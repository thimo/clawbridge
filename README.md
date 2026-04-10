# Clawbridge

A small Swift CLI, wrapped in a proper macOS `.app` bundle, that gives scheduled automation reliable access to local macOS services behind TCC (Transparency, Consent & Control).

Built because invoking CLI tools like `icalBuddy` from `launchd` on modern macOS is flaky: TCC gates EventKit per-binary and unbundled CLIs can't get stable grants. Wrapping the tool in an `.app` with proper `Info.plist` usage descriptions solves that — the grant sticks and scheduled jobs can depend on it.

Currently implements `calendar` (today / range). Designed to grow into other TCC-gated areas (Reminders, Contacts, Mail automation, etc.) by adding subcommands to the same bundle.

## Install

```sh
bash build.sh
```

This:
- builds the release binary with `swift build -c release`
- renders the app icon from `Resources/make-icon.swift`
- assembles `Clawbridge.app` with `Info.plist`
- ad-hoc signs with `codesign -s -`
- installs to `~/Applications/Clawbridge.app`
- symlinks `~/.local/bin/clawbridge` → the inner binary

Requirements: macOS 14+, Xcode Command Line Tools (Swift 6 toolchain).

## First-run permissions

After install, grant Calendar access:

```sh
clawbridge permissions
```

If macOS doesn't prompt (it may silently inherit your terminal's grant), force a clean attribution:

```sh
tccutil reset Calendar nl.thimo.clawbridge
open -a Clawbridge --args permissions
```

Watch for the system dialog, click **Allow Full Access**.

## Usage

All commands emit JSON arrays. Use with `jq`.

```sh
# Today's events across all calendars
clawbridge calendar today

# Today's events from a specific calendar (repeatable)
clawbridge calendar today --calendar "Work"

# An inclusive date range
clawbridge calendar range --from 2026-04-10 --to 2026-04-16 --calendar "Work"

# Write JSON to a file instead of stdout (see "The scheduled-job gotcha" below)
clawbridge calendar today --output /tmp/events.json
```

Event schema:

```json
{
  "title": "Team standup",
  "calendar": "Work",
  "allDay": false,
  "start": "2026-04-10T09:00:00+02:00",
  "end":   "2026-04-10T09:15:00+02:00",
  "location": "optional",
  "notes":    "optional",
  "url":      "optional",
  "attendees": ["optional", "list"]
}
```

On failure the output is a single object with an `error` key instead of an array — consumers can branch with `jq 'type == "object" and has("error")'`.

## The scheduled-job gotcha

Calling `clawbridge` directly from a scheduled job (`launchd` → shell → `clawbridge`) **works**. Calling it from a scheduled job that wraps another unsigned CLI tool (`launchd` → shell → `claude` → shell → `clawbridge`) **does not** — TCC attributes the request to the outer CLI as "responsible process", not to clawbridge, and denies access.

Fix: launch clawbridge through LaunchServices so it becomes a top-level process, not a child of the outer CLI:

```sh
tmpf=$(mktemp).json
open -W -a ~/Applications/Clawbridge.app --args calendar today --output "$tmpf"
cat "$tmpf"
rm "$tmpf"
```

`open -W` waits for the app to exit; `--args` forwards CLI flags; `--output` is needed because `open -a` detaches stdout.

The author uses clawbridge from Claude Code automations via a wrapper like the one above, kept at `~/.claude/scripts/clawbridge.sh`. It's not shipped in this repo because the path is specific to that setup — copy the snippet above into your own automations.

## Extending

Add a new subcommand by:
1. Create a new `*Command.swift` file in `Sources/Clawbridge/`.
2. Register it in `Clawbridge.swift`'s `subcommands` array (or nested under an existing parent command).
3. Add the matching TCC usage description key to `Resources/Info.plist` if the new feature touches a new privacy category (`NSRemindersFullAccessUsageDescription`, `NSContactsUsageDescription`, etc.).
4. Make sure the command supports `--output FILE` for parity with existing subcommands, so the `open -W -a` pattern can consume it.
5. Rebuild with `bash build.sh` and re-grant any new TCC categories with `clawbridge permissions`.

## Layout

```
.
├── Package.swift            # Swift Package manifest
├── Sources/Clawbridge/
│   ├── Clawbridge.swift     # @main entry, top-level command, subcommand registration
│   ├── CalendarCommand.swift
│   └── PermissionsCommand.swift
├── Resources/
│   ├── Info.plist           # Bundle identity + TCC usage descriptions
│   └── make-icon.swift      # Renders the app iconset from Core Graphics
├── build.sh                 # swift build → bundle → sign → install
└── build/                   # Build artifacts (gitignored)
```
