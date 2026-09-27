import Foundation
import SQLite3

// Mail.app's own SQLite index ("Envelope Index"). AppleScript `whose` walks
// every message of a mailbox, which is ~30 s on a 27k-message Archive; the
// index answers in milliseconds. Reading it needs Full Disk Access; without
// it `open()` fails and callers fall back to AppleScript.
//
// Layout (V10, verified 2026-09-27): messages.ROWID is AppleScript's message
// `id`; mailboxes.url is `<scheme>://<account id>/<percent-encoded path>`;
// message_global_data.message_id_header holds the Message-ID with `<…>`.
enum MailIndex {
    /// Newest-first messages from the mailbox, or nil if the index can't be read.
    static func list(
        accounts: [String], mailbox: String?, limit: Int,
        unreadOnly: Bool = false, since: Date? = nil, query: String? = nil
    ) throws -> [MailMessage]? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        let boxIds = try boxes(db, accounts: accounts, mailbox: mailbox)

        var sql = """
            SELECT COALESCE(m.subject_prefix, '') || s.subject, a.address, a.comment,
                   m.date_received, m.read, g.message_id_header
            FROM messages m
            JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
            WHERE m.deleted = 0 AND m.mailbox IN (\(boxIds.map(String.init).joined(separator: ",")))
            """
        var binds: [String] = []
        if unreadOnly { sql += " AND m.read = 0" }
        if let since { sql += " AND m.date_received >= \(Int(since.timeIntervalSince1970))" }
        if let query {
            sql += " AND (COALESCE(m.subject_prefix, '') || s.subject LIKE ?1 ESCAPE '\\' OR a.address LIKE ?1 ESCAPE '\\' OR a.comment LIKE ?1 ESCAPE '\\')"
            let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            binds.append("%\(escaped)%")
        }
        sql += " ORDER BY m.date_received DESC LIMIT \(max(0, limit))"

        return try rows(db, sql, binds) { stmt in
            let address = text(stmt, 1)
            let comment = text(stmt, 2)
            let received = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 3)))
            return MailMessage(
                subject: text(stmt, 0),
                sender: comment.isEmpty ? address : "\(comment) <\(address)>",
                receivedISO: received.map(isoLocal),
                unread: sqlite3_column_int(stmt, 4) == 0,
                messageId: stripBrackets(text(stmt, 5))
            )
        }
    }

    /// Mail's internal message ids (AppleScript `id`) per RFC Message-ID,
    /// limited to the given mailbox/accounts. nil = index not readable.
    static func rowids(messageIds: [String], accounts: [String], mailbox: String?) -> [String: [Int]]? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        guard let boxIds = try? boxes(db, accounts: accounts, mailbox: mailbox) else { return nil }
        let sql = """
            SELECT m.ROWID FROM messages m
            JOIN message_global_data g ON g.ROWID = m.global_message_id
            WHERE m.deleted = 0 AND g.message_id_header = ?1
              AND m.mailbox IN (\(boxIds.map(String.init).joined(separator: ",")))
            """
        var result: [String: [Int]] = [:]
        for id in messageIds {
            let header = "<\(stripBrackets(id) ?? id)>"
            guard let hits = try? rows(db, sql, [header], { Int(sqlite3_column_int64($0, 0)) }) else { return nil }
            result[id] = hits
        }
        return result
    }

    // MARK: - Internals

    private static func open() -> OpaquePointer? {
        // Diagnostic switch: force the AppleScript path.
        if ProcessInfo.processInfo.environment["CLAWBRIDGE_NO_INDEX"] == "1" { return nil }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return nil }
        // Highest V<n> that has an index.
        let candidates = versions.filter { $0.hasPrefix("V") }
            .sorted { (Int($0.dropFirst()) ?? 0) > (Int($1.dropFirst()) ?? 0) }
            .map { base.appendingPathComponent($0).appendingPathComponent("MailData/Envelope Index").path }
        guard let path = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) }) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 3000)
        return db
    }

    /// ROWIDs of the mailbox on each selected (live) account. Accounts come
    /// from Mail itself: the index also keeps boxes of removed accounts.
    private static func boxes(_ db: OpaquePointer, accounts: [String], mailbox: String?) throws -> [Int64] {
        let live = try MailScript.accountIds()
        let selected = accounts.isEmpty ? live : live.filter { accounts.contains($0.name) }
        let wanted = Set(selected.map(\.id))
        let all = try rows(db, "SELECT ROWID, url FROM mailboxes", []) { stmt in
            (sqlite3_column_int64(stmt, 0), text(stmt, 1))
        }
        let ids = all.compactMap { rowid, url -> Int64? in
            guard let comps = URLComponents(string: url), let account = comps.host else { return nil }
            guard wanted.contains(account) else { return nil }
            let path = String(comps.path.dropFirst())  // `path` is percent-decoded
            // Default inbox is "INBOX" (IMAP) or "Inbox" (Exchange). A named box
            // is top-level or under INBOX on servers that nest everything
            // there; exact case, like AppleScript's `mailbox "<name>"`.
            guard let mailbox else {
                return path.caseInsensitiveCompare("INBOX") == .orderedSame ? rowid : nil
            }
            return path == mailbox || path == "INBOX/" + mailbox ? rowid : nil
        }
        guard !ids.isEmpty else {
            throw CLIError("mailbox not found: \(mailbox ?? "inbox")")
        }
        return ids
    }

    private static func rows<T>(
        _ db: OpaquePointer, _ sql: String, _ binds: [String], _ map: (OpaquePointer) -> T
    ) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CLIError("mail index: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, transient)
        }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw CLIError("mail index: \(String(cString: sqlite3_errmsg(db)))")
            }
            out.append(map(stmt))
        }
        return out
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    private static func stripBrackets(_ s: String) -> String? {
        guard !s.isEmpty else { return nil }
        guard s.hasPrefix("<"), s.hasSuffix(">") else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// Same shape as the AppleScript path: local time, no offset.
    private static func isoLocal(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fmt.string(from: d)
    }
}
