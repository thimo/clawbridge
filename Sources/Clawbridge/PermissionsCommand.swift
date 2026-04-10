import ArgumentParser
import EventKit
import Foundation

struct PermissionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Request TCC permissions interactively (run once after installing or rebuilding)."
    )

    func run() async throws {
        print("Clawbridge is requesting macOS permissions.")
        print("If a system dialog appears, click \"Allow Full Access\".")
        print("")
        print("Requesting Calendar access...")

        let store = EKEventStore()
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToEvents()
        } catch {
            print("  ✗ Error while requesting access: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        if granted {
            print("  ✓ Calendar: granted")
        } else {
            print("  ✗ Calendar: denied")
            print("")
            print("To fix: open System Settings → Privacy & Security → Calendars,")
            print("then enable Clawbridge in the list. If Clawbridge is not shown,")
            print("re-run this command from a GUI-session terminal (iTerm, Terminal.app).")
            throw ExitCode.failure
        }

        // As a quick smoke test, try to fetch calendars so any additional TCC
        // flags (fine-grained calendar access in macOS 14+) are exercised.
        let cals = store.calendars(for: .event)
        print("")
        print("Detected \(cals.count) calendar(s):")
        for cal in cals.sorted(by: { $0.title < $1.title }) {
            print("  - \(cal.title)")
        }
    }
}
