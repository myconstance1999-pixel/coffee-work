# Changelog

All notable changes to Coffee Work (the Codex Work Mode menu-bar utility) are
recorded here. Version `1.4.1` introduced the compact menu presentation.

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
