# Coffee Work

**v1.5 source preview.** Build from source. A Developer ID-signed, notarized
download is not available. See the [v1.5 source release](https://github.com/myconstance1999-pixel/coffee-work/releases/tag/v1.5).

Coffee Work is a small native macOS menu-bar utility that keeps a Mac from going
to *system idle sleep* while you are working — automatically while a local Codex
desktop task is running, and manually for a bounded timer. It is a self-contained
menu-bar app plus a shell helper and a Codex hook receiver.

Coffee Work is an independent project. It is **not** OpenAI Codex itself, is not
produced by or affiliated with OpenAI, and claims no official status. License
terms are available under [MIT](LICENSE).

## The four rules

1. **Automatic awake requires all four conditions at once.** The Auto awake
   toggle is on, power is external (AC), the console session is active and
   unlocked past login, and a valid Codex *desktop* task is actively working.
2. **A 120 second completion grace period.** After the last working turn stops,
   the assertion is held for 120 seconds and then released; new work cancels the
   grace immediately. Loss of external power, lock, sleep, or an inactive or
   unknown session overrides the grace and releases automatic awake immediately.
3. **Battery allows normal sleep, except for a manual override.** Automatic awake
   never holds on battery, an unknown source, or AC power loss. The manual timer
   is an explicit request, so it keeps the Mac awake on battery too.
4. **Lock and sleep pause both awake sources, and a manual timer keeps its
   absolute deadline.** Any assertion is suspended while the session is locked,
   asleep, inactive, or unknown, and resumes only when it is active and unlocked
   again. Resuming never extends a manual timer; a timer that reaches its
   deadline while paused is released, not revived.

## Build and install

* [Build](#build) — `./build.sh` produces `dist/Codex Work Mode.app` from this
  tree only.
* [Install (manual)](#install-manual) — user-local, fully manual steps; nothing
  is installed, launched, or registered automatically.
* [Hook setup](#install-manual) — the receiver is enabled through your own
  Codex hooks interface in step 5 of the install guide.
* [Testing](#testing) and [CONTRIBUTING.md](CONTRIBUTING.md) — how to run the
  isolated test suite.

See [RELEASE_NOTES.md](RELEASE_NOTES.md) for the v1.5 source-preview notes,
including known verification gaps.

## What it does

* **Automatic awake.** While a local Codex *desktop* task is working, the app
  holds one bounded idle-sleep assertion, then keeps it for a 120 second grace
  period after the last turn stops.
* **Manual awake.** A `1 / 4 / 8 / custom` hour-style timer, started and stopped
  from the menu, backed by the installed helper.
* **Read-only visibility.** The menu shows the current power source and the
  active energy mode, plus whether automatic awake is holding and why.

Only *system idle sleep* is prevented. The display is never held on, so the
screen may turn off normally; a dark screen is never treated as a screen lock.
The app never locks, unlocks, sleeps, or wakes the Mac on its own.

## Requirements

* macOS 13.0 or later. The currently validated target is Apple Silicon
  (`arm64-apple-macosx13.0`); other configurations are not claimed.
* The system Python 3 at `/usr/bin/python3` for the hook receiver.
* A Codex desktop app that ships the bundled `codex` executable under
  `/Applications/ChatGPT.app` or `/Applications/Codex.app`, and a supported user
  hooks interface. The receiver supports only those exact desktop-owned bundled
  paths; a standalone, headless, or nested CLI `codex` is excluded.
* Xcode command line tools (`swiftc`, `codesign`, `vtool`) to build.

## Build

```sh
./build.sh
```

This builds `dist/Codex Work Mode.app` from this tree only, stamps version 1.5,
signs it ad-hoc, and stages the receiver, the helper, and a hooks template
rendered for your home directory. It does not install, launch, trust, or
register anything, and it never touches your live Codex or Application Support
files.

The ad-hoc signature is a local integrity signature for development. It is
**not** Developer ID signing and **not** notarization, so macOS Gatekeeper will
treat the app as unsigned by an identified developer. No quarantine or
security-bypass command is recommended or required by this project.

## Install (manual)

Nothing below happens automatically. Install for your own user account only; no
administrator access is used.

1. **If a copy is already installed, check the manual timer first.**
   A normal Quit cancels an active manual timer, so do this before you quit or
   replace anything. Ask the installed helper for its status:

   ```sh
   /bin/zsh "$HOME/Library/Application Support/Codex Work Mode/toggle.zsh" status
   ```

   If it reports `ON` or `PAUSED`, let its original deadline finish and check
   again. Proceed only after it reports `OFF`. If you deliberately want to
   cancel the timer instead, run:

   ```sh
   /bin/zsh "$HOME/Library/Application Support/Codex Work Mode/toggle.zsh" off
   /bin/zsh "$HOME/Library/Application Support/Codex Work Mode/toggle.zsh" status
   ```

   Only then **quit any running copy of the app**. If the helper is not
   installed yet there is no timer to check, and you can quit the app directly.

2. **Install the app.** Create the user-local folder, back up any existing
   bundle, and copy the new one. All paths are quoted because the bundle name
   contains spaces:

   ```sh
   /bin/mkdir -p "$HOME/Applications"
   if [ -e "$HOME/Applications/Codex Work Mode.app" ]; then
     /usr/bin/ditto "$HOME/Applications/Codex Work Mode.app" \
             "$HOME/Applications/Codex Work Mode.app.backup-$(/bin/date +%Y%m%d%H%M%S)"
   fi
   /bin/cp -R "dist/Codex Work Mode.app" "$HOME/Applications/"
   ```

3. **Install the helper and receiver.** The app depends on the helper being
   present, so this step is required. Back up any existing installed copies,
   then create the support folder and copy both files (the quotes matter — the
   folder name contains a space):

   ```sh
   support="$HOME/Library/Application Support/Codex Work Mode"
   stamp=$(/bin/date +%Y%m%d%H%M%S)
   /bin/mkdir -p "$support"
   if [ -f "$support/toggle.zsh" ]; then
     /bin/cp -p "$support/toggle.zsh" "$support/toggle.zsh.backup-$stamp"
   fi
   if [ -f "$support/activity-hook.py" ]; then
     /bin/cp -p "$support/activity-hook.py" "$support/activity-hook.py.backup-$stamp"
   fi
   /bin/cp "dist/toggle.zsh" "$support/toggle.zsh"
   /bin/cp "dist/activity-hook.py" "$support/activity-hook.py"
   /bin/chmod 700 "$support/toggle.zsh" "$support/activity-hook.py"
   ```

   Copying the source tree into the support folder is optional and is not
   needed at runtime. For an upgrade, complete or explicitly cancel the timer
   first; these replacement steps assume the installed helper reports `OFF`.

4. **Render a hooks template for your account.**

   ```sh
   ./hooks/render-hooks.py --output /tmp/coffee-work-hooks.json
   ```

   Omit `--output` to print to stdout. The generator only ever creates a new
   file: it refuses an existing output, refuses any path that resolves inside a
   `.codex` directory, and never merges with or overwrites `~/.codex/hooks.json`.

5. **Merge and enable the seven Coffee handlers.** Open your existing
   `~/.codex/hooks.json` and, for each of the seven events — `UserPromptSubmit`,
   `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Stop`, `Interrupt`,
   `SessionEnd` — **append** the Coffee matcher entry from the rendered file to
   that event's existing array. If an event already has entries, keep every one
   of them and add the Coffee entry after them; if the event is absent, create
   it. Never replace a same-name event array, and never add a second JSON key
   with the same event name: duplicate keys can hide entries when parsed. Then select, review, and trust the seven Coffee handlers through
   your supported Codex hooks interface and make sure hooks are enabled. Hook
   trust is intentionally a user decision: this project does not bypass trust,
   downgrade security, or claim that every CLI version supports the same hooks
   surface.

6. **Launch the app** from `$HOME/Applications` and use the menu-bar cup.

## How the awake rules work

The app and the helper share one eligibility rule.

### Automatic awake

Automatic awake holds an assertion only when all of these are true:

* the Auto awake toggle is on;
* power is external (AC adapter);
* the current console session is active, past login, and unlocked;
* at least one known Codex turn is actively working.

When the last turn stops, the assertion is held for a **120 second grace
period** and then released. New work cancels the grace immediately. The grace is
overridden at once by any ineligible condition: **battery power, an unknown or
unavailable power source, a screen lock, or sleep**. New work cannot restart the
assertion while the Mac is ineligible.

### Manual awake

The manual timer is an explicit user request, so it **ignores power** — it runs
on battery too. It is still suspended while the session is locked, asleep,
inactive, or unknown, and it resumes automatically when the session becomes
active and unlocked again. Suspension keeps the **original absolute deadline**:
resuming never extends the timer, and a timer that reaches its deadline while
paused is released rather than revived.

Sleep, inactive, and lock are tracked as separate latches, so waking while the
screen is still locked cannot resume an assertion.

## Energy modes and power

Battery/AC energy modes (High Power, Low Power, Automatic) are **external system
preferences**. The app reads the current source and mode to display them; it
never configures, changes, or overrides them. Every power-related input is
read-only: IOKit power-source change events and the `IOPSCopyPowerSourcesInfo`
sample, plus one read-only `system_profiler SPPowerDataType -json` run and one
read-only `pmset -g custom` run at launch and each time the menu opens.

## Behavior limits

* The app does not wake the Mac when the lid is closed, does not force a
  clamshell-awake configuration, and does not prevent lid-close sleep.
* Only idle sleep is prevented; display sleep, screen lock, and user-initiated
  sleep still happen normally.
* The helper never changes a lock, power, or security setting, and installs no
  login item, daemon, or privileged service.
* Behavior is not guaranteed across every macOS release; the validated target is
  the one listed above.

## Privacy

The hook receiver reads the hook event JSON from stdin and parses it with the
standard JSON decoder. Only three selected fields — `hook_event_name`,
`session_id`, and `turn_id` — are used to build the snapshot and its hashed
identifiers; no other field's value is stored or written. The local snapshot
contains the event name, **hashed** session and turn identifiers, timestamps,
and the desktop owner pid plus start signature. Prompt text, tool input, tool
output, working directory, transcript path, model, permission mode, and every
other payload field are never copied into the snapshot and never written. No log
file is kept; exactly one current state file is published. Network access is
never used.

## Acceptance summary

Automated isolated tests exercise the awake-eligibility gate, the automatic
awake state machine, the activity snapshot parser, the receiver's owner filter
and privacy behavior, and the helper's lifecycle (pause, resume, legacy stand-in
records, and out-of-contract state). On 2026-09-30, actual **lock, sleep,
wake-while-locked, and unlock** transitions passed on the current development
Mac. Physical unplug/replug, a power transition with the menu open, lid-close,
and fast-user-switch remain unverified.

## Testing

See [CONTRIBUTING.md](CONTRIBUTING.md). The focused entry point is:

```sh
./tests/validate.sh
```

## License

Licensed under the [MIT License](LICENSE).

Copyright (c) 2026 myconstance1999-pixel.
