# Changelog

All notable changes to Coffee Work (the Codex Work Mode menu-bar utility) are
recorded here. Version `1.4.1` introduced the compact menu presentation.

## 1.8

This public source release rolls up the locally accepted updates since public
`1.5`. There are no separate public `1.6`/`1.7` releases; those local versions
introduced the explicit display timer and locked trusted-AC background support,
and this release includes independent controls and bounded diagnostics.

* The manual background timer, the explicit display hold, and automatic
  background awake are now independent sources that can run at the same time.
  Starting or stopping one never changes another source's deadline or process,
  and the compact menu carries one truthful status and one stop action per
  source.
* An explicit display hold (`-d -i`) offers 30 minutes, 1/4/8 hours, a custom
  whole-hour count from 1 through 24, and an until-stopped request. It is offered
  on battery and in Low Power Mode because eligibility is the current unlocked
  active session alone, never the power source or energy mode, and no OS energy
  setting is written.
* A finite display request keeps one absolute deadline that survives pauses
  unchanged and never revives after expiry or cancellation. The until-stopped
  request is a distinct, memory-only state covered by bounded owner-tied
  `-d -i -t 300 -w <app pid>` leases renewed every 240 seconds. Every display
  child is `-d -i -t <= 86400 -w <app pid>`, never `-u` or `-s`, and an app
  restart never restores a display request.
* A user-invoked `立即启动屏保` row opens the installed system ScreenSaverEngine.
  It ends only the explicit display hold, leaves the background and automatic
  sources untouched, and writes no screen saver, timeout, password or energy
  setting.
* Automatic background awake stays idle-sleep-only and may now hold while the
  session is locked, but only on external power with a supported local hook
  reporting valid actively working Codex desktop work. A locked session with no
  valid work, a waiting/non-working task, or an invalid snapshot releases
  immediately with no grace; an unlocked completion uses the existing 120 second
  grace period.
* Work mode and composer-dot tasks that do not go through the supported local
  desktop hooks are not auto-detected; the manual background timer and the
  explicit display hold remain available.
* The app and the hook receiver keep bounded, privacy-minimized local diagnostic
  histories (four 256 KiB files per producer, owner-only, metadata whitelist),
  visible through `更多状态与日志` and `导出诊断日志…`.
* The isolated 1.8 menu acceptance passed independent concurrent timers, separate
  stop actions, the until-stopped request, and a custom 2-hour display timer.

## 1.5

* Includes the exact nested `CodexCLI.app` executable-path compatibility fix,
  retaining desktop ownership checks and standalone/headless CLI exclusions.

* Both awake sources are now session- and power-aware through one shared
  eligibility rule: the active, unlocked console session is required for any
  assertion, and automatic awake additionally requires external power.
* Automatic awake fails closed on an unknown or unavailable power source, and
  releases immediately on battery, lock, sleep, or session-inactive.
* Manual awake still ignores power, but is suspended while the session is
  locked, asleep, inactive, or unknown. Suspension keeps the original absolute
  deadline and remaining seconds, so resuming never extends the timer.
* Sleep, inactive, and lock are tracked as separate latches, so waking while
  still locked cannot resume an assertion.
* Every caffeinate request is now idle-sleep prevention only (`-i`); the display
  is never held on and a dark screen is not treated as a lock.
* Legacy `-d -i` helper records are still recognized and can still be stopped,
  and the legacy logical deadline is recovered from the supported `ps -o etime=`
  keyword.

## 1.4.1

* Presentation-only: the same status, toggle, timer, and read-only details are
  regrouped into a short top-level menu with `Keep awake for` and `Details`
  submenus. No timer, automatic-awake, helper, receiver, or hook behavior
  changed.

## 1.4

* Automatic awake for local Codex desktop work, driven by the `activity-hook.py`
  receiver and a 120 second grace period after the last turn stops.
* Read-only Codex activity, power source, and energy mode rows.
* The `Auto awake for Codex` toggle is the only persisted setting.
* The app owns a single bounded `caffeinate -d -i -t 300 -w <app pid>` process and
  releases it on quit.

## 1.3

* Read-only power source and energy mode rows, obtained from one
  `system_profiler SPPowerDataType -json` run and one `pmset -g custom` run.
