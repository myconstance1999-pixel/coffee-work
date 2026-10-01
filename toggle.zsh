#!/bin/zsh
# Codex Work Mode manual timer helper (v1.5).
#
# Bounded, user-controlled prevention of *system idle sleep* only. The owned
# caffeinate process is started with `-i`; `-d` (display) is never requested, so
# the screen may turn off normally and a dark screen is never treated as a lock.
# No lock, power, or security setting is ever changed, and no login item,
# daemon, or privileged service is used.
#
# Entry points (unchanged): toggle | on | off | status, with a duration in
# seconds (1..86400, default 28800). Internal entry points used by the menu-bar
# app so it never writes this state file itself: suspend | resume. A third
# argument of `paused` makes `on` create the logical timer without starting any
# caffeinate process, so a request made while the Mac is not eligible to stay
# awake never even momentarily creates an awake assertion.
#
# State is a small plain-text record published atomically (write a temp file,
# then rename over `session`). It is read by fixed line number and literal
# prefix only: nothing is ever sourced or evaluated.
set -eu
umask 077

mode=${1:-toggle}
duration=${2:-28800}
paused_request=${3:-}
[[ "$mode" == (toggle|on|off|status|suspend|resume) ]] || exit 2
[[ "$duration" == <1-86400> ]] || exit 2

state_dir="$HOME/Library/Application Support/Codex Work Mode"
state_file="$state_dir/session"
/bin/mkdir -p "$state_dir"

now_epoch() { /bin/date +%s; }

# Boot identity: a paused record is only resumable on the same boot, so a reboot
# can never revive it. `kern.boottime` is a read-only sysctl.
boot_epoch() {
  local raw
  raw=$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null || true)
  [[ "$raw" == *'sec = '* ]] || return 0
  print -r -- "${raw#*sec = }" | /usr/bin/awk -F'[, ]' '{print $1; exit}'
}

# Absolute epoch -> the human deadline the menu shows.
expiry_text() {
  [[ -n "$1" ]] || return 0
  /bin/date -r "$1" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || true
}

# --- read the published record (fixed line numbers, literal prefixes) ---
owned_pid=''
owned_sig=''
stored_expiry_text=''
expires_epoch=''
stored_boot=''
stored_state=''
stored_remaining=''
if [[ -f "$state_file" ]]; then
  owned_pid=$(/usr/bin/sed -n '1p' "$state_file" 2>/dev/null || true)
  owned_sig=$(/usr/bin/sed -n '2p' "$state_file" 2>/dev/null || true)
  stored_expiry_text=$(/usr/bin/sed -n 's/^Automatic stop: //p' "$state_file" 2>/dev/null | /usr/bin/head -n 1 || true)
  expires_epoch=$(/usr/bin/sed -n 's/^Expires: //p' "$state_file" 2>/dev/null | /usr/bin/head -n 1 || true)
  stored_boot=$(/usr/bin/sed -n 's/^Boot: //p' "$state_file" 2>/dev/null | /usr/bin/head -n 1 || true)
  stored_state=$(/usr/bin/sed -n 's/^State: //p' "$state_file" 2>/dev/null | /usr/bin/head -n 1 || true)
  stored_remaining=$(/usr/bin/sed -n 's/^Remaining: //p' "$state_file" 2>/dev/null | /usr/bin/head -n 1 || true)
fi

current_epoch=$(now_epoch)
current_boot=$(boot_epoch)

# Critical published numbers are validated before any arithmetic touches them.
# A value that is not a plain number, or is outside the 1..86400 second contract
# (or, for an absolute deadline, is not ahead of now within that same bound), is
# cleared and treated as absent. A corrupt or hostile record therefore fails
# closed instead of being interpreted as a very long awake request.
if [[ -n "$expires_epoch" ]] && {
     [[ "$expires_epoch" != <-> ]] \
     || (( expires_epoch <= current_epoch )) \
     || (( expires_epoch - current_epoch > 86400 ))
   }; then
  expires_epoch=''
fi
if [[ -n "$stored_remaining" && "$stored_remaining" != <1-86400> ]]; then
  stored_remaining=''
fi

# A record only ever owns a process whose exact start signature and command
# line still match the stored values. The legacy v1.4 helper used `-d -i`; those
# sessions are still recognized (and can still be stopped) without ever killing
# a process that does not match the stored signature.
owned_cmd_ok() {
  [[ "$1" == *'/usr/bin/caffeinate -i -t '* || "$1" == *'/usr/bin/caffeinate -d -i -t '* ]]
}

owned_active=0
if [[ "$owned_pid" == <1-> && -n "$owned_sig" ]]; then
  actual=$(/bin/ps -p "$owned_pid" -o lstart= -o command= 2>/dev/null || true)
  if [[ -n "$actual" && "$actual" == "$owned_sig" ]] && owned_cmd_ok "$actual"; then
    owned_active=1
  fi
fi

# A paused record holds no process. It is only live while its boot identity
# matches and its original absolute deadline has not passed; anything else is
# stale and removed, so it can never be revived after a reboot or an expiry.
paused=0
if [[ "$stored_state" == 'paused' && "$stored_remaining" == <1-86400> && -n "$expires_epoch" ]]; then
  if [[ -n "$current_boot" && "$stored_boot" == "$current_boot" ]] && (( current_epoch < expires_epoch )); then
    paused=1
  fi
fi
if [[ "$stored_state" == 'paused' && "$paused" == 0 && "$owned_active" == 0 ]]; then
  /bin/rm -f "$state_file"
fi

live=0
if (( owned_active )); then live=1; fi
if (( paused )); then live=1; fi

# The deadline shown for the current record: the epoch when present, otherwise
# the legacy human string carried by an old three-line record.
display_expiry() {
  if [[ -n "$expires_epoch" ]]; then expiry_text "$expires_epoch"; else print -r -- "$stored_expiry_text"; fi
}

# Recover a legacy record's remaining whole seconds from its command's `-t`
# value and the owned process's elapsed time. `ps -o etime=` is the supported
# BSD keyword (etimes= does not exist on macOS) and prints `[[dd-]hh:]mm:ss`;
# this parses every documented shape. Only used while suspending a legacy
# session; returns non-zero when the value cannot be recovered.
legacy_remaining() {
  local secs elapsed left days=0 hours=0 minutes=0 seconds=0
  secs=${1##*-t }
  secs=${secs%% *}
  # Only a whole number of seconds inside the 1..86400 contract is recoverable;
  # a corrupt `-t` value is reported as unrecoverable rather than trusted.
  [[ "$secs" == <1-86400> ]] || return 1
  elapsed=$(/bin/ps -p "$owned_pid" -o etime= 2>/dev/null | /usr/bin/tr -d ' ' || true)
  [[ -n "$elapsed" ]] || return 1
  if [[ "$elapsed" == *-* ]]; then
    days=${elapsed%%-*}
    elapsed=${elapsed#*-}
  fi
  local parts
  parts=(${(s/:/)elapsed})
  case ${#parts[@]} in
    3) hours=${parts[1]}; minutes=${parts[2]}; seconds=${parts[3]} ;;
    2) minutes=${parts[1]}; seconds=${parts[2]} ;;
    1) seconds=${parts[1]} ;;
    *) return 1 ;;
  esac
  [[ "$days" == <-> && "$hours" == <-> && "$minutes" == <-> && "$seconds" == <-> ]] || return 1
  elapsed=$(( days * 86400 + hours * 3600 + minutes * 60 + seconds ))
  left=$(( secs - elapsed ))
  # Recovered time is bounded like every other duration the helper can hold.
  [[ "$left" == <1-86400> ]] || return 1
  print -r -- "$left"
}

# Publish a complete record atomically: a reader either sees the previous valid
# record or this one, never a partial write.
write_record() {
  local pid=$1 sig=$2 exp=$3 state=$4 remain=$5
  local tmp="$state_file.tmp.$$"
  {
    print -r -- "$pid"
    print -r -- "$sig"
    print -r -- "Automatic stop: $(expiry_text "$exp")"
    print -r -- "Boot: $current_boot"
    print -r -- "State: $state"
    print -r -- "Expires: $exp"
    if [[ "$state" == 'paused' ]]; then
      print -r -- "Remaining: $remain"
    fi
  } > "$tmp"
  /bin/mv -f "$tmp" "$state_file"
}

# Release the exact owned process only. A failed TERM is escalated to KILL only
# after re-verifying the same pid still carries the same stored signature, so an
# unrelated process can never be signalled.
stop_owned() {
  if (( owned_active )); then
    /bin/kill -TERM "$owned_pid" 2>/dev/null || true
    /bin/sleep 0.05
    if /bin/kill -0 "$owned_pid" 2>/dev/null; then
      actual=$(/bin/ps -p "$owned_pid" -o lstart= -o command= 2>/dev/null || true)
      if [[ "$actual" == "$owned_sig" ]] && owned_cmd_ok "$actual"; then
        /bin/kill -KILL "$owned_pid" 2>/dev/null || true
      fi
    fi
  fi
}

# Start a bounded idle-sleep assertion and publish its record. A spawn that
# cannot be verified is terminated and reported, never published.
start_session() {
  local secs=$1 exp=$2 pid sig
  # Every start path (new request, resume, or a recovered legacy timer) is
  # clamped to the same 1..86400 contract before a process can be spawned.
  [[ "$secs" == <1-86400> ]] || return 1
  /usr/bin/nohup /usr/bin/caffeinate -i -t "$secs" </dev/null >/dev/null 2>&1 &
  pid=$!
  /bin/sleep 0.15
  sig=$(/bin/ps -p "$pid" -o lstart= -o command= 2>/dev/null || true)
  if [[ -z "$sig" || "$sig" != *'/usr/bin/caffeinate -i -t '* ]]; then
    /bin/kill -TERM "$pid" 2>/dev/null || true
    return 1
  fi
  if ! write_record "$pid" "$sig" "$exp" active ''; then
    /bin/kill -TERM "$pid" 2>/dev/null || true
    return 1
  fi
  print 'Codex Work Mode: ON'
  print -r -- "Automatic stop: $(expiry_text "$exp")"
  print 'Run the shortcut again to stop early.'
  return 0
}

# --- status ---
if [[ "$mode" == 'status' ]]; then
  if (( owned_active )); then
    print 'ON — system idle sleep prevented.'
    print -r -- "Automatic stop: $(display_expiry)"
    if [[ -n "$expires_epoch" ]]; then
      print -r -- "Expires: $expires_epoch"
    fi
    exit 0
  fi
  if (( paused )); then
    # Report the CURRENT remaining time against the original absolute deadline,
    # never the value stored at pause time. Reads are side-effect free: the
    # stored record is not rewritten, so a status read can never extend it.
    left=$(( expires_epoch - current_epoch ))
    if (( left > stored_remaining )); then left=$stored_remaining; fi
    (( left > 0 )) || left=0
    print 'PAUSED — timer held while the Mac is not eligible to stay awake.'
    print -r -- "Automatic stop: $(display_expiry)"
    print -r -- "Expires: $expires_epoch"
    print -r -- "Remaining: $left"
    exit 0
  fi
  print 'OFF — normal sleep settings apply.'
  exit 0
fi

# --- off (active, legacy, or paused; a paused timer stays cancelable) ---
if [[ "$mode" == 'off' || ( "$mode" == 'toggle' && "$live" == 1 ) ]]; then
  stop_owned
  /bin/rm -f "$state_file"
  print 'Codex Work Mode: OFF'
  print 'Normal sleep settings apply.'
  exit 0
fi

# --- suspend: release only the exact owned process, keep the logical timer ---
if [[ "$mode" == 'suspend' ]]; then
  if (( paused )); then
    print 'Codex Work Mode: timer already paused.'
    exit 0
  fi
  if (( owned_active )); then
    keep_exp=''
    left=''
    if [[ -n "$expires_epoch" ]]; then
      keep_exp="$expires_epoch"
      left=$(( expires_epoch - current_epoch ))
    else
      left=$(legacy_remaining "$owned_sig" || true)
      if [[ "$left" == <1-> ]]; then
        keep_exp=$(( current_epoch + left ))
      fi
    fi
    if [[ "$left" != <1-> || -z "$keep_exp" ]]; then
      # The remaining logical time cannot be recovered (legacy record without a
      # readable elapsed time). Release it cleanly instead of holding awake
      # behind a lock; there is no state left to revive.
      stop_owned
      /bin/rm -f "$state_file"
      print 'Codex Work Mode: OFF (timer released while suspending).'
      exit 0
    fi
    stop_owned
    if ! write_record "$owned_pid" "$owned_sig" "$keep_exp" paused "$left"; then
      # The process was released but the paused record could not be published;
      # remove the now-stale record rather than leave a dangling claim.
      /bin/rm -f "$state_file"
      print 'Codex Work Mode: could not pause the timer.' >&2
      exit 1
    fi
    print 'Codex Work Mode: ON (paused)'
    print -r -- "Automatic stop: $(expiry_text "$keep_exp")"
    print -r -- "Remaining: $left"
    exit 0
  fi
  print 'Codex Work Mode: no timer to pause.'
  exit 0
fi

# --- resume: only the remaining whole seconds, never an extended deadline ---
if [[ "$mode" == 'resume' ]]; then
  if (( owned_active )); then
    print 'Codex Work Mode: timer already active.'
    exit 0
  fi
  if (( paused )); then
    left=$(( expires_epoch - current_epoch ))
    if (( left > stored_remaining )); then left=$stored_remaining; fi
    if (( left < 1 )); then
      /bin/rm -f "$state_file"
      print 'Codex Work Mode: OFF (deadline reached while paused).'
      exit 0
    fi
    if start_session "$left" "$expires_epoch"; then exit 0; fi
    print 'Codex Work Mode: could not resume the timer.' >&2
    exit 1
  fi
  print 'Codex Work Mode: no paused timer to resume.'
  exit 0
fi

# --- on / toggle while inactive: start a new bounded timer ---
if (( owned_active )); then
  print 'Codex Work Mode is already ON. Run again to turn it off.'
  exit 0
fi

exp=$(( current_epoch + duration ))
if [[ "$paused_request" == 'paused' ]]; then
  write_record '' '' "$exp" paused "$duration"
  print 'Codex Work Mode: ON (paused)'
  print -r -- "Automatic stop: $(expiry_text "$exp")"
  print -r -- "Remaining: $duration"
  print 'The timer is held until the Mac is eligible to stay awake.'
  exit 0
fi
if (( paused )); then
  # An explicit new request replaces a paused record; there is no process to
  # release.
  /bin/rm -f "$state_file"
fi
if start_session "$duration" "$exp"; then exit 0; fi
print 'Codex Work Mode: could not start the timer.' >&2
exit 1
