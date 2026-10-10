# Release Notes

## v1.8 — source release

This is a **source release** for people who build from source. A Developer
ID-signed, notarized download is not available. Local builds use ad-hoc signing.
It incorporates the locally accepted updates since the public v1.5 source preview.

### Behavior in v1.8

* The manual background timer, the explicit display hold, and automatic
  background awake are independent sources. Starting or stopping one never
  changes another source's deadline or process; the menu shows one status and one
  stop action per source.
* **Explicit display hold (`-d -i`):** 30 minutes, 1/4/8 hours, a custom
  whole-hour count from 1 through 24, and an until-stopped request. It is offered
  on battery and in Low Power Mode, because eligibility is the current unlocked
  active session alone and no OS energy setting is written.
* A finite display request keeps one absolute deadline that survives pauses
  unchanged and never revives after expiry or cancellation. The until-stopped
  request is memory-only, covered by bounded owner-tied
  `-d -i -t 300 -w <app pid>` leases renewed every 240 seconds, and is not
  restored after quitting or restarting the app. Every display child is
  `-d -i -t <= 86400 -w <app pid>`, never `-u` or `-s`.
* **Manual background timer:** 1/4/8 hours and custom 1..24 whole hours. It is an
  explicit request, so it ignores power and runs on battery, but it is suspended
  while the session is locked, asleep, inactive, or unknown and resumes with only
  the remaining time. Suspension keeps the original absolute deadline; a timer
  that reaches its deadline while paused is released, not revived.
* **Automatic background awake (idle sleep only):** holds only with the toggle on,
  external power, a trusted current session, and a supported local hook reporting
  valid actively working Codex desktop work. It may hold while the session is
  locked only in that state. A locked session with no valid work, a waiting or
  non-working task, or an invalid snapshot releases immediately with no grace; an
  unlocked completion is held for a 120 second grace period and then released,
  and new work cancels the grace immediately.
* Work mode and composer-dot tasks without the supported local desktop hooks are
  not auto-detected; a standalone CLI, a headless process, and cloud tasks are
  not auto-detected either. Use the manual background timer or the display hold
  for those.
* A user-invoked `立即启动屏保` row opens the installed system ScreenSaverEngine.
  It ends only the explicit display hold, leaves the background and automatic
  sources untouched, writes no screen saver, timeout, password or energy setting,
  and never claims the screen saver is running when the launcher fails.
* Sleep, inactive, and lock are separate latches, so waking while the screen is
  still locked cannot resume manual/display assertions. Automatic background
  awake remains governed by its verified-work rule.
* The app and the hook receiver keep bounded, privacy-minimized local diagnostic
  histories: four 256 KiB files per producer, owner-only permissions, and a
  metadata whitelist (reasons, statuses, session/power labels, hashed identities,
  owner pid, counts, exit/error codes, deadlines). Prompt, tool, media, transcript
  and other payload content is never included. `更多状态与日志` can view or export
  those bounded files.

### Computer Use limits — 2026-10-09

A hands-off native Computer Use trial was run on this Mac on 2026-10-09 without
touching the keyboard, trackpad, or Touch ID:

* **Explicit lock:** unlocked after about **2 seconds**, then a fresh Calculator
  action computed `8 × 9 = 72`.
* **Display off + lock:** Computer Use woke the display and unlocked, then a
  fresh Calculator action computed `9 × 9 = 81`.
* **Screen saver + lock:** automatic unlock **failed twice**; the screen saver and
  lock remained, and the owner had to unlock manually.

These are **single unattended recovery successes, not sustained locked or
display-off GUI work, and not a reliability guarantee.** **Coffee does not unlock
the Mac and does not type a password**; the recovery was performed by the current
Computer Use environment. **No security or Locked Use setting was changed**, and
none is recommended. Do not rely on unattended Computer Use while the screen
saver is running.

### Build and test from source

Build the staged app bundle:

```sh
./build.sh
```

Run the focused test suite (Swift parser and menu suites, receiver and privacy
tests, hooks-renderer tests, helper lifecycle tests, source-contract checks, and
the read-only session observer):

```sh
./tests/validate.sh
```

The build stages output in `dist/` and `build/` without installing the app or
changing hook trust, and it depends only on checked-in inputs. Tests run isolated
helper processes and temporary awake assertions, then clean up the processes they
own; they do not launch or replace the installed app. The helper lifecycle script
needs the real `/bin/ps`; in a sandbox that forbids `ps` it reports `BLOCKED` and
exits non-zero on purpose instead of substituting a fixture.

### Hook setup

The receiver is installed as one step of the manual install guide. Follow
[README.md](README.md) — "Install (manual)", step 5, and the
[Build and install](README.md#build-and-install) navigation — for rendering a
hooks template, merging the seven Coffee matcher entries, and enabling and
trusting them through your supported Codex hooks interface.

### Verification status

Actual isolated 1.8 menu acceptance passed, including independent concurrent
timers (manual background and explicit display), separate stop
actions, the until-stopped display request, and a custom 2-hour display timer.

Verified on the current development Mac (2026-09-30): actual **lock, sleep,
wake-while-locked, and unlock** transitions passed, so pause and resume across
those transitions is confirmed.

Still unverified and not claimed:

* physical battery or Low Power Mode with a long display hold;
* physical unplug / replug power transitions (and a power transition with the
  menu open);
* lid-close behavior;
* fast user switch.

Automated isolated tests cover the awake-eligibility gate, the automatic awake
state machine, the manual and display timer contracts, the activity snapshot
parser, the receiver's owner filter, privacy and bounded diagnostics, and the
helper lifecycle. They do not replace the physical checks listed above.

### Signing

The build signs the app **ad-hoc only**. That is a local integrity signature for
development; it is **not** Developer ID signing and **not** notarization.
macOS Gatekeeper will treat the app as unsigned by an identified developer, and
no quarantine or security-bypass command is recommended or required.

### Power settings are read-only

Battery/AC energy modes (High Power, Low Power, Automatic) are external system
preferences. The app reads the current source and mode to display them and never
configures, changes, or overrides them; the explicit display hold works on battery
and in Low Power Mode without turning Low Power Mode off. Every power-related
input is read-only: IOKit power-source change events, the
`IOPSCopyPowerSourcesInfo` sample, one read-only `system_profiler SPPowerDataType
-json` run, and one read-only `pmset -g custom` run at launch and whenever the
menu opens.

### License

Licensed under the [MIT License](LICENSE).

Copyright (c) 2026 myconstance1999-pixel.

## v1.5 — source preview

This is a **source preview** for people who build from source. A Developer
ID-signed, notarized download is not available. Local builds use ad-hoc signing.

### Behavior in v1.5

* Both awake sources share one eligibility rule. Any assertion requires an
  active, unlocked console session past login.
* Automatic awake holds only when the Auto awake toggle is on, power is
  external (AC), the session is eligible, and at least one known Codex *desktop*
  turn is actively working. After the last turn stops it is held for a 120
  second grace period, then released; new work cancels the grace immediately.
* Automatic awake fails closed and releases at once on battery, an unknown or
  unavailable power source, a screen lock, or sleep.
* Manual awake ignores power and runs on battery too, but is suspended while the
  session is locked, asleep, inactive, or unknown, and resumes only when it is
  active and unlocked again. Suspension keeps the original absolute deadline;
  resuming uses only the time still remaining and never extends the timer. A timer that reaches
  its deadline while paused is released rather than revived.
* Sleep, inactive, and lock are separate latches, so waking while the screen is
  still locked cannot resume an assertion.
* Every `caffeinate` request is idle-sleep prevention only (`-i`). The display is
  never held on, and a dark screen is not treated as a screen lock.
* Legacy `-d -i` helper records are still recognized and can still be stopped.

### Build and test from source

Build the staged app bundle:

```sh
./build.sh
```

Run the focused test suite (Swift parser suites, receiver tests, hooks-renderer
tests, helper lifecycle tests, source-contract checks, and the read-only session
observer):

```sh
./tests/validate.sh
```

The build stages output in `dist/` and `build/` without installing the app or
changing hook trust. Tests run isolated helper processes and temporary awake
assertions, then clean up the processes they own. They do not launch or replace
the installed app. The source archive passed the build and full test suite on
2026-09-30. The subsequent presentation-only update reuses that evidence because
the code, build scripts, and tests are unchanged.

### Hook setup

The receiver is installed as one step of the manual install guide. Follow
[README.md](README.md) — "Install (manual)", step 5, and the
[Build and install](README.md#build-and-install) navigation — for rendering a
hooks template, merging the seven Coffee matcher entries, and enabling and
trusting them through your supported Codex hooks interface.

### Verification status

Verified on the current development Mac (2026-09-30): actual **lock, sleep,
wake-while-locked, and unlock** transitions passed, so pause and resume across
those transitions is confirmed.

Still unverified and not claimed:

* physical unplug / replug power transitions;
* a power transition while the menu is open;
* lid-close behavior;
* fast user switch.

Automated isolated tests cover the awake-eligibility gate, the automatic awake
state machine, the activity snapshot parser, the receiver's owner filter and
privacy behavior, and the helper lifecycle. They do not replace the physical
checks listed above.

### Signing

The build signs the app **ad-hoc only**. That is a local integrity signature for
development; it is **not** Developer ID signing and **not** notarization.
macOS Gatekeeper will treat the app as unsigned by an identified developer, and
no quarantine or security-bypass command is recommended or required.

### Power settings are read-only

Battery/AC energy modes (High Power, Low Power, Automatic) are external system
preferences. The app reads the current source and mode to display them and never
configures, changes, or overrides them. Every power-related input is read-only:
IOKit power-source change events, the `IOPSCopyPowerSourcesInfo` sample, one
read-only `system_profiler SPPowerDataType -json` run, and one read-only
`pmset -g custom` run at launch and whenever the menu opens.

### License

Licensed under the [MIT License](LICENSE).

Copyright (c) 2026 myconstance1999-pixel.
