import ArgumentParser
import Foundation

// Clawbridge.app is the only stably code-signed identity on this Mac, so
// macOS TCC folder grants (Desktop/Documents/Downloads) keyed to it survive
// rebuilds. `run` makes the app the launcher of an unattended cron chain
// (`ruby vonk-cron …` → claude → bash → ls/pdftotext/mv), so every child
// inherits the app as its responsible process and the grants apply to the
// whole chain. Invoked by a LaunchAgent as:
//   open -n -W -a Clawbridge.app --args run --log <path> --cwd <dir> \
//       --env K=V ... -- <command …>

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Launch a command as a child of Clawbridge, so it inherits its TCC identity."
    )

    @Option(name: .long, help: "Append child stdout/stderr to this file instead of inheriting the parent's.")
    var log: String?

    @Option(name: .long, help: "Working directory for the child process.")
    var cwd: String?

    @Option(name: .long, help: "Environment variable to overlay as KEY=VALUE (repeatable).")
    var env: [String] = []

    @Option(name: .long, help: "Seconds to wait after SIGTERM before SIGKILL-ing the child.")
    var termGrace: Double = 5

    // `.remaining` (not `.captureForPassthrough`) so `run --help` with no
    // `--` still triggers ArgumentParser's built-in help handling instead of
    // being swallowed into the passthrough command.
    @Argument(parsing: .remaining, help: "Command to run, and its arguments.")
    var command: [String] = []

    func run() async throws {
        guard !command.isEmpty else {
            throw CLIError("no command given (pass it after `--`)")
        }

        // --log: open for append (create if missing), never truncate.
        var logHandle: FileHandle?
        if let logPath = log {
            let fm = FileManager.default
            if !fm.fileExists(atPath: logPath) {
                fm.createFile(atPath: logPath, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: logPath) else {
                throw CLIError("could not open log file for writing: \(logPath)")
            }
            handle.seekToEndOfFile()
            logHandle = handle
        }

        let timestamp = isoTimestamp()
        let logLine = "[\(timestamp)] clawbridge run: \(command.joined(separator: " "))\n"
        if let handle = logHandle {
            if let data = logLine.data(using: .utf8) { handle.write(data) }
        }

        let process = Process()

        // Executable resolution: if command[0] contains a "/", use it as-is;
        // otherwise run it through `/usr/bin/env` so it resolves via PATH
        // (given through --env).
        if command[0].contains("/") {
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
        }

        // Environment: start from the parent's (LaunchServices gives the app
        // a minimal one), overlay each --env KEY=VALUE, then set the two
        // vars the wrapper script uses to exec this binary directly for
        // nested calls instead of going through `open` again.
        var environment = ProcessInfo.processInfo.environment
        for entry in env {
            guard let eqIndex = entry.firstIndex(of: "=") else {
                throw CLIError("invalid --env value (expected KEY=VALUE): \(entry)")
            }
            let key = String(entry[entry.startIndex..<eqIndex])
            let value = String(entry[entry.index(after: eqIndex)...])
            environment[key] = value
        }
        environment["CLAWBRIDGE_ROOT"] = "1"
        environment["CLAWBRIDGE_BIN"] = resolvedExecutablePath()
        process.environment = environment

        if let cwd = cwd {
            let cwdURL = URL(fileURLWithPath: cwd)
            guard FileManager.default.fileExists(atPath: cwdURL.path) else {
                throw CLIError("--cwd does not exist: \(cwd)")
            }
            process.currentDirectoryURL = cwdURL
        }

        if let handle = logHandle {
            process.standardOutput = handle
            process.standardError = handle
        }
        // else: inherit the parent's stdout/stderr (Process default).

        // Signal handling: forward SIGTERM/SIGINT to the child, escalating to
        // SIGKILL after --term-grace seconds if it hasn't exited. Rationale:
        // the LaunchAgent may wrap `open` in a timeout, and a stranded child
        // would hold a session lock.
        // Use a background queue, not .main: process.waitUntilExit() below
        // blocks synchronously on whatever thread runs this async function,
        // and there's no guarantee the real main thread is free to drain
        // .main in the meantime.
        let signalQueue = DispatchQueue(label: "clawbridge.run.signals")
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        let termGraceSeconds = termGrace

        func forwardAndEscalate() {
            guard process.isRunning else { return }
            process.terminate()  // sends SIGTERM
            signalQueue.asyncAfter(deadline: .now() + termGraceSeconds) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        termSource.setEventHandler { forwardAndEscalate() }
        intSource.setEventHandler { forwardAndEscalate() }
        termSource.resume()
        intSource.resume()

        do {
            try process.run()
        } catch {
            let message = "clawbridge run: failed to launch \(command[0]): \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            if let handle = logHandle, let data = message.data(using: .utf8) {
                handle.write(data)
            }
            throw ExitCode(127)
        }

        process.waitUntilExit()
        try? logHandle?.close()

        if process.terminationReason == .uncaughtSignal {
            throw ExitCode(128 + process.terminationStatus)
        }
        throw ExitCode(process.terminationStatus)
    }

    /// Absolute path of the currently running executable, so nested
    /// invocations can exec it directly instead of going through `open` again.
    private func resolvedExecutablePath() -> String {
        if let path = Bundle.main.executablePath {
            return path
        }
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") {
            return arg0
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd).appendingPathComponent(arg0).standardized.path
    }

    private func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }
}
