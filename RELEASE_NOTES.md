# Release Notes

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
