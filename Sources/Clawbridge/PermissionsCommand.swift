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

        let store = EKEventStore()
        var anyFailed = false

        // ---- Calendar ----
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

        // ---- Reminders ----
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

        // ---- Mail (AppleScript / Automation) ----
        // We don't pre-flight Automation TCC: macOS triggers the prompt the
        // first time we actually talk to Mail.app. Just remind the user.
        print("Mail (AppleScript): no pre-flight check; the macOS prompt to")
        print("  \"control Mail\" will appear the first time `clawbridge mail …`")
        print("  is run. Make sure Mail.app is running.")

        if anyFailed {
            print("")
            print("To fix denied permissions: System Settings → Privacy & Security → ")
            print("Calendars / Reminders, enable Clawbridge. If Clawbridge is missing,")
            print("re-run this command from a GUI-session terminal (iTerm, Terminal.app).")
            throw ExitCode.failure
        }
    }
}
