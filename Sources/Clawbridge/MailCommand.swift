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
            MailFoldersCommand.self,
            MailTrashCommand.self,
            MailMoveCommand.self,
            MailSendCommand.self,
            MailSaveCommand.self,
        ]
    )
}

// MARK: - Subcommands

struct MailUnreadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unread",
        abstract: "Print unread messages from a mailbox as a JSON array."
    )

    @Option(name: [.customShort("n"), .long], help: "Maximum number of messages to return.")
    var limit: Int = 50

    @Option(name: [.customShort("a"), .long], help: "Filter to a specific account name (repeatable).")
    var account: [String] = []

    @Option(name: [.customShort("m"), .long], help: "Mailbox/folder name (default: inbox).")
    var mailbox: String?

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let messages = try MailScript.fetchMessages(
                unreadOnly: true, limit: limit, accounts: account, mailbox: mailbox, sinceDate: nil
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
        abstract: "Print the most recent messages from a mailbox as a JSON array."
    )

    @Option(name: [.customShort("n"), .long], help: "Maximum number of messages to return.")
    var limit: Int = 25

    @Option(name: [.customShort("a"), .long], help: "Filter to a specific account name (repeatable).")
    var account: [String] = []

    @Option(name: [.customShort("m"), .long], help: "Mailbox/folder name (default: inbox).")
    var mailbox: String?

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let messages = try MailScript.fetchMessages(
                unreadOnly: false, limit: limit, accounts: account, mailbox: mailbox, sinceDate: nil
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

    @Option(name: [.customShort("m"), .long], help: "Mailbox/folder name (default: inbox).")
    var mailbox: String?

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let startOfDay = Calendar.current.startOfDay(for: Date())
            let messages = try MailScript.fetchMessages(
                unreadOnly: false, limit: 200, accounts: account, mailbox: mailbox, sinceDate: startOfDay
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
        abstract: "Search a mailbox by subject/sender substring (case-insensitive)."
    )

    @Option(name: [.customShort("q"), .long], help: "Substring to match in subject OR sender.")
    var query: String

    @Option(name: [.customShort("n"), .long], help: "Maximum number of messages to return.")
    var limit: Int = 50

    @Option(name: [.customShort("a"), .long], help: "Filter to a specific account name (repeatable).")
    var account: [String] = []

    @Option(name: [.customShort("m"), .long], help: "Mailbox/folder name (default: inbox).")
    var mailbox: String?

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let messages = try MailScript.search(
                query: query, limit: limit, accounts: account, mailbox: mailbox
            )
            try MailJSON.emit(messages, toFile: output)
        } catch {
            try MailJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

struct MailFoldersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "folders",
        abstract: "List mailbox/folder names per account as a JSON array."
    )

    @Option(name: [.customShort("a"), .long], help: "Filter to a specific account name (repeatable).")
    var account: [String] = []

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let folders = try MailScript.listFolders(accounts: account)
            let payload: [[String: Any]] = folders.map { ["account": $0.account, "mailbox": $0.mailbox] }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try MailJSON.write(data, toFile: output)
        } catch {
            try MailJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

struct MailTrashCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trash",
        abstract: "Move messages (matched by message id) to Trash. Recoverable."
    )

    @Option(name: [.customLong("message-id"), .customShort("i")], help: "Message id to trash (repeatable).")
    var messageId: [String]

    @Option(name: [.customShort("a"), .long], help: "Limit to a specific account name (repeatable).")
    var account: [String] = []

    @Option(name: [.customShort("m"), .long], help: "Mailbox/folder name to search in (default: inbox).")
    var mailbox: String?

    @Option(name: [.customShort("o"), .long], help: "Write status JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            guard !messageId.isEmpty else {
                throw CLIError("At least one --message-id is required.")
            }
            let result = try MailScript.trash(
                messageIds: messageId, accounts: account, mailbox: mailbox
            )
            let payload: [String: Any] = [
                "ok": true,
                "requested": messageId.count,
                "moved": result.moved,
                "missing": result.missing,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try MailJSON.write(data, toFile: output)
        } catch {
            try MailJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

struct MailMoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move messages (matched by message id) to another mailbox in the same account."
    )

    @Option(name: [.customLong("message-id"), .customShort("i")], help: "Message id to move (repeatable).")
    var messageId: [String]

    @Option(name: [.customShort("a"), .long], help: "Limit to a specific account name (repeatable).")
    var account: [String] = []

    @Option(name: [.customShort("m"), .long], help: "Source mailbox/folder name (default: inbox).")
    var mailbox: String?

    @Option(name: .long, help: "Destination mailbox, in the source's account. Never created.")
    var to: String

    @Option(name: [.customShort("o"), .long], help: "Write status JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            guard !messageId.isEmpty else {
                throw CLIError("At least one --message-id is required.")
            }
            let result = try MailScript.move(
                messageIds: messageId, accounts: account, mailbox: mailbox, target: to
            )
            let payload: [String: Any] = [
                "ok": true,
                "requested": messageId.count,
                "moved": result.moved,
                "missing": result.missing,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try MailJSON.write(data, toFile: output)
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

struct MailSaveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save",
        abstract: "Save a message's raw RFC822 source (Mail.app's `source` property) to a .eml file."
    )

    @Option(name: [.customLong("message-id"), .customShort("i")], help: "Message id to save.")
    var messageId: String

    // `--file` is the .eml destination; `--output` below stays the JSON-result
    // path used by the `open -a` wrapper — kept as two separate options
    // because they point at two different files.
    @Option(name: .long, help: "Destination path for the .eml file.")
    var file: String

    @Option(name: [.customShort("a"), .long], help: "Limit to a specific account name (repeatable).")
    var account: [String] = []

    @Option(name: [.customShort("m"), .long], help: "Mailbox/folder name to search in (default: inbox).")
    var mailbox: String?

    @Flag(name: .long, help: "Overwrite --file if it already exists.")
    var force: Bool = false

    @Option(name: [.customShort("o"), .long], help: "Write status JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let fileURL = URL(fileURLWithPath: file)
            let dirURL = fileURL.deletingLastPathComponent()
            let fm = FileManager.default
            guard fm.fileExists(atPath: dirURL.path) else {
                throw CLIError("directory does not exist: \(dirURL.path)")
            }
            if !force && fm.fileExists(atPath: fileURL.path) {
                throw CLIError("file exists: \(fileURL.path)")
            }

            let result = try MailScript.save(messageId: messageId, accounts: account, mailbox: mailbox)
            guard let data = result.source.data(using: .utf8) else {
                throw CLIError("failed to encode message source as UTF-8")
            }
            try data.write(to: fileURL)

            var payload: [String: Any] = [
                "file": fileURL.path,
                "subject": result.subject,
                "sender": result.sender,
                "bytes": data.count,
            ]
            if let r = result.receivedISO { payload["received"] = r }
            let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try MailJSON.write(jsonData, toFile: output)
        } catch {
            try MailJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

// MARK: - AppleScript bridge

enum MailScript {
    private static func asLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// AppleScript that fills `boxes` with the mailbox on every selected
    /// account that actually has it. Only the lookup may fail per account (a
    /// mailbox name tried on every account won't exist on most); if none has
    /// it, the script errors instead of quietly yielding an empty result.
    private static func resolveBoxes(_ accounts: [String], _ mailbox: String?) -> String {
        let accountFilter = makeAccountFilter(accounts)
        let label = asLiteral(mailbox ?? "inbox")
        // No per-account `inbox` in Mail's dictionary: IMAP calls it "INBOX",
        // Exchange "Inbox".
        let names = (mailbox.map { [$0] } ?? ["INBOX", "Inbox"]).map(asLiteral).joined(separator: ", ")
        return """
            set boxes to {}
            \(accountFilter.scriptHeader)
            repeat with acc in \(accountFilter.scriptIterable)
                repeat with nm in {\(names)}
                    try
                        set mbRef to mailbox (nm as text) of acc
                        get name of mbRef
                        set end of boxes to mbRef
                        exit repeat
                    end try
                end repeat
            end repeat
            if (count of boxes) is 0 then error "mailbox not found: " & \(label)
        """
    }

    static func fetchMessages(
        unreadOnly: Bool,
        limit: Int,
        accounts: [String],
        mailbox: String?,
        sinceDate: Date?
    ) throws -> [MailMessage] {
        if let hits = try MailIndex.list(
            accounts: accounts, mailbox: mailbox, limit: limit, unreadOnly: unreadOnly, since: sinceDate
        ) {
            return hits
        }
        var conditions: [String] = []
        if unreadOnly { conditions.append("read status is false") }
        if let since = sinceDate {
            // Relative to `current date`: a date literal would be parsed in
            // the user's locale.
            let secs = max(0, Int(Date().timeIntervalSince(since)))
            conditions.append("date received > ((current date) - \(secs))")
        }
        // Without a filter, skip `whose` (it makes Mail walk the whole mailbox)
        // and take the first `limit` messages; Mail keeps them newest-first.
        let collect: String
        if conditions.isEmpty {
            collect = """
                    set c to count of messages of mb
                    if c > \(limit) then set c to \(limit)
                    if c > 0 then set msgList to msgList & (messages 1 thru c of mb)
            """
        } else {
            collect = "        set msgList to msgList & (messages of mb whose \(conditions.joined(separator: " and ")))"
        }
        return try listMessages(accounts: accounts, mailbox: mailbox, limit: limit, collect: collect)
    }

    static func search(query: String, limit: Int, accounts: [String], mailbox: String?) throws -> [MailMessage] {
        if let hits = try MailIndex.list(accounts: accounts, mailbox: mailbox, limit: limit, query: query) {
            return hits
        }
        let q = asLiteral(query)
        let collect = "        set msgList to msgList & (messages of mb whose (subject contains \(q) or sender contains \(q)))"
        return try listMessages(accounts: accounts, mailbox: mailbox, limit: limit, collect: collect)
    }

    /// `collect` appends message references from mailbox `mb` to `msgList`.
    private static func listMessages(
        accounts: [String], mailbox: String?, limit: Int, collect: String
    ) throws -> [MailMessage] {
        let script = """
        tell application "Mail"
        \(resolveBoxes(accounts, mailbox))
            set out to ""
            set msgList to {}
            repeat with mbItem in boxes
                set mb to contents of mbItem
        \(collect)
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

        \(isoHandler)
        """
        let raw = try runOsascript(script)
        return parseMessageList(raw)
    }

    private static let isoHandler = """
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

    /// Name and id (the UUID in Mail's index URLs) of every account.
    static func accountIds() throws -> [(name: String, id: String)] {
        let script = """
        tell application "Mail"
            set out to ""
            repeat with acc in every account
                set out to out & (name of acc) & tab & (id of acc) & linefeed
            end repeat
            return out
        end tell
        """
        return try runOsascript(script).split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2 else { return nil }
            return (name: parts[0], id: parts[1])
        }
    }

    static func listFolders(accounts: [String]) throws -> [(account: String, mailbox: String)] {
        let accountFilter = makeAccountFilter(accounts)
        let script = """
        tell application "Mail"
            set out to ""
            \(accountFilter.scriptHeader)
            repeat with acc in \(accountFilter.scriptIterable)
                try
                    set an to name of acc
                    repeat with mb in mailboxes of acc
                        try
                            set out to out & an & "\\t" & (name of mb) & "\\n"
                        end try
                    end repeat
                end try
            end repeat
            return out
        end tell
        """
        let raw = try runOsascript(script)
        return raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { return nil }
            return (account: parts[0], mailbox: parts[1])
        }
    }

    static func trash(messageIds: [String], accounts: [String], mailbox: String?) throws -> (moved: Int, missing: [String]) {
        // Mark read before trashing: a message moved to Trash while still
        // unread keeps inflating unread counts / re-surfacing in some clients.
        let action = """
                        try
                            set read status of m to true
                        end try
                        delete m
        """
        return try actWithRetry(messageIds: messageIds, accounts: accounts, mailbox: mailbox, prelude: "", action: action)
    }

    /// Move messages to mailbox `target` in the same account as the source
    /// box. Errors before touching anything if an account lacks `target`.
    static func move(
        messageIds: [String], accounts: [String], mailbox: String?, target: String
    ) throws -> (moved: Int, missing: [String]) {
        let t = asLiteral(target)
        let prelude = """
            set targets to {}
            repeat with mbItem in boxes
                set acc to account of (contents of mbItem)
                try
                    set tgt to mailbox \(t) of acc
                    get name of tgt
                on error
                    error "target mailbox not found: " & \(t) & " in account " & (name of acc)
                end try
                set end of targets to tgt
            end repeat
        """
        let action = "                move m to (item k of targets)"
        return try actWithRetry(messageIds: messageIds, accounts: accounts, mailbox: mailbox, prelude: prelude, action: action)
    }

    /// Run `action` once, then retry ids that matched nothing once more:
    /// Mail's index occasionally lags a message that is plainly there, so the
    /// retry also scans the mailbox for ids the index still doesn't have.
    private static func actWithRetry(
        messageIds: [String], accounts: [String], mailbox: String?, prelude: String, action: String
    ) throws -> (moved: Int, missing: [String]) {
        var counts = try act(messageIds: messageIds, accounts: accounts, mailbox: mailbox, prelude: prelude, action: action)
        var missing = messageIds.filter { (counts[$0] ?? 0) == 0 }
        if !missing.isEmpty {
            Thread.sleep(forTimeInterval: 2)
            let retry = try act(
                messageIds: missing, accounts: accounts, mailbox: mailbox, prelude: prelude, action: action,
                scanIfUnindexed: true
            )
            counts.merge(retry) { $0 + $1 }
            missing = missing.filter { (retry[$0] ?? 0) == 0 }
        }
        return (moved: counts.values.reduce(0, +), missing: missing)
    }

    /// Apply `action` (AppleScript on message `m`, found in `item k of boxes`)
    /// to every message matching each id. Returns the match count per id.
    private static func act(
        messageIds: [String], accounts: [String], mailbox: String?, prelude: String, action: String,
        scanIfUnindexed: Bool = false
    ) throws -> [String: Int] {
        let script = """
        tell application "Mail"
        \(resolveBoxes(accounts, mailbox))
        \(prelude)
            set wanted to \(wantedList(messageIds, accounts: accounts, mailbox: mailbox, scanIfUnindexed: scanIfUnindexed))
            set out to ""
            repeat with w in wanted
                set n to 0
                repeat with k from 1 to count of boxes
                    set hits to my findMsgs(item k of boxes, item 1 of w, item 2 of w)
                    repeat with m in hits
                        try
        \(action)
                            set n to n + 1
                        end try
                    end repeat
                end repeat
                set out to out & n & linefeed
            end repeat
            return out
        end tell

        \(findHandler)
        """
        let lines = try runOsascript(script).split(separator: "\n").map {
            Int($0.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        guard lines.count == messageIds.count else {
            throw CLIError("unexpected AppleScript output: \(lines.count) counts for \(messageIds.count) ids")
        }
        var counts: [String: Int] = [:]
        for (id, n) in zip(messageIds, lines) { counts[id, default: 0] += n }
        return counts
    }

    /// AppleScript list `{{"<message-id>", <internal ids>}, …}`. The internal
    /// ids come from Mail's index; `missing value` when the index can't be
    /// read (or, with `scanIfUnindexed`, doesn't know the id), which makes
    /// `findMsgs` fall back to `whose`.
    private static func wantedList(
        _ messageIds: [String], accounts: [String], mailbox: String?, scanIfUnindexed: Bool = false
    ) -> String {
        let rowids = MailIndex.rowids(messageIds: messageIds, accounts: accounts, mailbox: mailbox)
        let items = messageIds.map { id -> String in
            guard let hits = rowids?[id], !(hits.isEmpty && scanIfUnindexed) else {
                return "{\(asLiteral(id)), missing value}"
            }
            return "{\(asLiteral(id)), {\(hits.map(String.init).joined(separator: ", "))}}"
        }
        return "{" + items.joined(separator: ", ") + "}"
    }

    /// `findMsgs(mb, wid, rowids)`: the messages in `mb` with Message-ID `wid`.
    /// Addressing by internal id is instant; `whose` walks the whole mailbox
    /// (~30 s on a 27k-message Archive), so it is only the fallback.
    private static let findHandler = """
    on findMsgs(mb, wid, rowids)
        tell application "Mail"
            if rowids is missing value then
                return (messages of mb whose message id is (wid as text))
            end if
            set hits to {}
            repeat with r in rowids
                try
                    set m to «class mssg» id (r as integer) of mb
                    get id of m
                    set end of hits to m
                end try
            end repeat
            return hits
        end tell
    end findMsgs
    """

    /// Fetch one message's subject/sender/received-date/raw-source by exact RFC
    /// Message-ID. Throws if zero or more than one message matches.
    static func save(
        messageId: String, accounts: [String], mailbox: String?
    ) throws -> (subject: String, sender: String, receivedISO: String?, source: String) {
        // Generated fresh per call: a boundary the message source itself can't
        // fake, so metadata and raw source can be split back apart in Swift
        // without assuming anything about what's inside the source.
        let separator = UUID().uuidString
        let script = """
        tell application "Mail"
        \(resolveBoxes(accounts, mailbox))
            set w to item 1 of \(wantedList([messageId], accounts: accounts, mailbox: mailbox, scanIfUnindexed: true))
            set hits to {}
            repeat with mbItem in boxes
                set hits to hits & my findMsgs(contents of mbItem, item 1 of w, item 2 of w)
            end repeat
            set n to count of hits
            if n is not 1 then
                return (n as text)
            end if
            set m to item 1 of hits
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
            set rcvIso to ""
            try
                set rcv to date received of m
                set rcvIso to my isoFromDate(rcv)
            end try
            set srcText to source of m
            return "1" & linefeed & sub & "\\t" & snd & "\\t" & rcvIso & linefeed & "\(separator)" & linefeed & srcText
        end tell

        \(findHandler)

        \(isoHandler)
        """

        var raw = try runOsascript(script)
        // osascript appends exactly one trailing newline to whatever the
        // script returns; strip only that one so a message source that
        // itself ends in blank lines round-trips untouched.
        if raw.hasSuffix("\n") { raw.removeLast() }

        guard let sepRange = raw.range(of: "\n\(separator)\n") else {
            let countLine = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let count = Int(countLine) else {
                throw CLIError("unexpected AppleScript output while saving message \(messageId)")
            }
            if count == 0 {
                throw CLIError("message not found: \(messageId)")
            }
            throw CLIError("ambiguous: \(count) messages match \(messageId)")
        }

        let metadataBlock = String(raw[raw.startIndex..<sepRange.lowerBound])
        let sourceText = String(raw[sepRange.upperBound...])
        let metaLines = metadataBlock.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard metaLines.count == 2 else {
            throw CLIError("unexpected AppleScript output while saving message \(messageId)")
        }
        let fields = metaLines[1].components(separatedBy: "\t")
        let subject = fields.count > 0 ? fields[0] : ""
        let sender = fields.count > 1 ? fields[1] : ""
        let receivedISO = (fields.count > 2 && !fields[2].isEmpty) ? fields[2] : nil

        return (subject: subject, sender: sender, receivedISO: receivedISO, source: sourceText)
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

        // Drain both pipes on background threads *while the process runs*.
        // A pipe's kernel buffer is ~64KB; some commands (e.g. `mail save`
        // dumping a multi-megabyte message source) write far more than that
        // to stdout. Reading via readDataToEndOfFile() only after
        // waitUntilExit() deadlocks as soon as osascript fills that buffer
        // and blocks on write() with nothing draining the other end.
        var outData = Data()
        var errData = Data()
        let readGroup = DispatchGroup()
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading

        do {
            try process.run()
        } catch {
            throw CLIError("Failed to launch osascript: \(error.localizedDescription)")
        }

        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outHandle.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errHandle.readDataToEndOfFile()
            readGroup.leave()
        }

        process.waitUntilExit()
        readGroup.wait()

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
