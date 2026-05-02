import ArgumentParser
import Foundation

// macOS has no native API to query Mail.app (no MailKit equivalent for read access).
// Path-1 implementation: shell out to `osascript` and ask Mail.app via AppleScript.
// Requires Mail.app to be running and Automation TCC ("Allow Clawbridge to control Mail").

struct MailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Query and send mail via Mail.app (AppleScript bridge).",
        subcommands: [
            MailUnreadCommand.self,
            MailRecentCommand.self,
            MailTodayCommand.self,
            MailSearchCommand.self,
            MailSendCommand.self,
        ]
    )
}

// MARK: - Subcommands

struct MailUnreadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unread",
        abstract: "Print unread messages from the inbox as a JSON array."
    )

    @Option(name: [.customShort("n"), .long], help: "Maximum number of messages to return.")
    var limit: Int = 50

    @Option(name: [.customShort("a"), .long], help: "Filter to a specific account name (repeatable).")
    var account: [String] = []

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let messages = try MailScript.fetchInboxMessages(
                unreadOnly: true, limit: limit, accounts: account, sinceDate: nil
            )
            try MailJSON.emit(messages, toFile: output)
        } catch {
            try MailJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

struct MailRecentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recent",
        abstract: "Print the most recent messages from the inbox as a JSON array."
    )

    @Option(name: [.customShort("n"), .long], help: "Maximum number of messages to return.")
    var limit: Int = 25

    @Option(name: [.customShort("a"), .long], help: "Filter to a specific account name (repeatable).")
    var account: [String] = []

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let messages = try MailScript.fetchInboxMessages(
                unreadOnly: false, limit: limit, accounts: account, sinceDate: nil
            )
            try MailJSON.emit(messages, toFile: output)
        } catch {
            try MailJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

struct MailTodayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "today",
        abstract: "Print messages received today (00:00 local) as a JSON array."
    )

    @Option(name: [.customShort("a"), .long], help: "Filter to a specific account name (repeatable).")
    var account: [String] = []

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let startOfDay = Calendar.current.startOfDay(for: Date())
            let messages = try MailScript.fetchInboxMessages(
                unreadOnly: false, limit: 200, accounts: account, sinceDate: startOfDay
            )
            try MailJSON.emit(messages, toFile: output)
        } catch {
            try MailJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

struct MailSearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search inbox messages by subject/sender substring (case-insensitive)."
    )

    @Option(name: [.customShort("q"), .long], help: "Substring to match in subject OR sender.")
    var query: String

    @Option(name: [.customShort("n"), .long], help: "Maximum number of messages to return.")
    var limit: Int = 50

    @Option(name: [.customShort("a"), .long], help: "Filter to a specific account name (repeatable).")
    var account: [String] = []

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let messages = try MailScript.searchInbox(query: query, limit: limit, accounts: account)
            try MailJSON.emit(messages, toFile: output)
        } catch {
            try MailJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

struct MailSendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Compose and send a message via Mail.app."
    )

    @Option(name: [.customShort("t"), .long], help: "Recipient address (repeatable for multiple To).")
    var to: [String]

    @Option(name: .long, help: "Cc recipient (repeatable).")
    var cc: [String] = []

    @Option(name: .long, help: "Bcc recipient (repeatable).")
    var bcc: [String] = []

    @Option(name: [.customShort("s"), .long], help: "Subject line.")
    var subject: String

    @Option(name: [.customShort("b"), .long], help: "Body. Use --body-file for content from a file.")
    var body: String?

    @Option(name: .long, help: "Path to a file whose contents will be the body (overrides --body).")
    var bodyFile: String?

    @Option(name: [.customShort("a"), .long], help: "Send from this account (sender address). Defaults to Mail.app default.")
    var account: String?

    @Flag(name: .long, help: "Save to Drafts instead of sending immediately.")
    var draft: Bool = false

    @Option(name: [.customShort("o"), .long], help: "Write status JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let actualBody: String
            if let bf = bodyFile {
                actualBody = try String(contentsOfFile: bf, encoding: .utf8)
            } else if let b = body {
                actualBody = b
            } else {
                throw CLIError("Either --body or --body-file is required.")
            }

            try MailScript.send(
                to: to,
                cc: cc,
                bcc: bcc,
                subject: subject,
                body: actualBody,
                fromAccount: account,
                draft: draft
            )
            let payload: [String: Any] = [
                "ok": true,
                "draft": draft,
                "to": to,
                "subject": subject,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try MailJSON.write(data, toFile: output)
        } catch {
            try MailJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

// MARK: - AppleScript bridge

enum MailScript {
    static func fetchInboxMessages(
        unreadOnly: Bool,
        limit: Int,
        accounts: [String],
        sinceDate: Date?
    ) throws -> [MailMessage] {
        let unreadFilter = unreadOnly ? "and read status is false" : ""
        let accountFilter = makeAccountFilter(accounts)
        let sinceFilter = makeSinceFilter(sinceDate)
        let filterClause = [unreadFilter, sinceFilter].filter { !$0.isEmpty }.joined(separator: " ")

        let script = """
        tell application "Mail"
            set out to ""
            set msgList to {}
            \(accountFilter.scriptHeader)
            repeat with acc in \(accountFilter.scriptIterable)
                try
                    set inboxMsgs to (messages of inbox of acc whose 1 = 1 \(filterClause))
                    set msgList to msgList & inboxMsgs
                end try
            end repeat
            -- Sort by date received descending; AppleScript can't sort, so we iterate.
            set total to count of msgList
            set cap to \(limit)
            if total < cap then set cap to total
            -- Mail returns inbox messages roughly newest-first; trust that order.
            repeat with i from 1 to cap
                set m to item i of msgList
                try
                    set sub to subject of m
                on error
                    set sub to ""
                end try
                try
                    set snd to sender of m
                on error
                    set snd to ""
                end try
                try
                    set rcv to date received of m
                on error
                    set rcv to missing value
                end try
                try
                    set isUnread to read status of m is false
                on error
                    set isUnread to false
                end try
                try
                    set msgId to message id of m
                on error
                    set msgId to ""
                end try
                set rcvIso to ""
                if rcv is not missing value then
                    set rcvIso to my isoFromDate(rcv)
                end if
                set out to out & sub & "\\t" & snd & "\\t" & rcvIso & "\\t" & (isUnread as text) & "\\t" & msgId & "\\n"
            end repeat
            return out
        end tell

        on isoFromDate(d)
            set y to year of d as integer
            set mo to (month of d as integer)
            set dy to day of d
            set h to hours of d
            set mi to minutes of d
            set s to seconds of d
            set ystr to text -4 thru -1 of ("0000" & y)
            set mostr to text -2 thru -1 of ("00" & mo)
            set dystr to text -2 thru -1 of ("00" & dy)
            set hstr to text -2 thru -1 of ("00" & h)
            set mistr to text -2 thru -1 of ("00" & mi)
            set sstr to text -2 thru -1 of ("00" & s)
            return ystr & "-" & mostr & "-" & dystr & "T" & hstr & ":" & mistr & ":" & sstr
        end isoFromDate
        """

        let raw = try runOsascript(script)
        return parseMessageList(raw)
    }

    static func searchInbox(query: String, limit: Int, accounts: [String]) throws -> [MailMessage] {
        let q = query.replacingOccurrences(of: "\"", with: "\\\"")
        let accountFilter = makeAccountFilter(accounts)
        let script = """
        tell application "Mail"
            set out to ""
            set msgList to {}
            \(accountFilter.scriptHeader)
            repeat with acc in \(accountFilter.scriptIterable)
                try
                    set hits to (messages of inbox of acc whose (subject contains "\(q)" or sender contains "\(q)"))
                    set msgList to msgList & hits
                end try
            end repeat
            set total to count of msgList
            set cap to \(limit)
            if total < cap then set cap to total
            repeat with i from 1 to cap
                set m to item i of msgList
                try
                    set sub to subject of m
                on error
                    set sub to ""
                end try
                try
                    set snd to sender of m
                on error
                    set snd to ""
                end try
                try
                    set rcv to date received of m
                on error
                    set rcv to missing value
                end try
                try
                    set isUnread to read status of m is false
                on error
                    set isUnread to false
                end try
                try
                    set msgId to message id of m
                on error
                    set msgId to ""
                end try
                set rcvIso to ""
                if rcv is not missing value then
                    set rcvIso to my isoFromDate(rcv)
                end if
                set out to out & sub & "\\t" & snd & "\\t" & rcvIso & "\\t" & (isUnread as text) & "\\t" & msgId & "\\n"
            end repeat
            return out
        end tell

        on isoFromDate(d)
            set y to year of d as integer
            set mo to (month of d as integer)
            set dy to day of d
            set h to hours of d
            set mi to minutes of d
            set s to seconds of d
            set ystr to text -4 thru -1 of ("0000" & y)
            set mostr to text -2 thru -1 of ("00" & mo)
            set dystr to text -2 thru -1 of ("00" & dy)
            set hstr to text -2 thru -1 of ("00" & h)
            set mistr to text -2 thru -1 of ("00" & mi)
            set sstr to text -2 thru -1 of ("00" & s)
            return ystr & "-" & mostr & "-" & dystr & "T" & hstr & ":" & mistr & ":" & sstr
        end isoFromDate
        """
        let raw = try runOsascript(script)
        return parseMessageList(raw)
    }

    static func send(
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        body: String,
        fromAccount: String?,
        draft: Bool
    ) throws {
        let escSubject = subject.replacingOccurrences(of: "\"", with: "\\\"")
        // Encode body via tempfile to avoid AppleScript string-escape minefield.
        let tmp = try writeTempFile(body)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        var lines: [String] = []
        lines.append("set bodyText to read POSIX file \"\(tmp)\" as «class utf8»")
        lines.append("tell application \"Mail\"")
        if let acct = fromAccount {
            let escAcct = acct.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("    set newMsg to make new outgoing message with properties {subject:\"\(escSubject)\", content:bodyText, sender:\"\(escAcct)\", visible:false}")
        } else {
            lines.append("    set newMsg to make new outgoing message with properties {subject:\"\(escSubject)\", content:bodyText, visible:false}")
        }
        lines.append("    tell newMsg")
        for addr in to {
            let e = addr.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("        make new to recipient at end of to recipients with properties {address:\"\(e)\"}")
        }
        for addr in cc {
            let e = addr.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("        make new cc recipient at end of cc recipients with properties {address:\"\(e)\"}")
        }
        for addr in bcc {
            let e = addr.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("        make new bcc recipient at end of bcc recipients with properties {address:\"\(e)\"}")
        }
        lines.append("    end tell")
        if draft {
            lines.append("    save newMsg")
        } else {
            lines.append("    send newMsg")
        }
        lines.append("end tell")
        _ = try runOsascript(lines.joined(separator: "\n"))
    }

    // MARK: - Internals

    private struct AccountFilter {
        let scriptHeader: String
        let scriptIterable: String
    }

    private static func makeAccountFilter(_ accounts: [String]) -> AccountFilter {
        if accounts.isEmpty {
            return AccountFilter(scriptHeader: "", scriptIterable: "every account")
        }
        let escaped = accounts.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ")
        return AccountFilter(
            scriptHeader: "set acctNames to {\(escaped)}\n            set acctList to {}\n            repeat with an in acctNames\n                try\n                    set acctList to acctList & {account named (an as text)}\n                end try\n            end repeat",
            scriptIterable: "acctList"
        )
    }

    private static func makeSinceFilter(_ sinceDate: Date?) -> String {
        guard let d = sinceDate else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone.current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let s = fmt.string(from: d)
        // AppleScript date literal: `date "yyyy-MM-dd HH:mm:ss"` — Mail will coerce.
        return "and date received > (date \"\(s)\")"
    }

    private static func parseMessageList(_ raw: String) -> [MailMessage] {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.compactMap { line -> MailMessage? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 5 else { return nil }
            return MailMessage(
                subject: parts[0],
                sender: parts[1],
                receivedISO: parts[2].isEmpty ? nil : parts[2],
                unread: parts[3] == "true",
                messageId: parts[4].isEmpty ? nil : parts[4]
            )
        }
    }

    private static func writeTempFile(_ content: String) throws -> String {
        let tmpDir = NSTemporaryDirectory()
        let path = tmpDir + "clawbridge-mail-\(UUID().uuidString).txt"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private static func runOsascript(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw CLIError("Failed to launch osascript: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? "unknown osascript error"
            throw CLIError("AppleScript failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

// MARK: - Models + JSON

struct MailMessage {
    let subject: String
    let sender: String
    let receivedISO: String?
    let unread: Bool
    let messageId: String?
}

enum MailJSON {
    static func emit(_ messages: [MailMessage], toFile: String?) throws {
        let payload: [[String: Any]] = messages.map { m in
            var d: [String: Any] = [
                "subject": m.subject,
                "sender": m.sender,
                "unread": m.unread,
            ]
            if let r = m.receivedISO { d["received"] = r }
            if let id = m.messageId { d["messageId"] = id }
            return d
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try write(data, toFile: toFile)
    }

    static func emitError(_ error: Error, toFile: String?) throws {
        let message: String
        if let cli = error as? CLIError { message = cli.message }
        else { message = error.localizedDescription }
        let payload: [String: Any] = ["error": message]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try write(data, toFile: toFile)
    }

    static func write(_ data: Data, toFile: String?) throws {
        if let path = toFile {
            try data.write(to: URL(fileURLWithPath: path))
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
