# Coffee Work

**v1.8 source release.** Build from source. An ad-hoc signature is produced
locally; a Developer ID-signed, notarized download is not available. See the
repository [releases](https://github.com/myconstance1999-pixel/coffee-work/releases)
for published source releases, including [v1.8](https://github.com/myconstance1999-pixel/coffee-work/releases/tag/v1.8) and the [v1.5 source release](https://github.com/myconstance1999-pixel/coffee-work/releases/tag/v1.5).

**中文用户手册：[docs/USER_GUIDE.zh-CN.md](docs/USER_GUIDE.zh-CN.md)** —
a practical Simplified Chinese guide to what Coffee does when Codex stops, the Mac
sleeps, locks, or loses power. The previous 1.5 guide is preserved at
[docs/history/USER_GUIDE.v1.5.zh-CN.md](docs/history/USER_GUIDE.v1.5.zh-CN.md).

Coffee Work is a small native macOS menu-bar utility. It offers three independent
awake sources, each with its own start/stop control, and it does not manage Codex
tasks:

* an **automatic background** awake source for a local Codex desktop task;
* a **manual background timer** with a fixed deadline;
* an explicit **display hold** that also keeps the screen on.

It is a self-contained menu-bar app plus a shell helper and a Codex hook receiver.

Coffee Work is an independent project. It is **not** OpenAI Codex itself, is not
produced by or affiliated with OpenAI, and claims no official status. License
terms are available under [MIT](LICENSE).

## The three awake sources

The manual background timer, the explicit display hold, and the automatic
background source can all run at the same time. Starting or stopping one never
changes another source's deadline or process, and the menu carries one truthful
status and one stop action per source.

1. **Automatic background awake (idle sleep only).** Holds a bounded
   `caffeinate -i` assertion only when the Auto toggle is on, power is external
   (AC), the current console session is a trusted active or locked session, and a
   supported local hook reports a valid Codex *desktop* task actively working.
   When the last working turn stops on an unlocked session, the assertion is held
   for a **120 second grace period** and then released. A locked session with no
   valid working task, a waiting or otherwise non-working task, an invalid
   snapshot, sleep, an inactive or unknown session, or battery/unknown power
   releases it immediately.
2. **Manual background timer (idle sleep only).** `1 / 4 / 8 / custom 1..24`
   whole hours. It is an explicit request, so it **ignores power** and runs on
   battery too. It is still suspended while the session is locked, asleep,
   inactive, or unknown, and it resumes with only the remaining time: the
   original absolute deadline never moves, and a timer that expires while paused
   is released, not revived.
3. **Explicit display hold (`-d -i`).** `30 minutes / 1 / 4 / 8 / custom 1..24`
   whole hours, plus **until I turn it off**. It is offered on battery and in Low
   Power Mode because its only eligibility rule is the current unlocked active
   session — never the power source or energy mode — and Coffee writes no energy
   setting. A finite display hold keeps one absolute deadline that survives
   pauses unchanged and never revives after expiry or cancellation. The
   until-stopped request is a distinct, **memory-only** state: it is covered by
   bounded `-d -i -t 300 -w <app pid>` leases renewed every 240 seconds, so a hung
   app can never leave a stray indefinite child behind, and quitting or restarting
   Coffee does not restore it. Every display child uses
   `-d -i -t <= 86400 -w <app pid>`, never `-u` or `-s` and never simulated input.

Only *system idle sleep* is prevented by the background sources. The display
sources additionally keep the display on. Coffee never locks, unlocks, sleeps,
or wakes the Mac on its own, and a user-invoked screen saver or a lock always
wins.

## Menu

The compact menu shows a read-only status line, the `自动保持后台工作（接通电源）`
toggle (the only persisted setting), one start/stop row per awake source, an
`立即启动屏保` row, a `更多状态与日志` submenu, and Quit. The display submenu is
offered as `保持屏幕显示` only while no display hold is configured; while one runs
the menu shows its own `结束屏幕显示保持` row instead.

* **`立即启动屏保`** opens the installed system ScreenSaverEngine through
  NSWorkspace. It ends only this app's explicit display hold so Coffee does not
  fight your choice, leaves the background and automatic awake sources untouched,
  writes no screen saver, timeout, password or energy setting, and never claims
  the screen saver is running when the launcher fails.
* **Lock, sleep, inactive, or unknown sessions pause the manual and display
  sources.** Sleep, inactive, and lock are tracked as separate latches, so waking
  while the screen is still locked cannot resume a manual or display assertion.
  Automatic background awake uses the verified-work rule above.
* **`更多状态与日志`** shows the connected-task state, the automatic-awake reason,
  the read-only power source and energy mode, and two diagnostic rows: view the
  local diagnostic log, or export it.

## Build and install

* [Build](#build) — `./build.sh` produces `dist/Codex Work Mode.app` from this
  tree only.
* [Install (manual)](#install-manual) — user-local, fully manual steps; nothing
  is installed, launched, or registered automatically.
* [Upgrading](#upgrading) — safe steps that account for a running display hold,
  a manual timer, and Codex tasks you do not want to interrupt.
* [Hook setup](#install-manual) — the receiver is enabled through your own
  Codex hooks interface in step 5 of the install guide.
* [Testing](#testing) and [CONTRIBUTING.md](CONTRIBUTING.md) — how to run the
  isolated test suite.

See [RELEASE_NOTES.md](RELEASE_NOTES.md) for the v1.8 source-release notes,
including known verification gaps and limits.

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

This builds `dist/Codex Work Mode.app` from this tree only, stamps version 1.8,
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

1. **If a copy is already installed, settle its awake sources first, and do not
   interrupt a Codex task you want to keep running.** Coffee has more than one
   independent hold, so check both the manual helper and the app's own display
   hold:
   * Ask the installed helper for its manual background timer:
     `/bin/zsh "$HOME/Library/Application Support/Codex Work Mode/toggle.zsh" status`.
     If it reports `ON` or `PAUSED`, let its original deadline finish and check
     again, or stop it explicitly with the helper's `off` command if you do not
     want to wait. Proceed only after it reports `OFF`.
   * A running **display hold** is owned by the app itself and is shown in the
     menu as `结束屏幕显示保持`. Let it finish or choose that row to end it. Then
     **quit the app** with its Quit row. Quitting the app also releases the
     display hold, the manual background timer, and the automatic assertion.
   * If a task must continue without a gap in awake protection, postpone this
     manual upgrade until that task finishes. Quitting Coffee releases its
     protection even though it does not stop the task process. Do not kill
     Codex or weaken security settings to complete an upgrade.
   If the helper is not installed yet there is no manual timer to check.

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
   needed at runtime.

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

### Upgrading

Back up the existing app and support files before replacement. Check both the
manual timer and the app-owned display request, including paused requests.
Normal Quit cancels both and releases automatic background protection.

If a running task depends on that protection, wait until it completes before
following these manual steps. Keeping the task process alive alone does not
prevent macOS from sleeping during an upgrade. Preserve existing desktop/login
entries and hook trust; an upgrade does not require stopping Codex, changing
security settings, or adding duplicate hooks.

## How the awake rules work

Manual/display requests and automatic background awake have distinct session
eligibility rules, described below.

### Automatic background awake

Automatic awake holds an assertion only when all of these are true:

* the Auto awake toggle is on;
* power is external (AC);
* the current console session is trusted: the active unlocked session, **or** a
  locked session only while a supported local hook reports valid, actively
  working Codex desktop work;
* at least one known Codex turn is actively working.

When the last turn stops on an unlocked session, the assertion is held for a
**120 second grace period** and then released. New work cancels the grace
immediately. On a locked session, a finished turn, a waiting or otherwise
non-working task, or an invalid/unknown snapshot releases the assertion
immediately with no grace. Loss of external power, sleep, an inactive session, or
an unknown session also releases it at once.

### Why "the app is just open" is not work

The activity snapshot is written only by the Codex desktop hooks.
`UserPromptSubmit` opens a turn; `PreToolUse`/`PostToolUse` only refresh an
already-known turn and never invent one; `PermissionRequest` marks a turn
`waiting` (awaiting approval, not working); `Stop`/`Interrupt` close exactly one
turn; `SessionEnd` clears one session. Unknown or malformed events are ignored.

**Work mode and the composer dot are not detected when they do not go through the
supported local desktop hooks.** A standalone CLI, a headless process, a cloud
task, or a Work/dot task without those local hook events does not trigger
automatic awake, and Coffee does not inspect cloud-side progress. The manual
background timer and the display hold remain available for those cases.

### Manual background timer and display hold

Both are explicit requests. The manual background timer ignores power; the
display hold also ignores power, and is allowed on battery and in Low Power Mode
because it is a user choice, not an energy-policy change. Both are suspended
while the session is locked, asleep, inactive, or unknown and resume only when it
is active and unlocked again. Suspension keeps the **original absolute
deadline**: resuming never extends the timer, and a timer that reaches its
deadline while paused is released rather than revived. The until-stopped display
request is memory-only and is not restored after quitting or restarting Coffee.

### Screen saver, lock, and display are separate

A user-invoked screen saver (`立即启动屏保`) ends only the explicit display hold.
The background manual timer and the automatic source keep running, subject to the
same lock/sleep/session rules. A dark screen is never treated as a lock by the
background sources: display sleep is normal and does not release an idle-sleep
assertion. An actual lock pauses manual/display holds; automatic background
awake can remain eligible only under the verified-work rule above.

## Energy modes and power

Battery/AC energy modes (High Power, Low Power, Automatic) are **external system
preferences**. The app reads the current source and mode to display them; it
never configures, changes, or overrides them. The explicit display hold works on
battery and in Low Power Mode and does not turn Low Power Mode off. Every
power-related input is read-only: IOKit power-source change events and the
`IOPSCopyPowerSourcesInfo` sample, plus one read-only
`system_profiler SPPowerDataType -json` run and one read-only `pmset -g custom`
run at launch and each time the menu opens.

## Diagnostics and privacy

The hook receiver reads the hook event JSON from stdin and parses it with the
standard JSON decoder. Only three selected fields — `hook_event_name`,
`session_id`, and `turn_id` — are used to build the snapshot and its hashed
identifiers; no other field's value is stored or written. The local snapshot
contains the event name, **hashed** session and turn identifiers, timestamps,
and the desktop owner pid plus start signature. Prompt text, tool input, tool
output, working directory, transcript path, model, permission mode, and every
other payload field are never copied into the snapshot and never written.

The app and the receiver each keep a **bounded local diagnostic history** of
privacy-minimized metadata. The app writes
`…/Codex Work Mode/diagnostics/app.jsonl`; the receiver writes
`…/Codex Work Mode/codex-activity/diagnostics/hook.jsonl`. Each is limited to four
256 KiB files (one current plus three rotated), owner-only permissions, and a
whitelist of metadata field names — reasons, statuses, session/power labels,
hashed identities, owner pid, counts, exit/error codes, deadlines. Prompt, tool,
media, transcript and other payload content is never included, and an exception
message is never serialized. Logging is best-effort: a logging failure cannot
change an awake decision, hook output, or exit status. `导出诊断日志…` exports only
those bounded producer files, never arbitrary support files or raw payloads.
Network access is never used.

## Behavior limits

* The app does not wake the Mac when the lid is closed, does not force a
  clamshell-awake configuration, and does not prevent lid-close sleep.
* Only idle sleep is prevented by the background sources; display sleep, screen
  lock, and user-initiated sleep still happen normally. The display hold can be
  defeated by a user lock or screen saver, and it never unlocks the Mac.
* The helper never changes a lock, power, or security setting, and installs no
  login item, daemon, or privileged service.
* Behavior is not guaranteed across every macOS release; the validated target is
  the one listed above.

## Verification status and limits

Actual isolated **1.8 menu acceptance passed**, including independent concurrent
timers (manual background and explicit display), separate stop
actions, the until-stopped display request, and a custom 2-hour display timer.

### Hands-off native Computer Use trial — 2026-10-09

On 2026-10-09 a hands-off native Computer Use trial was run on this Mac without
touching the keyboard, trackpad, or Touch ID:

* **Explicit lock:** the instance was unlocked after about **2 seconds**, and a
  fresh Calculator action then computed `8 × 9 = 72`.
* **Display off + lock:** Computer Use woke the display and unlocked the session,
  and a fresh Calculator action then computed `9 × 9 = 81`.
* **Screen saver + lock:** automatic unlock **failed twice**; the screen saver
  and lock remained, and the owner had to unlock manually.

These are **single unattended recovery successes, not sustained locked or
display-off GUI work, and not a reliability guarantee.** They do not show that
Computer Use can keep working while the session stays locked or the display stays
off. **Coffee does not unlock the Mac and does not type a password.** The
recovery in that trial was performed by the current Computer Use environment, not
by Coffee. **No security or Locked Use setting was changed** in that trial, and
this project recommends no such change.

Physical battery/Low-Power long display hold, physical unplug/replug power
transitions, lid-close behavior, and fast-user-switch remain **unverified** and
are not claimed. A power
transition while the menu is open was also unverified in 1.5; the common-run-loop
power source is asserted in source and by isolated tests, not by a physical
transition.

Automated isolated tests cover the awake-eligibility gate, the automatic awake
state machine, the manual and display timers, the activity snapshot parser and
its uncertainty states, the receiver's owner filter, privacy and bounded
diagnostics, and the helper lifecycle. They do not replace the physical checks
listed above.

## Acceptance summary

Automated isolated tests exercise the shared awake-eligibility gate, the
automatic awake state machine (including the locked-with-verified-work case and
the 120 second grace), the manual and explicit-display timer contracts, the
activity snapshot parser, the receiver's owner filter, privacy and bounded
diagnostic behavior, and the helper lifecycle. Actual **lock, sleep,
wake-while-locked, and unlock** transitions passed on the current development Mac
on 2026-09-30, so pause and resume across those transitions is confirmed.

## Testing

See [CONTRIBUTING.md](CONTRIBUTING.md). The focused entry point is:

```sh
./tests/validate.sh
```

## License

Licensed under the [MIT License](LICENSE).

Copyright (c) 2026 myconstance1999-pixel.
