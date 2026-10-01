#!/bin/zsh
# Real isolated helper lifecycle tests for toggle.zsh (v1.5).
#
# The helper under test is the production toggle.zsh with exactly one
# substitution: its `state_dir=` line points at a private directory under
# build/. Every process probe is the real /bin/ps and every awake assertion is
# the real /usr/bin/caffeinate. There is no process-table shim: if /bin/ps
# cannot be executed (for example inside a restricted sandbox), the script
# reports the blocker and exits non-zero rather than substituting a fixture.
#
# Nothing here touches the live ~/Library/Application Support/Codex Work Mode
# state, the installed helper, or the running production app.
#
# Every process started here is test-owned. Cleanup never uses a global command
# or duration pattern: helper-owned timers are released through the helper's own
# exact-signature path, stand-in processes are tracked and signalled only while
# their recorded /bin/ps signature is still present, and section H confines its
# faulted helper and child to a dedicated session/process group so its leftover
# check can only ever look at that group. An EXIT/INT/TERM trap releases all of
# them even when a check fails or the run is interrupted.
#
# Output is PASS/FAIL per check; any failure exits non-zero.
set -u

cd "$(dirname "$0")/.."
root=$PWD

# --- preflight: the real system probes only ---------------------------------
if ! /bin/ps -p $$ -o lstart= -o command= >/dev/null 2>&1; then
    print -u2 -- 'BLOCKED: /bin/ps cannot be executed in this environment.'
    print -u2 -- 'These lifecycle tests exercise the real system ps and never shim it.'
    print -u2 -- 'Run this script from an unconfined shell, for example:'
    print -u2 -- '  cd coffee-work && /bin/zsh tests/helper-lifecycle-tests.sh'
    exit 1
fi
# Section H proves exactly which processes its faulted helper left behind by
# reading process-group membership. If that full-table probe is unavailable the
# release check could silently pass on an empty read, so it fails closed here.
if ! /bin/ps -axo pid=,pgid= >/dev/null 2>&1; then
    print -u2 -- 'BLOCKED: /bin/ps -axo pid=,pgid= is unavailable in this environment.'
    print -u2 -- 'Section H needs the real process-group table to verify release.'
    print -u2 -- 'Run this script from an unconfined shell, for example:'
    print -u2 -- '  cd coffee-work && /bin/zsh tests/helper-lifecycle-tests.sh'
    exit 1
fi

work="$root/build/helper-lifecycle"
/bin/rm -rf "$work"
/bin/mkdir -p "$work/state"
/bin/chmod 700 "$work" "$work/state"

# The isolated helper is the production helper with only the state root moved.
helper="$work/state/toggle.zsh"
/usr/bin/awk -v dir="$work/state" '
    /^state_dir=/ { print "state_dir=\"" dir "\""; next }
    { print }
' toggle.zsh > "$helper"
/bin/chmod 700 "$helper"

# Gate: the isolated helper differs from production only at the state root.
if ! diff \
    <(/usr/bin/sed -e 's|^state_dir=.*|state_dir=ROOT|' toggle.zsh) \
    <(/usr/bin/sed -e 's|^state_dir=.*|state_dir=ROOT|' "$helper"); then
    print 'FAIL isolated helper differs from production outside the state seam'
    exit 1
fi
/usr/bin/grep -q "$work/state" "$helper" || { print 'FAIL state root not isolated'; exit 1; }
print 'PASS isolated helper is production toggle.zsh with only the state root moved'

failures=0

# --- process probes (real /bin/ps) -----------------------------------------
ps_signature() {
    [[ -n "$1" ]] || return 1
    /bin/ps -p "$1" -o lstart= -o command= 2>/dev/null
}
ps_command() {
    [[ -n "$1" ]] || return 1
    /bin/ps -p "$1" -o command= 2>/dev/null
}
session_pid() {
    [[ -f "$work/state/session" ]] || return 0
    /usr/bin/sed -n '1p' "$work/state/session" 2>/dev/null || true
}
check_eq() {
    if [[ "$2" == "$3" ]]; then
        print "PASS $1"
    else
        print "FAIL $1 :: got [$2] want [$3]"
        failures=$(( failures + 1 ))
    fi
}
check_sub() {
    if [[ "$2" == *"$3"* ]]; then
        print "PASS $1"
    else
        print "FAIL $1 :: got [$2] want substring [$3]"
        failures=$(( failures + 1 ))
    fi
}
check_not_sub() {
    if [[ "$2" == *"$3"* ]]; then
        print "FAIL $1 :: got [$2] must not contain [$3]"
        failures=$(( failures + 1 ))
    else
        print "PASS $1"
    fi
}
check_empty() {
    if [[ -z "$2" ]]; then
        print "PASS $1"
    else
        print "FAIL $1 :: got [$2] want empty"
        failures=$(( failures + 1 ))
    fi
}
# Liveness check that does not rely on a single kill -0 probe: a process can be
# reparented, so fall back to pgrep. The pgrep pattern includes the exact bound
# so it can never match the long-lived production automatic assertion. This is a
# read-only probe: it never signals anything, and it reports success only for the
# exact pid it was given.
process_alive() {
    local pid=$1 pattern=$2
    [[ -n "$pid" ]] || return 1
    if /bin/kill -0 "$pid" 2>/dev/null; then return 0; fi
    /usr/bin/pgrep -f "$pattern" 2>/dev/null | /usr/bin/grep -qx "$pid" && return 0
    return 1
}
reset_session() {
    /bin/rm -f "$work/state/session"
}
# Release one known test-owned process by its exact pid. Only ever called with a
# pid this script started or read back from its own published record.
reap_caffeinate() {
    local pid=$1
    [[ -n "$pid" ]] || return 0
    /bin/kill -TERM "$pid" 2>/dev/null || true
}

# --- test-owned process bookkeeping -----------------------------------------
# Every process this script starts is recorded together with the exact /bin/ps
# signature it had at start. Release signals a recorded pid only while that same
# signature is still present, so a recycled pid, an unrelated user timer, or any
# other process this script does not own can never be signalled.
typeset -a tracked_pids tracked_sigs
track_pid() {
    local pid=$1
    [[ -n "$pid" ]] || return 0
    tracked_pids+=("$pid")
    tracked_sigs+=("$(ps_signature "$pid" || true)")
}
release_tracked() {
    local i pid sig current
    for (( i = 1; i <= ${#tracked_pids}; i++ )); do
        pid=${tracked_pids[i]}
        sig=${tracked_sigs[i]}
        [[ -n "$pid" && -n "$sig" ]] || continue
        current=$(ps_signature "$pid" || true)
        [[ -n "$current" && "$current" == "$sig" ]] || continue
        /bin/kill -TERM "$pid" 2>/dev/null || true
    done
}

# Section H runs its faulted helper and its child in a dedicated session and
# process group. These helpers are the only place group membership is used, and
# the target is always that one exact pgid, never a command or duration pattern.
h_pgid=''
group_pids() {
    [[ -n "$1" ]] || return 0
    /bin/ps -axo pid=,pgid= 2>/dev/null | /usr/bin/awk -v g="$1" '$2 == g { print $1 }'
}
release_group() {
    local pid
    for pid in ${(f)$(group_pids "$h_pgid")}; do
        [[ -n "$pid" ]] || continue
        /bin/kill -TERM "$pid" 2>/dev/null || true
    done
}

# Any failure or interrupt must still release every test-owned process: the
# helper's own exact-signature stop path, tracked stand-ins, and the dedicated
# section H process group.
cleanup() {
    local test_exit_code=$?
    trap - EXIT INT TERM
    # Restore the section H publication fault before touching the helper, so an
    # interrupt in the middle of H can still publish its stop and is not left
    # with an unwritable state root.
    /bin/chmod 700 "$work/state" 2>/dev/null || true
    release_tracked
    release_group
    /bin/zsh "$helper" off >/dev/null 2>&1 || true
    /bin/rm -f "$work/state/session" 2>/dev/null || true
    exit $test_exit_code
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

print ''
print '== A. active timer uses -i only and expires on the deadline =='
reset_session
# The bound is deliberately longer than the check sequence so a slow probe does
# not outlive the timer mid-check.
out=$(/bin/zsh "$helper" on 5 2>&1); rc=$?
check_eq 'A1 on exit 0' "$rc" '0'
check_sub 'A2 on reports active' "$out" 'Codex Work Mode: ON'
pid=$(session_pid)
sig=$(/usr/bin/sed -n '2p' "$work/state/session" 2>/dev/null || true)
track_pid "$pid"
args=$(ps_command "$pid" || true)
check_sub 'A3 stored signature is idle-only' "$sig" '/usr/bin/caffeinate -i -t '
check_not_sub 'A4 stored signature has no display flag' "$sig" ' -d '
check_sub 'A5 real argv has -i' "$args" '-i'
check_not_sub 'A6 real argv has no -d' "$args" '-d'
check_not_sub 'A7 real argv has no -u' "$args" '-u'
check_not_sub 'A8 real argv has no -s' "$args" '-s'
check_sub 'A9 real argv bounded to the requested duration' "$args" '-t 5'
if process_alive "$pid" 'caffeinate -i -t 5'; then
    print 'PASS A10 owned process is alive while active'
else
    print "FAIL A10 owned process missing while active (pid=$pid)"
    failures=$(( failures + 1 ))
fi
out=$(/bin/zsh "$helper" status 2>&1)
check_sub 'A11 status is ON with the deadline' "$out" 'Automatic stop:'
/bin/sleep 5.4
out=$(/bin/zsh "$helper" status 2>&1)
check_sub 'A12 expired active timer reports OFF' "$out" 'OFF'
if process_alive "$pid" 'caffeinate -i -t 5'; then
    print 'FAIL A13 owned process outlived its bound'
    reap_caffeinate "$pid"
    failures=$(( failures + 1 ))
else
    print 'PASS A13 owned process exited at its bound'
fi

print ''
print '== B. suspend releases the process; resume keeps the original deadline =='
reset_session
/bin/zsh "$helper" on 30 >/dev/null 2>&1
pid1=$(session_pid)
track_pid "$pid1"
exp1=$(/usr/bin/sed -n 's/^Expires: //p' "$work/state/session")
out=$(/bin/zsh "$helper" suspend 2>&1); rc=$?
check_eq 'B1 suspend exit 0' "$rc" '0'
check_sub 'B2 suspend reports paused' "$out" 'ON (paused)'
check_eq 'B3 record state paused' "$(/usr/bin/sed -n 's/^State: //p' "$work/state/session")" 'paused'
check_eq 'B4 pause keeps the original deadline' "$(/usr/bin/sed -n 's/^Expires: //p' "$work/state/session")" "$exp1"
remaining=$(/usr/bin/sed -n 's/^Remaining: //p' "$work/state/session")
if [[ "$remaining" == <1-30> ]]; then
    print "PASS B5 pause stores remaining whole seconds ($remaining)"
else
    print "FAIL B5 remaining [$remaining] outside 1..30"
    failures=$(( failures + 1 ))
fi
if process_alive "$pid1" 'caffeinate -i -t 30'; then
    print 'FAIL B6 caffeinate still running while paused'
    reap_caffeinate "$pid1"
    failures=$(( failures + 1 ))
else
    print 'PASS B6 pause released the exact owned process'
fi
out=$(/bin/zsh "$helper" status 2>&1)
check_sub 'B7 status is PAUSED' "$out" 'PAUSED'
/bin/sleep 1.2
out=$(/bin/zsh "$helper" resume 2>&1); rc=$?
check_eq 'B8 resume exit 0' "$rc" '0'
check_sub 'B9 resume reports active' "$out" 'Codex Work Mode: ON'
check_eq 'B10 resume keeps the original deadline' "$(/usr/bin/sed -n 's/^Expires: //p' "$work/state/session")" "$exp1"
pid2=$(session_pid)
track_pid "$pid2"
args=$(ps_command "$pid2" || true)
check_sub 'B11 resumed process uses -i' "$args" '-i'
check_not_sub 'B12 resumed process has no -d' "$args" '-d'
seconds=${args##*-t }
seconds=${seconds%% *}
if [[ "$seconds" == <1-29> ]]; then
    print "PASS B13 resume used only the remaining seconds ($seconds)"
else
    print "FAIL B13 resumed bound [$seconds] outside 1..29"
    failures=$(( failures + 1 ))
fi
before=$(session_pid)
out=$(/bin/zsh "$helper" resume 2>&1); rc=$?
check_eq 'B14 resume while active exits 0' "$rc" '0'
check_sub 'B15 resume while active is a no-op' "$out" 'already active'
check_eq 'B16 resume while active starts no new process' "$(session_pid)" "$before"
/bin/zsh "$helper" off >/dev/null 2>&1

print ''
print '== C. a paused timer stays cancelable =='
reset_session
/bin/zsh "$helper" on 30 paused >/dev/null 2>&1
check_empty 'C0 a paused start records no process' "$(session_pid)"
out=$(/bin/zsh "$helper" off 2>&1)
check_sub 'C1 off cancels a paused timer' "$out" 'OFF'
if [[ -f "$work/state/session" ]]; then
    print 'FAIL C2 paused record survived off'
    failures=$(( failures + 1 ))
else
    print 'PASS C2 paused record removed by off'
fi
/bin/zsh "$helper" on 30 paused >/dev/null 2>&1
out=$(/bin/zsh "$helper" toggle 2>&1)
check_sub 'C3 toggle cancels a paused timer' "$out" 'OFF'
if /bin/zsh "$helper" status 2>&1 | /usr/bin/grep -q 'ON'; then
    print 'FAIL C4 cancelled paused timer still ON'
    failures=$(( failures + 1 ))
else
    print 'PASS C4 cancelled paused timer is off'
fi
/bin/zsh "$helper" on 30 paused >/dev/null 2>&1
before=$(/usr/bin/shasum -a 256 "$work/state/session" | /usr/bin/awk '{print $1}')
/bin/zsh "$helper" status >/dev/null 2>&1
/bin/zsh "$helper" status >/dev/null 2>&1
after=$(/usr/bin/shasum -a 256 "$work/state/session" | /usr/bin/awk '{print $1}')
check_eq 'C5 repeated status never rewrites the paused record' "$after" "$before"
out=$(/bin/zsh "$helper" suspend 2>&1); rc=$?
check_eq 'C6 suspend while paused exits 0' "$rc" '0'
check_sub 'C7 suspend while paused is a no-op' "$out" 'already paused'
/bin/zsh "$helper" off >/dev/null 2>&1

print ''
print '== D. legacy three-line -d -i record is recognized and released exactly =='
reset_session
# A real, test-owned STAND-IN whose ps command line carries the legacy
# signature. `exec -a` only changes argv[0]; the process is a bounded sleep, not
# a real caffeinate, that the helper may signal. It exists only so the helper's
# legacy-signature recognition can be exercised; no real display assertion is
# ever requested, and the stand-in is released by exact tracked identity.
/bin/bash -c 'exec -a "/usr/bin/caffeinate -d -i -t 60" /bin/sleep 60' &
legacy_pid=$!
/bin/sleep 0.2
track_pid "$legacy_pid"
legacy_sig=$(ps_signature "$legacy_pid" || true)
if [[ "$legacy_sig" != *'/usr/bin/caffeinate -d -i -t '* ]]; then
    print "FAIL D0 could not create a legacy-shaped process (sig=[$legacy_sig])"
    reap_caffeinate "$legacy_pid"
    failures=$(( failures + 1 ))
else
    {
        print -r -- "$legacy_pid"
        print -r -- "$legacy_sig"
        print -r -- 'Automatic stop: 2026-09-27 08:00 PDT'
    } > "$work/state/session"
    out=$(/bin/zsh "$helper" status 2>&1)
    check_sub 'D1 legacy record reports ON' "$out" 'ON'
    out=$(/bin/zsh "$helper" off 2>&1); rc=$?
    check_eq 'D2 legacy off exit 0' "$rc" '0'
    if /bin/kill -0 "$legacy_pid" 2>/dev/null; then
        print 'FAIL D3 legacy process survived off'
        reap_caffeinate "$legacy_pid"
        failures=$(( failures + 1 ))
    else
        print 'PASS D3 legacy process released by exact signature'
    fi
fi

print ''
print '== E. a mismatched pid is never signalled =='
reset_session
/bin/sleep 45 &
other_pid=$!
/bin/sleep 0.2
track_pid "$other_pid"
{
    print -r -- "$other_pid"
    print -r -- 'Some other start marker /usr/bin/caffeinate -i -t 60'
    print -r -- 'Automatic stop: 2026-09-27 08:00 PDT'
    print -r -- 'Boot: 1'
    print -r -- 'State: active'
    print -r -- 'Expires: 4102444800'
} > "$work/state/session"
/bin/zsh "$helper" off >/dev/null 2>&1
if /bin/kill -0 "$other_pid" 2>/dev/null; then
    print 'PASS E1 unrelated process was not signalled'
else
    print 'FAIL E1 unrelated process was killed'
    failures=$(( failures + 1 ))
fi
/bin/kill -TERM "$other_pid" 2>/dev/null || true

print ''
print '== F. a paused record from another boot is never revived =='
reset_session
/bin/zsh "$helper" on 30 paused >/dev/null 2>&1
/usr/bin/sed -i '' 's|^Boot: .*$|Boot: 1|' "$work/state/session"
out=$(/bin/zsh "$helper" resume 2>&1); rc=$?
check_eq 'F1 resume after boot change exits 0' "$rc" '0'
check_empty 'F2 no process is started for a stale-boot record' "$(session_pid)"
check_sub 'F3 stale-boot record resolves OFF' "$(/bin/zsh "$helper" status 2>&1)" 'OFF'

print ''
print '== G. a paused timer expires on its original deadline =='
reset_session
/bin/zsh "$helper" on 2 paused >/dev/null 2>&1
/bin/sleep 2.6
out=$(/bin/zsh "$helper" status 2>&1)
check_sub 'G1 paused deadline reached reports OFF' "$out" 'OFF'
if [[ -f "$work/state/session" ]]; then
    print 'FAIL G2 expired paused record remains'
    failures=$(( failures + 1 ))
else
    print 'PASS G2 expired paused record removed'
fi
/bin/zsh "$helper" resume >/dev/null 2>&1
check_empty 'G3 expired paused timer was not revived' "$(session_pid)"

print ''
print '== H. a spawn that cannot be published is released, not left running =='
reset_session
# The state root is made unwritable for this one check. The helper must still
# verify its real caffeinate spawn, fail to publish the record, release the
# process it started, and report failure instead of leaving an assertion behind.
# No process-table shim is involved: only the publication target is faulted.
#
# The faulted helper and its caffeinate child run in a brand-new session and
# process group: the launcher calls setsid() before exec, so the helper becomes
# the session/process-group leader and its child inherits that exact pgid. The
# leftover check below reads only processes whose pgid is this dedicated group.
# It never searches by command text or duration, so an unrelated user timer can
# never be listed or signalled. The group is also released by the EXIT trap.
h_pgid=''
h_pgid_file="$work/h-pgid"
/bin/rm -f "$h_pgid_file"
launcher="$work/session-launcher.py"
/bin/cat > "$launcher" <<'PY'
import os
import sys

# argv: <pgid-file> <program> [args...]
pgid_file = sys.argv[1]
program = sys.argv[2:]
try:
    os.setsid()
except OSError as error:
    sys.stderr.write("session launcher: setsid failed: %s\n" % error)
    sys.exit(1)
with open(pgid_file, "w") as handle:
    handle.write(str(os.getpgrp()))
os.execv(program[0], program)
PY
/bin/chmod 500 "$work/state"
/usr/bin/python3 "$launcher" "$h_pgid_file" /bin/zsh "$helper" on 5 >/dev/null 2>&1 &
h_launch=$!
# Read the dedicated pgid as soon as the launcher publishes it, before waiting,
# so an interrupt during the helper run can still release only this group.
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "$h_pgid_file" ]] && break
    /bin/sleep 0.05
done
[[ -s "$h_pgid_file" ]] && h_pgid=$(/bin/cat "$h_pgid_file")
wait "$h_launch"; rc=$?
/bin/chmod 700 "$work/state"
own_pgid=$(/bin/ps -o pgid= -p $$ 2>/dev/null | /usr/bin/tr -d ' ')
if [[ -z "$h_pgid" || "$h_pgid" == "$own_pgid" ]]; then
    print "FAIL H0 could not isolate the faulted helper in its own process group (pgid=[$h_pgid])"
    failures=$(( failures + 1 ))
    h_pgid=''
else
    if (( rc != 0 )); then
        print 'PASS H1 unpublishable start exits non-zero'
    else
        print 'FAIL H1 unpublishable start exited 0'
        failures=$(( failures + 1 ))
    fi
    if [[ -f "$work/state/session" ]]; then
        print 'FAIL H2 session published despite the publication failure'
        failures=$(( failures + 1 ))
    else
        print 'PASS H2 no session published when the record cannot be written'
    fi
    leftover=''
    for i in 1 2 3 4 5 6 7 8 9 10; do
        leftover=$(group_pids "$h_pgid")
        [[ -z "$leftover" ]] && break
        /bin/sleep 0.1
    done
    if [[ -z "$leftover" ]]; then
        print 'PASS H3 unpublishable spawn was released'
    else
        print "FAIL H3 unpublishable spawn still running in test group $h_pgid: $leftover"
        for pid in ${(f)leftover}; do /bin/kill -TERM "$pid" 2>/dev/null || true; done
        failures=$(( failures + 1 ))
        for i in 1 2 3 4 5 6 7 8 9 10; do
            leftover=$(group_pids "$h_pgid")
            [[ -z "$leftover" ]] && break
            /bin/sleep 0.1
        done
    fi
    # Stop tracking only once the dedicated group is actually empty; if anything
    # survived, the EXIT trap retries the same exact group.
    [[ -z "$leftover" ]] && h_pgid=''
fi

print ''
print '== I. a malformed or unreadable record fails safe =='
reset_session
print -r -- 'this is not a record' > "$work/state/session"
out=$(/bin/zsh "$helper" status 2>&1); rc=$?
check_eq 'I1 malformed record status exit 0' "$rc" '0'
check_sub 'I2 malformed record reports OFF' "$out" 'OFF'
check_sub 'I3 off clears a malformed record' "$(/bin/zsh "$helper" off 2>&1)" 'OFF'

print ''
print '== J. the helper has no power or session input of its own =='
if /usr/bin/grep -qE 'pmset|IOPS|system_profiler|CGSession' toggle.zsh; then
    print 'FAIL J1 helper reads system power/session state'
    failures=$(( failures + 1 ))
else
    print 'PASS J1 helper is power/session independent (manual ignores power)'
fi

print ''
print '== K. legacy -d -i timer is preserved across suspend (supported etime=) =='
reset_session
/bin/zsh "$helper" off >/dev/null 2>&1 || true
# Test-owned STAND-IN with a legacy-shaped argv0; it is a bounded sleep, not a
# real caffeinate, and it never requests a display or system assertion. The
# helper's real etime= probe reads its real elapsed time while the record is
# suspended, then the stand-in is released by exact tracked identity.
/bin/bash -c 'exec -a "/usr/bin/caffeinate -d -i -t 30" /bin/sleep 30' &
legacy_pid=$!
/bin/sleep 0.2
track_pid "$legacy_pid"
legacy_sig=$(ps_signature "$legacy_pid" || true)
if [[ "$legacy_sig" != *'/usr/bin/caffeinate -d -i -t '* ]]; then
    print "FAIL K0 could not create a legacy-shaped process (sig=[$legacy_sig])"
    reap_caffeinate "$legacy_pid"
    failures=$(( failures + 1 ))
else
    {
        print -r -- "$legacy_pid"
        print -r -- "$legacy_sig"
        print -r -- 'Automatic stop: 2026-09-27 08:00 PDT'
    } > "$work/state/session"
    /bin/sleep 1
    before=$(/bin/date +%s)
    out=$(/bin/zsh "$helper" suspend 2>&1); rc=$?
    after=$(/bin/date +%s)
    check_eq 'K1 legacy suspend exit 0' "$rc" '0'
    check_sub 'K2 legacy suspend reports paused' "$out" 'ON (paused)'
    check_eq 'K3 legacy record becomes paused' \
        "$(/usr/bin/sed -n 's/^State: //p' "$work/state/session")" 'paused'
    remaining=$(/usr/bin/sed -n 's/^Remaining: //p' "$work/state/session")
    if [[ "$remaining" == <1-30> ]]; then
        print "PASS K4 legacy remaining recovered from the real etime= ($remaining)"
    else
        print "FAIL K4 legacy remaining [$remaining] outside 1..30"
        failures=$(( failures + 1 ))
    fi
    expires=$(/usr/bin/sed -n 's/^Expires: //p' "$work/state/session")
    if [[ "$expires" == <1-> ]] && (( expires >= before && expires <= after + 30 )); then
        print 'PASS K5 legacy pause keeps an absolute deadline near now + remaining'
    else
        print "FAIL K5 legacy deadline [$expires] outside the recovered window"
        failures=$(( failures + 1 ))
    fi
    if /bin/kill -0 "$legacy_pid" 2>/dev/null; then
        print 'FAIL K6 legacy process was not released while pausing'
        reap_caffeinate "$legacy_pid"
        failures=$(( failures + 1 ))
    else
        print 'PASS K6 legacy process released while pausing'
    fi
    record_before=$(/usr/bin/shasum -a 256 "$work/state/session" | /usr/bin/awk '{print $1}')
    /bin/sleep 1.3
    out=$(/bin/zsh "$helper" status 2>&1)
    check_sub 'K7 paused legacy status still reports PAUSED' "$out" 'PAUSED'
    now_remaining=$(print -r -- "$out" | /usr/bin/sed -n 's/^Remaining: //p')
    if [[ "$now_remaining" == <0-29> ]]; then
        print "PASS K8 status counts down against the absolute deadline ($now_remaining)"
    else
        print "FAIL K8 status remaining [$now_remaining] did not count down"
        failures=$(( failures + 1 ))
    fi
    record_after=$(/usr/bin/shasum -a 256 "$work/state/session" | /usr/bin/awk '{print $1}')
    check_eq 'K9 status never rewrote the paused legacy record' "$record_after" "$record_before"
    out=$(/bin/zsh "$helper" resume 2>&1); rc=$?
    check_eq 'K10 resume legacy-paused exit 0' "$rc" '0'
    check_sub 'K11 resume legacy-paused reports active' "$out" 'Codex Work Mode: ON'
    args=$(ps_command "$(session_pid)" || true)
    seconds=${args##*-t }
    seconds=${seconds%% *}
    if [[ "$seconds" == <1-30> ]]; then
        print "PASS K12 resumed legacy timer used only the recovered remaining ($seconds)"
    else
        print "FAIL K12 resumed legacy bound [$seconds] outside 1..30"
        failures=$(( failures + 1 ))
    fi
    /bin/zsh "$helper" off >/dev/null 2>&1
fi

print ''
print '== L. paused status counts down and never extends the absolute deadline =='
reset_session
/bin/zsh "$helper" on 4 paused >/dev/null 2>&1
exp0=$(/usr/bin/sed -n 's/^Expires: //p' "$work/state/session")
out1=$(/bin/zsh "$helper" status 2>&1)
rem1=$(print -r -- "$out1" | /usr/bin/sed -n 's/^Remaining: //p')
/bin/sleep 1.3
out2=$(/bin/zsh "$helper" status 2>&1)
rem2=$(print -r -- "$out2" | /usr/bin/sed -n 's/^Remaining: //p')
check_eq 'L1 status never moves the absolute deadline' \
    "$(/usr/bin/sed -n 's/^Expires: //p' "$work/state/session")" "$exp0"
if [[ "$rem1" == <1-4> && "$rem2" == <0-3> ]] && (( rem2 < rem1 )); then
    print "PASS L2 repeated status counts down against the deadline ($rem1 -> $rem2)"
else
    print "FAIL L2 repeated status did not count down ($rem1 -> $rem2)"
    failures=$(( failures + 1 ))
fi
/bin/sleep 2.8
out3=$(/bin/zsh "$helper" status 2>&1)
check_sub 'L3 paused timer expires on its original deadline' "$out3" 'OFF'
if [[ -f "$work/state/session" ]]; then
    print 'FAIL L4 expired paused record remains published'
    failures=$(( failures + 1 ))
else
    print 'PASS L4 expired paused record removed'
fi

print ''
print '== M. out-of-contract state numbers fail closed, never a long awake request =='
reset_session
/bin/zsh "$helper" on 30 paused >/dev/null 2>&1

/usr/bin/sed -i '' 's|^Remaining: .*$|Remaining: 999999999|' "$work/state/session"
out=$(/bin/zsh "$helper" status 2>&1); rc=$?
check_eq 'M1 huge Remaining status exit 0' "$rc" '0'
check_sub 'M2 huge Remaining resolves OFF' "$out" 'OFF'
if [[ -f "$work/state/session" ]]; then
    print 'FAIL M3 out-of-contract record remains published'
    failures=$(( failures + 1 ))
else
    print 'PASS M3 out-of-contract record removed'
fi
out=$(/bin/zsh "$helper" resume 2>&1); rc=$?
check_eq 'M4 resume after huge Remaining exits 0' "$rc" '0'
check_empty 'M5 resume after huge Remaining starts no process' "$(session_pid)"

/bin/zsh "$helper" on 30 paused >/dev/null 2>&1
/usr/bin/sed -i '' 's|^Expires: .*$|Expires: notanumber|' "$work/state/session"
out=$(/bin/zsh "$helper" status 2>&1); rc=$?
check_eq 'M6 non-numeric Expires status exit 0' "$rc" '0'
check_sub 'M7 non-numeric Expires resolves OFF' "$out" 'OFF'
check_empty 'M8 non-numeric Expires starts no process' "$(session_pid)"

/bin/zsh "$helper" on 30 paused >/dev/null 2>&1
/usr/bin/sed -i '' 's|^Expires: .*$|Expires: 99999999999999|' "$work/state/session"
check_sub 'M9 far-future Expires resolves OFF' "$(/bin/zsh "$helper" status 2>&1)" 'OFF'
/bin/zsh "$helper" resume >/dev/null 2>&1
check_empty 'M10 far-future Expires starts no process' "$(session_pid)"
/bin/zsh "$helper" off >/dev/null 2>&1

print ''
print '== N. only the supported etime= keyword is used =='
if /usr/bin/grep -q -- '-o etimes=' toggle.zsh; then
    print 'FAIL N1 production helper invokes the nonexistent etimes= field'
    failures=$(( failures + 1 ))
elif /usr/bin/grep -q -- '-o etime=' toggle.zsh; then
    print 'PASS N1 production helper uses only the supported etime= elapsed keyword'
else
    print 'FAIL N1 production helper lost its elapsed-time probe'
    failures=$(( failures + 1 ))
fi

# Never leave a test-owned session or process behind.
/bin/zsh "$helper" off >/dev/null 2>&1 || true
/bin/rm -f "$work/state/session"

print ''
if (( failures > 0 )); then
    print "FAILED: $failures isolated helper lifecycle check(s)"
    exit 1
fi
print 'PASS: all isolated helper lifecycle checks'
exit 0
