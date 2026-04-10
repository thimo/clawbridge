import ArgumentParser

@main
struct Clawbridge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clawbridge",
        abstract: "Local macOS bridge for scheduled automation.",
        version: "0.1.0",
        subcommands: [CalendarCommand.self, PermissionsCommand.self]
    )
}
