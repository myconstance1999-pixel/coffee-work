#!/bin/zsh
# Focused validation for the bounded contract.
#
# 1. Swift: compiles the production CustomHours parser and checks every boundary.
# 2. zsh: checks toggle.zsh syntax and its numeric duration pattern in isolation.
# Neither step runs the helper against the real session.
set -eu
cd "$(dirname "$0")/.."
root=$PWD

print '== 1. CustomHours parser boundaries (production source) =='
/bin/mkdir -p build
prefix=build/CustomHoursPrefix.swift
/usr/bin/sed '/^let app = NSApplication.shared$/,$d' MenuBar.swift > "$prefix"
/bin/cat tests/custom-hours-main.swift >> "$prefix"
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -framework AppKit "$prefix" \
    -o build/custom-hours-tests
./build/custom-hours-tests

print ''
print '== 2. PowerStatus parser fixtures (production source) =='
prefix=build/PowerStatusPrefix.swift
/usr/bin/sed '/^let app = NSApplication.shared$/,$d' MenuBar.swift > "$prefix"
/bin/cat tests/power-status-main.swift >> "$prefix"
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -framework AppKit "$prefix" \
    -o build/power-status-tests
./build/power-status-tests

print ''
print '== 2b. Auto awake engine + power/session gate + activity snapshot parser (production source) =='
prefix=build/AutoAwakePrefix.swift
/usr/bin/sed '/^let app = NSApplication.shared$/,$d' MenuBar.swift > "$prefix"
/bin/cat tests/auto-awake-main.swift >> "$prefix"
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -framework AppKit "$prefix" \
    -o build/auto-awake-tests
./build/auto-awake-tests

print ''
print '== 3. toggle.zsh syntax =='
/bin/zsh -n toggle.zsh
print 'PASS: zsh -n toggle.zsh'
print ''
print '== 4. toggle.zsh duration bound (pattern extracted from the source) =='
bound=$(/usr/bin/sed -n 's/.*\[\[ "\$duration" == \(<[0-9][0-9]*-[0-9][0-9]*>\) \]\].*/\1/p' toggle.zsh)
print "extracted pattern: $bound"
[[ "$bound" == '<1-86400>' ]] || { print "FAIL: unexpected duration bound"; exit 1 }

failures=0
accept() {
    if [[ "$1" == ${~bound} ]]; then
        print "PASS accept $1"
    else
        print "FAIL expected accept: $1"
        failures=$(( failures + 1 ))
    fi
}
reject() {
    if [[ "$1" == ${~bound} ]]; then
        print "FAIL expected reject: $1"
        failures=$(( failures + 1 ))
    else
        print "PASS reject $1"
    fi
}

accept 1
accept 8
accept 28800
accept 86399
accept 86400
reject 0
reject 86401
reject -1
reject abc
reject 1.5
reject ''

(( failures == 0 )) || { print "FAILED: $failures duration-bound check(s)"; exit 1 }
print 'PASS: all duration-bound checks'

print ''
print '== 4b. activity hook receiver, ancestry filter, privacy, locking =='
/usr/bin/python3 tests/activity-hook-tests.py

print ''
print '== 4b2. portable hooks renderer: quoting, refusal, exclusive creation =='
# Pure stdlib tests over private temporary directories: no real home, no
# ~/.codex config, no global filesystem scan.
/usr/bin/python3 tests/render-hooks-tests.py

print ''
print '== 4c. isolated real helper lifecycle (pause/resume/legacy/safety) =='
# Runs the production toggle.zsh against a private state root with only its
# `state_dir=` line moved. The real /bin/ps and the real /usr/bin/caffeinate are
# used; there is no process-table shim. If /bin/ps cannot be executed in the
# current environment the lifecycle script reports the blocker and exits
# non-zero, which fails this gate on purpose.
/bin/zsh tests/helper-lifecycle-tests.sh

print ''
print '== 5. menu contract in source (v1.4.1 hierarchy) =='
/usr/bin/grep -q 'Custom hours…' MenuBar.swift && print 'PASS: Custom hours… menu item present'
/usr/bin/grep -q 'for hours in \[1, 4, 8\]' MenuBar.swift && print 'PASS: 1/4/8 presets preserved'
/usr/bin/grep -q 'title: "Stop timer"' MenuBar.swift && print 'PASS: Stop timer action present'
/usr/bin/grep -q 'title: "Keep awake for"' MenuBar.swift && print 'PASS: Keep awake for submenu present'
/usr/bin/grep -q 'title: "Details"' MenuBar.swift && print 'PASS: Details submenu present'
/usr/bin/grep -q '#selector(stopMode)' MenuBar.swift && print 'PASS: Stop timer uses the existing stopMode action'
/usr/bin/grep -q '#selector(startFromMenu(_:))' MenuBar.swift && print 'PASS: preset rows use the existing startFromMenu action'
/usr/bin/grep -q '#selector(startCustomFromMenu(_:))' MenuBar.swift && print 'PASS: custom row uses the existing startCustomFromMenu action'
/usr/bin/grep -q '"Power source: ' MenuBar.swift && print 'PASS: power source row present'
/usr/bin/grep -q '"Energy mode: ' MenuBar.swift && print 'PASS: energy mode row present'
/usr/bin/grep -q 'Loading…' MenuBar.swift && print 'PASS: Loading… row state present'
/usr/bin/grep -q '"/usr/sbin/system_profiler"' MenuBar.swift && print 'PASS: read-only system_profiler probe present'
/usr/bin/grep -q 'SPPowerDataType' MenuBar.swift && print 'PASS: SPPowerDataType read present'
/usr/bin/grep -q '"/usr/bin/pmset"' MenuBar.swift && print 'PASS: read-only pmset probe present'
/usr/bin/grep -q '\["-g", "custom"\]' MenuBar.swift && print 'PASS: pmset limited to -g custom'
/usr/bin/grep -q 'Auto awake for Codex' MenuBar.swift && print 'PASS: Auto awake for Codex item present'
/usr/bin/grep -q 'cup.and.saucer.fill' MenuBar.swift && print 'PASS: filled cup symbol preserved'
/usr/bin/grep -q 'codex-activity' MenuBar.swift && print 'PASS: own activity snapshot folder bound'
/usr/bin/grep -q '"/usr/bin/caffeinate"' MenuBar.swift && print 'PASS: owned caffeinate present'
/usr/bin/grep -q '"-w", String(ProcessInfo.processInfo.processIdentifier)' MenuBar.swift && print 'PASS: caffeinate tied to the app pid for crash safety'
/usr/bin/grep -q 'graceSeconds: Double = 120' MenuBar.swift && print 'PASS: 120 second grace present'
/usr/bin/grep -q 'autoAwakeForCodex' MenuBar.swift && print 'PASS: only the auto toggle setting is persisted'
# v1.5 session/power-aware gate contract in source.
/usr/bin/grep -q 'IOPSNotificationCreateRunLoopSource' MenuBar.swift && print 'PASS: power changes use the IOKit run-loop source'
/usr/bin/grep -q 'IOPSCopyPowerSourcesInfo' MenuBar.swift && print 'PASS: read-only IOKit power-source sample present'
/usr/bin/grep -q 'CGSessionCopyCurrentDictionary' MenuBar.swift && print 'PASS: current session read through CGSessionCopyCurrentDictionary'
/usr/bin/grep -q 'CGSSessionScreenIsLocked' MenuBar.swift && print 'PASS: undocumented lock key handled explicitly'
/usr/bin/grep -q 'com.apple.screenIsLocked' MenuBar.swift && print 'PASS: distributed lock notification observed'
/usr/bin/grep -q 'com.apple.screenIsUnlocked' MenuBar.swift && print 'PASS: distributed unlock notification observed'
/usr/bin/grep -q 'willSleepNotification' MenuBar.swift && print 'PASS: willSleep observed'
/usr/bin/grep -q 'didWakeNotification' MenuBar.swift && print 'PASS: didWake observed'
/usr/bin/grep -q 'sessionDidResignActiveNotification' MenuBar.swift && print 'PASS: session resign-active observed'
/usr/bin/grep -q 'sessionDidBecomeActiveNotification' MenuBar.swift && print 'PASS: session become-active observed'
/usr/bin/grep -q 'struct SessionGate' MenuBar.swift && print 'PASS: separate sleep/inactive/lock latches present'
/usr/bin/grep -q 'sessionAllowsAssertion' MenuBar.swift && print 'PASS: one shared session gate for auto and manual'
/usr/bin/grep -q '"Timer paused' MenuBar.swift && print 'PASS: paused manual status preserved with its deadline'
/usr/bin/grep -q 'Auto: paused' MenuBar.swift && print 'PASS: automatic eligibility explained in Details'
/usr/bin/grep -q 'Auto: ready — no Codex work' MenuBar.swift && print 'PASS: no-work reason present'
/usr/bin/grep -q 'QAPowerSourceMonitor\|QASessionSampler' MenuBar.swift && print 'FAIL: QA test controls leaked into production' && exit 1
print 'PASS: no QA-only test controls in the production source'

print ''
print '== 5b. nested-menu integrity: no delegate on any submenu, rows keep item refs =='
# Only the top-level menu may have a delegate. A delegate on the Keep awake
# for / Details submenu would fire menuWillOpen on hover, refreshing state and
# rebuilding the parent menu (and firing another power probe) while a nested
# row is on screen.
delegates=$(/usr/bin/grep -c 'menu\.delegate = self' MenuBar.swift)
[ "$delegates" = 1 ] || {
    print "FAIL: expected exactly one menu delegate (top level), found $delegates"
    exit 1
}
print 'PASS: exactly one menu delegate (top-level menu only)'
# The read-only power rows must stay reachable through the stored item
# references so an asynchronous read retitles them in place.
/usr/bin/grep -q 'powerSourceItem = powerSource' MenuBar.swift || {
    print 'FAIL: power source row reference is not retained'
    exit 1
}
/usr/bin/grep -q 'energyModeItem = energyMode' MenuBar.swift || {
    print 'FAIL: energy mode row reference is not retained'
    exit 1
}
print 'PASS: power/energy row references retained for in-place async updates'

print ''
print '== 5c. v1.5 power-source, effective-assertion, and bounded-retry contract =='
# The IOKit notification source must be installed in the COMMON run-loop modes,
# so a power transition is handled while the menu is tracking as well as at
# idle, and the source must be registered before the first sample.
/usr/bin/grep -q 'CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)' MenuBar.swift || {
    print 'FAIL: power notification source is not installed in common run-loop modes'
    exit 1
}
if /usr/bin/grep -q 'CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)' MenuBar.swift; then
    print 'FAIL: power notification source is still installed in the default mode only'
    exit 1
fi
# A missing notification source must fail closed with an unknown availability,
# both at setup and in every later sample while no source is installed.
[ "$(/usr/bin/grep -c 'availability = .unknown' MenuBar.swift)" -ge 1 ] || {
    print 'FAIL: monitor setup failure does not force an unknown power availability'
    exit 1
}
/usr/bin/grep -q 'guard runLoopSource != nil else' MenuBar.swift || {
    print 'FAIL: sample() does not fail closed without an installed notification source'
    exit 1
}
# Effective process-held state is separate from the engine intent, is set on a
# real start, and is cleared on every failure/exit/release path.
/usr/bin/grep -q 'autoHeld = true' MenuBar.swift || {
    print 'FAIL: effective held state is never set by a running owned process'
    exit 1
}
[ "$(/usr/bin/grep -c 'autoHeld = false' MenuBar.swift)" -ge 2 ] || {
    print 'FAIL: effective held state is not cleared on failure and exit'
    exit 1
}
/usr/bin/grep -q 'handleAutoProcessExit' MenuBar.swift || {
    print 'FAIL: owned assertion early exit is not handled'
    exit 1
}
/usr/bin/grep -q 'AutoAwakeEngine.mayStart' MenuBar.swift || {
    print 'FAIL: assertion retries are not bounded by the renewal window'
    exit 1
}
print 'PASS: common-mode power source, fail-closed setup, effective held state, bounded retries'

print ''
print '== 6. read-only guard: only pmset -g custom, no power writes or privileged commands =='
# pmset is allowed for exactly one read: `-g custom`. The exact argument array
# is asserted, so no other pmset argument can be introduced; a settings write
# (`-a`, `-b`, `-c`, `-s`, or a bare `-g <setting>`) would fail this step.
/usr/bin/grep -q '\["-g", "custom"\]' MenuBar.swift || {
    print 'FAIL: pmset arguments are not exactly -g custom'
    exit 1
}
if [ "$(/usr/bin/grep -c '"/usr/bin/pmset"' MenuBar.swift)" != 1 ]; then
    print 'FAIL: pmset referenced outside the single read-only probe'
    exit 1
fi
if /usr/bin/grep -qE '\bsudo\b|/usr/bin/security|\bchmod\b|\bchown\b|\blaunchctl\b' MenuBar.swift; then
    print 'FAIL: privileged command present in MenuBar.swift'
    exit 1
fi
print 'PASS: pmset invoked only as -g custom; no power-setting/privileged command in MenuBar.swift'

print ''
print '== 7. automatic awake guard: one owned caffeinate, idle-only, no helper/session writes =='
# The app owns exactly one caffeinate invocation, its own; it never writes the
# manual helper session file or the activity snapshot. v1.5 requests idle sleep
# only: -i is present and -d/-u/-s never are.
if [ "$(/usr/bin/grep -c '"/usr/bin/caffeinate"' MenuBar.swift)" != 1 ]; then
    print 'FAIL: caffeinate referenced outside the single owned process'
    exit 1
fi
/usr/bin/grep -q '"\-i",' MenuBar.swift || {
    print 'FAIL: automatic assertion does not request idle sleep (-i)'
    exit 1
}
if /usr/bin/grep -nE '"-d"|"-u"|"-s"' MenuBar.swift; then
    print 'FAIL: automatic assertion still requests a display/user/system sleep flag'
    exit 1
fi
print 'PASS: automatic assertion is -i only'
if /usr/bin/grep -q 'appendingPathComponent("session")' MenuBar.swift; then
    # The app only reads the helper session for its process watch; it must never
    # write it. No write API may be reached with that path.
    if /usr/bin/grep -qE 'write\(to:|createFile\(atPath: session|removeItem\(at: session' MenuBar.swift; then
        print 'FAIL: app appears to write the manual helper session file'
        exit 1
    fi
fi
if /usr/bin/grep -q 'writeState\|state.json.tmp' MenuBar.swift; then
    print 'FAIL: app must not write the hook receiver activity state'
    exit 1
fi
print 'PASS: app owns only its caffeinate and only reads activity state'

print ''
print '== 8. toggle.zsh v1.5 helper contract (source) =='
/bin/zsh -n toggle.zsh
print 'PASS: zsh -n toggle.zsh'
/usr/bin/grep -q '(toggle|on|off|status|suspend|resume)' toggle.zsh || {
    print 'FAIL: toggle.zsh entry points changed'
    exit 1
}
print 'PASS: toggle | on | off | status | suspend | resume entry points present'
/usr/bin/grep -q '\[\[ "\$duration" == <1-86400> \]\]' toggle.zsh || {
    print 'FAIL: toggle.zsh duration bound changed'
    exit 1
}
print 'PASS: duration bound is 1..86400'
if [ "$(/usr/bin/grep -c 'nohup /usr/bin/caffeinate' toggle.zsh)" != 1 ]; then
    print 'FAIL: toggle.zsh must own exactly one caffeinate invocation'
    exit 1
fi
/usr/bin/grep -q 'nohup /usr/bin/caffeinate -i -t' toggle.zsh || {
    print 'FAIL: toggle.zsh does not request idle sleep only'
    exit 1
}
if /usr/bin/grep -E 'nohup /usr/bin/caffeinate' toggle.zsh | /usr/bin/grep -qE '(^| )-(d|u|s)( |$)'; then
    print 'FAIL: toggle.zsh still requests -d/-u/-s'
    exit 1
fi
print 'PASS: toggle.zsh caffeinate invocation is -i only'
/usr/bin/grep -q 'caffeinate -d -i -t' toggle.zsh || {
    print 'FAIL: toggle.zsh no longer recognizes legacy -d -i sessions'
    exit 1
}
print 'PASS: legacy -d -i session recognition present'
# The legacy remaining-time probe must use the supported BSD `etime=` keyword;
# `etimes=` does not exist on macOS and a regression to it would silently drop
# the legacy logical deadline.
/usr/bin/grep -q -- '-o etime=' toggle.zsh || {
    print 'FAIL: toggle.zsh lost the supported legacy etime= elapsed probe'
    exit 1
}
if /usr/bin/grep -q -- '-o etimes=' toggle.zsh; then
    print 'FAIL: toggle.zsh requests the nonexistent etimes= keyword'
    exit 1
fi
print 'PASS: legacy elapsed time uses only the supported etime= keyword'
# Published numbers are bounded before arithmetic so a corrupt state cannot
# become a long awake request.
/usr/bin/grep -q 'expires_epoch - current_epoch > 86400' toggle.zsh || {
    print 'FAIL: the absolute deadline is not bounded before arithmetic'
    exit 1
}
/usr/bin/grep -q 'stored_remaining" != <1-86400>' toggle.zsh || {
    print 'FAIL: the stored remaining seconds are not bounded before arithmetic'
    exit 1
}
print 'PASS: critical helper state numbers are bounded before arithmetic'
/usr/bin/grep -q 'State: $state' toggle.zsh || { print 'FAIL: pause state missing'; exit 1 }
/usr/bin/grep -q 'Remaining: \$remain' toggle.zsh || { print 'FAIL: pause remaining missing'; exit 1 }
/usr/bin/grep -q 'mv -f "\$tmp" "\$state_file"' toggle.zsh || {
    print 'FAIL: state publication is not atomic'
    exit 1
}
print 'PASS: suspend/resume state and atomic publication present'
if /usr/bin/grep -qE '(^|[^[:alnum:]_])(source|eval)([^[:alnum:]_]|$)' toggle.zsh; then
    print 'FAIL: toggle.zsh sources or evals its state'
    exit 1
fi
print 'PASS: helper state is read without source/eval'

print ''
print '== 9. isolated read-only session observer (same production adapter) =='
prefix=build/ObserverPrefix.swift
/usr/bin/sed '/^let app = NSApplication.shared$/,$d' MenuBar.swift > "$prefix"
/bin/cat qa/session-observer.swift >> "$prefix"
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -framework AppKit -framework CoreGraphics \
    -framework IOKit "$prefix" -o build/session-observer
./build/session-observer --seconds 2
print 'PASS: observer compiled and sampled the real session read-only'

print ''
print 'PASS: focused validation complete'
