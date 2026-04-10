import ArgumentParser
import EventKit
import Foundation

// Umbrella `calendar` command; all work happens in subcommands.
struct CalendarCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Query the macOS Calendar via EventKit.",
        subcommands: [CalendarTodayCommand.self, CalendarRangeCommand.self]
    )
}

// MARK: - Subcommands

struct CalendarTodayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "today",
        abstract: "Print today's events as a JSON array."
    )

    @Option(name: [.customShort("c"), .long], help: "Filter to a specific calendar by name (repeatable).")
    var calendar: [String] = []

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout (used when launched via `open -a`).")
    var output: String?

    func run() async throws {
        do {
            let store = try await CalendarAccess.requestAccess()
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
            let events = CalendarAccess.fetchEvents(store: store, from: start, to: end, calendarNames: calendar)
            try EventJSON.emit(events, toFile: output)
        } catch {
            try EventJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

struct CalendarRangeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "range",
        abstract: "Print events in an inclusive [from..to] date range as a JSON array."
    )

    @Option(name: .long, help: "Start date (YYYY-MM-DD, inclusive).")
    var from: String

    @Option(name: .long, help: "End date (YYYY-MM-DD, inclusive).")
    var to: String

    @Option(name: [.customShort("c"), .long], help: "Filter to a specific calendar by name (repeatable).")
    var calendar: [String] = []

    @Option(name: [.customShort("o"), .long], help: "Write JSON to this file instead of stdout (used when launched via `open -a`).")
    var output: String?

    func run() async throws {
        do {
            guard let fromDate = DateParsing.parseYMD(from) else {
                throw CLIError("Invalid --from date: '\(from)'. Expected YYYY-MM-DD.")
            }
            guard let toDate = DateParsing.parseYMD(to) else {
                throw CLIError("Invalid --to date: '\(to)'. Expected YYYY-MM-DD.")
            }
            let store = try await CalendarAccess.requestAccess()
            let start = Calendar.current.startOfDay(for: fromDate)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: toDate))!
            let events = CalendarAccess.fetchEvents(store: store, from: start, to: end, calendarNames: calendar)
            try EventJSON.emit(events, toFile: output)
        } catch {
            try EventJSON.emitError(error, toFile: output)
            throw ExitCode.failure
        }
    }
}

// MARK: - Helpers

enum CalendarAccess {
    static func requestAccess() async throws -> EKEventStore {
        let store = EKEventStore()
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToEvents()
        } catch {
            throw CLIError("Failed to request calendar access: \(error.localizedDescription)")
        }
        guard granted else {
            throw CLIError(
                "Calendar access denied. Launch Clawbridge.app once from Finder "
                + "to trigger the system permission prompt, or grant Calendar access "
                + "to Clawbridge in System Settings → Privacy & Security → Calendars."
            )
        }
        return store
    }

    static func fetchEvents(
        store: EKEventStore,
        from: Date,
        to: Date,
        calendarNames: [String]
    ) -> [EKEvent] {
        let all = store.calendars(for: .event)
        let filtered: [EKCalendar]?
        if calendarNames.isEmpty {
            filtered = nil
        } else {
            let matches = all.filter { calendarNames.contains($0.title) }
            // If no calendars match the filter, EventKit's predicate treats nil as
            // "all calendars" — we want the opposite (empty result), so pass a
            // non-nil empty list. Predicate API doesn't accept empty, so return
            // [] at the fetch level instead.
            if matches.isEmpty { return [] }
            filtered = matches
        }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: filtered)
        return store.events(matching: predicate).sorted { lhs, rhs in
            lhs.startDate < rhs.startDate
        }
    }
}

enum DateParsing {
    static func parseYMD(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: s)
    }
}

enum EventJSON {
    static func emit(_ events: [EKEvent], toFile: String?) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone.current

        let payload: [[String: Any]] = events.map { ev in
            var dict: [String: Any] = [
                "title": ev.title ?? "",
                "calendar": ev.calendar?.title ?? "",
                "allDay": ev.isAllDay,
                "start": iso.string(from: ev.startDate),
                "end": iso.string(from: ev.endDate),
            ]
            if let loc = ev.location, !loc.isEmpty { dict["location"] = loc }
            if let url = ev.url?.absoluteString, !url.isEmpty { dict["url"] = url }
            if let notes = ev.notes, !notes.isEmpty { dict["notes"] = notes }
            if let attendees = ev.attendees, !attendees.isEmpty {
                dict["attendees"] = attendees.compactMap { $0.name }
            }
            return dict
        }

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try write(data, toFile: toFile)
    }

    // On failure, write a single-object error JSON so consumers launched via
    // `open -a` (no stdout visibility) can still detect the failure by
    // checking whether the output is an object with an "error" key.
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

struct CLIError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
