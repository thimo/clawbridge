import ArgumentParser
import EventKit
import Foundation

// Umbrella `reminders` command; all work happens in subcommands.
struct RemindersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Query and create macOS Reminders via EventKit.",
        subcommands: [
            RemindersListListsCommand.self,
            RemindersTodayCommand.self,
            RemindersOverdueCommand.self,
            RemindersPendingCommand.self,
            RemindersAllCommand.self,
            RemindersAddCommand.self,
        ]
    )
}

// MARK: - Subcommands

struct RemindersListListsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-lists",
        abstract: "Print all reminder lists as a JSON array of names."
    )

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let store = try await RemindersAccess.requestAccess()
            let names = store.calendars(for: .reminder).map { $0.title }.sorted()
            try ReminderJSON.emitNames(names, toFile: output)
        } catch {
            try ReminderJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

struct RemindersTodayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "today",
        abstract: "Print incomplete reminders due today (or already overdue) as a JSON array."
    )

    @Option(name: [.customShort("l"), .long], help: "Filter to a specific list by name (repeatable).")
    var list: [String] = []

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let store = try await RemindersAccess.requestAccess()
            // From the dawn of time up to end-of-today: catches overdue + due-today.
            let endOfToday = Calendar.current.date(
                byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())
            )!
            let reminders = try await RemindersAccess.fetchIncomplete(
                store: store, from: nil, to: endOfToday, listNames: list
            )
            try ReminderJSON.emit(reminders, toFile: output)
        } catch {
            try ReminderJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

struct RemindersOverdueCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "overdue",
        abstract: "Print incomplete reminders whose due date is before now."
    )

    @Option(name: [.customShort("l"), .long], help: "Filter to a specific list by name (repeatable).")
    var list: [String] = []

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let store = try await RemindersAccess.requestAccess()
            let reminders = try await RemindersAccess.fetchIncomplete(
                store: store, from: nil, to: Date(), listNames: list
            )
            try ReminderJSON.emit(reminders, toFile: output)
        } catch {
            try ReminderJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

struct RemindersPendingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pending",
        abstract: "Print all incomplete reminders (any due date, including no due date)."
    )

    @Option(name: [.customShort("l"), .long], help: "Filter to a specific list by name (repeatable).")
    var list: [String] = []

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let store = try await RemindersAccess.requestAccess()
            let reminders = try await RemindersAccess.fetchIncomplete(
                store: store, from: nil, to: nil, listNames: list
            )
            try ReminderJSON.emit(reminders, toFile: output)
        } catch {
            try ReminderJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

struct RemindersAllCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "all",
        abstract: "Print every reminder, completed or not. Use sparingly — can be slow on large lists."
    )

    @Option(name: [.customShort("l"), .long], help: "Filter to a specific list by name (repeatable).")
    var list: [String] = []

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let store = try await RemindersAccess.requestAccess()
            let reminders = try await RemindersAccess.fetchAll(store: store, listNames: list)
            try ReminderJSON.emit(reminders, toFile: output)
        } catch {
            try ReminderJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

struct RemindersAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a new reminder. Prints the created reminder as a single-object JSON."
    )

    @Option(name: [.customShort("t"), .long], help: "Reminder title (required).")
    var title: String

    @Option(name: [.customShort("l"), .long], help: "List name to add to (default: Reminders default list).")
    var list: String?

    @Option(name: [.customShort("d"), .long], help: "Due date/time. Accepts YYYY-MM-DD or YYYY-MM-DDTHH:MM (local TZ).")
    var due: String?

    @Option(name: [.customShort("n"), .long], help: "Optional notes.")
    var notes: String?

    @Option(name: [.customShort("p"), .long], help: "Priority 0-9 (0=none, 1=high, 5=medium, 9=low).")
    var priority: Int = 0

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout.")
    var output: String?

    func run() async throws {
        do {
            let store = try await RemindersAccess.requestAccess()

            let target: EKCalendar
            if let listName = list {
                guard let match = store.calendars(for: .reminder).first(where: { $0.title == listName }) else {
                    throw CLIError("No reminder list named '\(listName)'. Use `clawbridge reminders list-lists` to see available lists.")
                }
                target = match
            } else {
                guard let def = store.defaultCalendarForNewReminders() else {
                    throw CLIError("No default reminder list configured.")
                }
                target = def
            }

            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = target
            reminder.notes = notes
            reminder.priority = priority

            if let dueStr = due {
                guard let dueDate = DateParsing.parseFlexible(dueStr) else {
                    throw CLIError("Invalid --due value: '\(dueStr)'. Expected YYYY-MM-DD or YYYY-MM-DDTHH:MM.")
                }
                let components: Set<Calendar.Component>
                if dueStr.contains("T") {
                    components = [.year, .month, .day, .hour, .minute]
                } else {
                    components = [.year, .month, .day]
                }
                reminder.dueDateComponents = Calendar.current.dateComponents(components, from: dueDate)
            }

            do {
                try store.save(reminder, commit: true)
            } catch {
                throw CLIError("Failed to save reminder: \(error.localizedDescription)")
            }

            try ReminderJSON.emit([reminder], toFile: output)
        } catch {
            try ReminderJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

// MARK: - Helpers

enum RemindersAccess {
    static func requestAccess() async throws -> EKEventStore {
        let store = EKEventStore()
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToReminders()
        } catch {
            throw CLIError("Failed to request reminders access: \(error.localizedDescription)")
        }
        guard granted else {
            throw CLIError(
                "Reminders access denied. Run `clawbridge permissions` to trigger the system "
                + "prompt, or grant Reminders access to Clawbridge in System Settings → "
                + "Privacy & Security → Reminders."
            )
        }
        return store
    }

    static func filteredCalendars(store: EKEventStore, listNames: [String]) -> [EKCalendar]? {
        let all = store.calendars(for: .reminder)
        if listNames.isEmpty { return nil }
        let matches = all.filter { listNames.contains($0.title) }
        return matches  // empty list is a valid signal for "no match"
    }

    static func fetchIncomplete(
        store: EKEventStore,
        from: Date?,
        to: Date?,
        listNames: [String]
    ) async throws -> [EKReminder] {
        let cals = filteredCalendars(store: store, listNames: listNames)
        if let cals = cals, cals.isEmpty { return [] }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: from, ending: to, calendars: cals
        )
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { result in
                cont.resume(returning: (result ?? []).sorted(by: ReminderSort.byDue))
            }
        }
    }

    static func fetchAll(store: EKEventStore, listNames: [String]) async throws -> [EKReminder] {
        let cals = filteredCalendars(store: store, listNames: listNames)
        if let cals = cals, cals.isEmpty { return [] }
        let predicate = store.predicateForReminders(in: cals)
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { result in
                cont.resume(returning: (result ?? []).sorted(by: ReminderSort.byDue))
            }
        }
    }
}

enum ReminderSort {
    static func byDue(_ lhs: EKReminder, _ rhs: EKReminder) -> Bool {
        let l = lhs.dueDateComponents?.date ?? Date.distantFuture
        let r = rhs.dueDateComponents?.date ?? Date.distantFuture
        if l != r { return l < r }
        return (lhs.title ?? "") < (rhs.title ?? "")
    }
}

extension DateParsing {
    static func parseFlexible(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone.current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = s.contains("T") ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return fmt.date(from: s)
    }
}

enum ReminderJSON {
    static func emit(_ reminders: [EKReminder], toFile: String?) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone.current

        let payload: [[String: Any]] = reminders.map { r in
            var dict: [String: Any] = [
                "title": r.title ?? "",
                "list": r.calendar?.title ?? "",
                "completed": r.isCompleted,
                "priority": r.priority,
            ]
            if let due = r.dueDateComponents?.date {
                dict["due"] = iso.string(from: due)
                // Whether due is date-only or date+time:
                let hasTime = r.dueDateComponents?.hour != nil
                dict["dueHasTime"] = hasTime
            }
            if let completion = r.completionDate {
                dict["completedAt"] = iso.string(from: completion)
            }
            if let notes = r.notes, !notes.isEmpty { dict["notes"] = notes }
            if let url = r.url?.absoluteString, !url.isEmpty { dict["url"] = url }
            dict["id"] = r.calendarItemIdentifier
            return dict
        }

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try write(data, toFile: toFile)
    }

    static func emitNames(_ names: [String], toFile: String?) throws {
        let data = try JSONSerialization.data(
            withJSONObject: names,
            options: [.prettyPrinted]
        )
        try write(data, toFile: toFile)
    }

    static func emitError(_ error: Error, toFile: String?) throws {
        let message: String
        if let cli = error as? CLIError {
            message = cli.message
        } else {
            message = error.localizedDescription
        }
        let payload: [String: Any] = ["error": message]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try write(data, toFile: toFile)
    }

    private static func write(_ data: Data, toFile: String?) throws {
        if let path = toFile {
            try data.write(to: URL(fileURLWithPath: path))
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
