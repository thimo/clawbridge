import ArgumentParser
import Carbon
import EventKit
import Foundation

struct PermissionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Request TCC permissions interactively, or check them non-interactively with --check."
    )

    @Flag(name: .long, help: "Report current authorization status as JSON and exit, WITHOUT prompting. Safe for unattended preflight.")
    var check: Bool = false

    @Option(name: .long, help: "With --check: which permission to report (calendar | reminders | mail). Default: calendar.")
    var domain: String = "calendar"

    @Option(name: [.customShort("o"), .long], help: "With --check: write JSON here instead of stdout (used when launched via `open -a`).")
    var output: String?

    func run() async throws {
        if check {
            try runCheck()
            return
        }
        try await runInteractive()
    }

    // MARK: - Non-prompting status check (preflight)

    private func runCheck() throws {
        let result: (granted: Bool, status: String)
        switch domain.lowercased() {
        case "calendar":
            result = Self.eventKitStatus(.event)
        case "reminders":
            result = Self.eventKitStatus(.reminder)
        case "mail":
            result = Self.mailAutomationStatus()
        default:
            let payload: [String: Any] = ["error": "unknown --domain '\(domain)' (expected calendar|reminders|mail)"]
            try writeJSON(payload)
            throw ExitCode.failure
        }
        try writeJSON(["granted": result.granted, "status": result.status, "domain": domain.lowercased()])
        if !result.granted { throw ExitCode.failure }
    }

    /// Synchronous, never prompts (unlike requestFullAccessToEvents).
    private static func eventKitStatus(_ type: EKEntityType) -> (Bool, String) {
        let s = EKEventStore.authorizationStatus(for: type)
        switch s {
        case .fullAccess:    return (true, "fullAccess")
        case .authorized:    return (true, "authorized")
        case .writeOnly:     return (false, "writeOnly")        // insufficient: we read
        case .notDetermined: return (false, "notDetermined")
        case .denied:        return (false, "denied")
        case .restricted:    return (false, "restricted")
        @unknown default:    return (false, "unknown")
        }
    }

    /// Automation (Apple Events) TCC for controlling Mail.app, asking the
    /// system WITHOUT showing a dialog. If Mail isn't running we can't tell
    /// — report granted:true ("unknown") so the preflight doesn't
    /// false-block; the bounded real call will handle it.
    private static func mailAutomationStatus() -> (Bool, String) {
        let bundleID = "com.apple.mail"
        var status: OSStatus = -1
        bundleID.withCString { cstr in
            var target = AEAddressDesc()
            let createErr = AECreateDesc(
                typeApplicationBundleID,
                cstr,
                bundleID.utf8.count,
                &target
            )
            guard createErr == 0 else { status = OSStatus(createErr); return }
            defer { AEDisposeDesc(&target) }
            status = AEDeterminePermissionToAutomateTarget(
                &target,
                AEEventClass(typeWildCard),
                AEEventID(typeWildCard),
                false // askUserIfNeeded: never prompt
            )
        }
        switch status {
        case noErr:
            return (true, "authorized")
        case OSStatus(errAEEventNotPermitted):
            return (false, "denied")
        case OSStatus(procNotFound):
            return (true, "mail-not-running-unknown") // don't block on this
        case -1744: // errAEEventWouldRequireUserConsent
            return (false, "notDetermined")
        default:
            return (true, "unknown(\(status))") // unknown → don't false-block
        }
    }

    private func writeJSON(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        if let path = output {
            try data.write(to: URL(fileURLWithPath: path))
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    // MARK: - Interactive grant (run once after install / identity change)

    private func runInteractive() async throws {
        print("Clawbridge is requesting macOS permissions.")
        print("If a system dialog appears, click \"Allow Full Access\".")
        print("")

        let store = EKEventStore()
        var anyFailed = false

        print("Requesting Calendar access...")
        do {
            let granted = try await store.requestFullAccessToEvents()
            if granted {
                let cals = store.calendars(for: .event)
                print("  ✓ Calendar: granted (\(cals.count) calendars)")
            } else {
                print("  ✗ Calendar: denied")
                anyFailed = true
            }
        } catch {
            print("  ✗ Calendar error: \(error.localizedDescription)")
            anyFailed = true
        }

        print("Requesting Reminders access...")
        do {
            let granted = try await store.requestFullAccessToReminders()
            if granted {
                let lists = store.calendars(for: .reminder)
                print("  ✓ Reminders: granted (\(lists.count) lists)")
            } else {
                print("  ✗ Reminders: denied")
                anyFailed = true
            }
        } catch {
            print("  ✗ Reminders error: \(error.localizedDescription)")
            anyFailed = true
        }

        // Trigger the Automation (Apple Events) consent dialog for Mail by
        // actually asking — askUserIfNeeded: true — so it can be granted in
        // the same one-time pass instead of surfacing later in a headless
        // cron run with no GUI to answer it.
        print("Requesting Mail (Automation) access...")
        let bundleID = "com.apple.mail"
        var mailStatus: OSStatus = -1
        bundleID.withCString { cstr in
            var target = AEAddressDesc()
            if AECreateDesc(typeApplicationBundleID, cstr, bundleID.utf8.count, &target) == 0 {
                defer { AEDisposeDesc(&target) }
                mailStatus = AEDeterminePermissionToAutomateTarget(
                    &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), true
                )
            }
        }
        switch mailStatus {
        case noErr:
            print("  ✓ Mail Automation: granted")
        case OSStatus(procNotFound):
            print("  ! Mail Automation: Mail.app not running — start Mail and re-run to grant")
        default:
            print("  ✗ Mail Automation: not granted (status \(mailStatus))")
            anyFailed = true
        }

        if anyFailed {
            print("")
            print("To fix denied permissions: System Settings → Privacy & Security → ")
            print("Calendars / Reminders / Automation, enable Clawbridge. If Clawbridge")
            print("is missing, re-run this from a GUI-session terminal (Terminal.app).")
            throw ExitCode.failure
        }
    }
}
