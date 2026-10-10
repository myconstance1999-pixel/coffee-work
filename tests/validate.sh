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
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -module-cache-path "$root/build/compile-cache" -framework AppKit "$prefix" \
    -o build/custom-hours-tests
./build/custom-hours-tests

print ''
print '== 2. PowerStatus parser fixtures (production source) =='
prefix=build/PowerStatusPrefix.swift
/usr/bin/sed '/^let app = NSApplication.shared$/,$d' MenuBar.swift > "$prefix"
/bin/cat tests/power-status-main.swift >> "$prefix"
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -module-cache-path "$root/build/compile-cache" -framework AppKit "$prefix" \
    -o build/power-status-tests
./build/power-status-tests

print ''
print '== 2b. Auto awake engine + power/session gate + activity snapshot parser (production source) =='
prefix=build/AutoAwakePrefix.swift
/usr/bin/sed '/^let app = NSApplication.shared$/,$d' MenuBar.swift > "$prefix"
/bin/cat tests/auto-awake-main.swift >> "$prefix"
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -module-cache-path "$root/build/compile-cache" -framework AppKit "$prefix" \
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
print '== 5. native menu behavior and offscreen presentation =='
/bin/zsh tests/validate-menu.sh
/bin/zsh tests/validate-availability.sh

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
print '== 7. automatic idle-only and finite GUI assertion contracts; no session writes =='
# Automatic/background assertions remain idle-only. The accepted v1.6 GUI
# timer is the sole finite display exception, with the same deadline/session
# and owning-process limits. A whole-app ban on -d incorrectly rejected it.
/usr/bin/python3 tests/assertion-contract-tests.py
# The scoped Python guard also rejects file mutations outside DiagnosticLog.
# Its accepted bounded log rotation/export writes are unrelated to the helper
# session; matching any write(to:) anywhere produced a false failure here.
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
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -module-cache-path "$root/build/compile-cache" -framework AppKit -framework CoreGraphics \
    -framework IOKit "$prefix" -o build/session-observer
./build/session-observer --seconds 2
print 'PASS: observer compiled and sampled the real session read-only'

print ''
print 'PASS: focused validation complete'
