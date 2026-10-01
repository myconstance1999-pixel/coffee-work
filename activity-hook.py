#!/usr/bin/python3
"""Codex Work Mode activity hook receiver (v1.4).

A synchronous, network-free, Python-3-standard-library command hook for the
Codex user hooks file. Codex runs it once per hook event with the event payload
as JSON on stdin. It maintains one minimal activity snapshot so the Codex Work
Mode menu-bar app can keep the Mac awake while a local Codex *desktop* task
works.

Privacy contract
----------------
The snapshot persists only: the event name, hashed session/turn identifiers,
timestamps, and the desktop owner pid plus start signature. Prompt text, tool
input, tool output, cwd, transcript path, model, permission mode, and every
other payload field are never read into the snapshot and never written. The
payload is parsed only for `hook_event_name`, `session_id`, and `turn_id`;
`transcript_path` and `last_assistant_message` are deliberately untouched.
No log file is kept; exactly one current state file is published.

Turn contract
-------------
* UserPromptSubmit opens a root turn.
* PreToolUse/PostToolUse refresh or resume an already-known root turn only;
  they never invent a turn.
* PermissionRequest marks a known turn waiting.
* Stop/Interrupt close exactly one turn, so a late Stop for an older turn can
  never clear a newer one.
* SessionEnd clears one session's turns. SessionStart does not mark work.
* Unknown or malformed events are ignored.
* Each turn is capped at 24 hours (stale-event safety); a long tool is never
  cut merely because events are sparse while its owner is alive.

Desktop filter
--------------
The owning Codex app-server is found by walking the hook process's ancestor
chain (`ps -axo pid=,ppid=,lstart=,comm=`). The nearest `codex` ancestor must be
an exactly admitted bundled binary inside /Applications/ChatGPT.app (or
Codex.app) -- either the legacy `Contents/Resources/codex` or the current
`Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex` -- and must be
owned by the desktop main app or a process inside the same app bundle. A CLI
codex, a headless/Pinland codex, or a bundled codex parented outside the app
bundle is rejected, even if some outer ancestor happens to be the desktop app.

A shell can never make this receiver grant, deny, block, or continue a Codex
turn: it always exits 0 and prints nothing, except `{}` for Stop (the officially
documented empty command output).

Test/QA-only flags
------------------
`--state-dir`, `--now`, `--process-table`, and `--ancestry-start-pid` exist so
the deterministic test suite and isolated QA can redirect state, freeze the
clock, and supply fixture ancestry. The installed hooks.codex.json template
never passes them, and the owner filter never consults an environment variable.
"""

import argparse
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import time

VERSION = 1
MAX_TURN_AGE_SECONDS = 24 * 60 * 60
MAX_TURN_FUTURE_SECONDS = 60

HANDLED_EVENTS = frozenset(
    (
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "Stop",
        "Interrupt",
        "SessionEnd",
    )
)

# Bundled desktop Codex locations that may own activity. A bundled codex that
# lives elsewhere (for example Pinland or a headless server) is not accepted.
APP_BUNDLES = ("/Applications/ChatGPT.app", "/Applications/Codex.app")

# Exact bundled codex executables relative to an app bundle. The legacy layout
# ships the binary directly under Contents/Resources; the current desktop layout
# nests a CodexCLI.app helper under Contents/Resources/codex-cli. Only these
# exact paths are admitted, so an arbitrary binary under the bundle and any
# external daemon remain rejected.
BUNDLED_CODEX_RELATIVE_PATHS = (
    "Contents/Resources/codex",
    "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
)

PS_PATH = "/bin/ps"
PS_ARGUMENTS = ["-axo", "pid=,ppid=,lstart=,comm="]
STATE_FILE_NAME = "state.json"
LOCK_FILE_NAME = "lock"


def default_state_dir():
    """The installed activity directory inside the app support folder."""
    return os.path.join(
        os.path.expanduser("~"),
        "Library",
        "Application Support",
        "Codex Work Mode",
        "codex-activity",
    )


# ---------------------------------------------------------------------------
# Process ancestry
# ---------------------------------------------------------------------------


def parse_process_table(text):
    """Parse `ps -axo pid=,ppid=,lstart=,comm=` output into records.

    `lstart` is always five whitespace-separated tokens, so the remainder after
    them is the command path even when it contains spaces.
    """
    records = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 8:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        records.append(
            {
                "pid": pid,
                "ppid": ppid,
                "start": " ".join(parts[2:7]),
                "comm": " ".join(parts[7:]),
            }
        )
    return records


def read_process_table():
    """Read the live process table read-only. Failures yield an empty table."""
    try:
        completed = subprocess.run(
            [PS_PATH] + PS_ARGUMENTS,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        )
    except Exception:
        return []
    if completed.returncode != 0:
        return []
    try:
        text = completed.stdout.decode("utf-8", "replace")
    except Exception:
        return []
    return parse_process_table(text)


def _basename(path):
    return path.rsplit("/", 1)[-1] if path else ""


def is_codex_command(comm):
    return _basename(comm) == "codex"


def bundled_app_for(comm):
    """The desktop bundle that owns `comm`, or None when it is not bundled.

    Matches only the exact admitted bundled codex executables (legacy
    Contents/Resources/codex and the current codex-cli/CodexCLI.app layout).
    """
    for app in APP_BUNDLES:
        for relative in BUNDLED_CODEX_RELATIVE_PATHS:
            if comm == app + "/" + relative:
                return app
    return None


def app_main_executable(app):
    name = "ChatGPT" if app.endswith("ChatGPT.app") else "Codex"
    return app + "/Contents/MacOS/" + name


def _find_app_main(by_pid, record, app):
    """Walk further up from `record` for the desktop main executable."""
    main_executable = app_main_executable(app)
    current = by_pid.get(record["ppid"])
    seen = set()
    while current is not None and current["pid"] not in seen:
        seen.add(current["pid"])
        if current["comm"] == main_executable:
            return current
        current = by_pid.get(current["ppid"])
    return None


def classify_owner(records, hook_pid):
    """Identify the desktop app-server owner for a hook process.

    Returns an owner dict `{pid, start, main_pid, main_start, app}` when the
    nearest codex ancestor is the desktop-bundled app-server owned by the main
    app or one of its services; otherwise None.
    """
    by_pid = {}
    for record in records:
        by_pid[record["pid"]] = record

    chain = []
    pid = hook_pid
    seen = set()
    while pid and pid not in seen and pid in by_pid:
        seen.add(pid)
        chain.append(by_pid[pid])
        pid = by_pid[pid]["ppid"]

    nearest = None
    for record in chain:
        if is_codex_command(record["comm"]):
            nearest = record
            break
    if nearest is None:
        return None

    app = bundled_app_for(nearest["comm"])
    if app is None:
        return None  # CLI or otherwise non-desktop codex.

    # A nested codex (subagent) may sit under the app-server codex. Climb while
    # the parent is still the same bundled codex so the topmost one is recorded.
    top = nearest
    parent = by_pid.get(nearest["ppid"])
    while (
        parent is not None
        and is_codex_command(parent["comm"])
        and bundled_app_for(parent["comm"]) == app
    ):
        top = parent
        parent = by_pid.get(parent["ppid"])

    if parent is None:
        return None

    main_executable = app_main_executable(app)
    if parent["comm"] == main_executable:
        main = parent
    elif parent["comm"].startswith(app + "/Contents/"):
        # A service inside the same bundle (for example a Contents/Frameworks
        # helper). Record the main executable when the chain reaches it.
        main = _find_app_main(by_pid, parent, app)
    else:
        return None  # Owned by a terminal, launcher, Pinland, or anything else.

    return {
        "pid": top["pid"],
        "start": top["start"],
        "main_pid": main["pid"] if main is not None else None,
        "main_start": main["start"] if main is not None else None,
        "app": app,
    }


# ---------------------------------------------------------------------------
# State reduction
# ---------------------------------------------------------------------------


def _hash(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


def _empty_state(owner, now):
    return {
        "version": VERSION,
        "updated": now,
        "last_event": None,
        "owner": owner,
        "turns": [],
    }


def _load_turns(state):
    turns = {}
    raw = state.get("turns")
    if not isinstance(raw, list):
        return turns
    for item in raw:
        if not isinstance(item, dict):
            continue
        session = item.get("session")
        turn = item.get("turn")
        if not isinstance(session, str) or not isinstance(turn, str):
            continue
        if not session or not turn:
            continue
        try:
            opened = float(item.get("opened", 0))
            refreshed = float(item.get("refreshed", opened))
        except (TypeError, ValueError):
            continue
        turns[(session, turn)] = {
            "session": session,
            "turn": turn,
            "state": "waiting" if item.get("state") == "waiting" else "working",
            "opened": opened,
            "refreshed": refreshed,
        }
    return turns


def _serialize_turns(turns):
    return [turns[key] for key in sorted(turns, key=lambda k: (turns[k]["opened"], k))]


def reduce_state(state, event, session_id, turn_id, now, owner):
    """Apply one event. Returns `(state, changed)`.

    `state` may be None (no readable snapshot yet). Owner changes reset all
    turns because the previous owner's records are no longer trustworthy.
    """
    changed = False
    if not isinstance(state, dict) or state.get("owner") != owner:
        state = _empty_state(owner, now)
        changed = True

    turns = _load_turns(state)

    # Stale-event safety: cap each turn at 24 hours of age.
    for key in list(turns):
        age = now - turns[key]["opened"]
        if age > MAX_TURN_AGE_SECONDS or age < -MAX_TURN_FUTURE_SECONDS:
            del turns[key]
            changed = True

    if event not in HANDLED_EVENTS:
        if changed:
            state["turns"] = _serialize_turns(turns)
            state["updated"] = now
        return state, changed

    session = _hash(session_id) if isinstance(session_id, str) and session_id else None
    turn = _hash(turn_id) if isinstance(turn_id, str) and turn_id else None

    if event == "UserPromptSubmit":
        if session is None or turn is None:
            # Official payloads carry a nonempty turn id. Without one no later
            # Stop/Interrupt could ever name and close this turn, so ignore the
            # event rather than synthesize an id that Stop cannot close.
            return state, changed
        key = (session, turn)
        record = turns.get(key)
        if record is None:
            record = {
                "session": session,
                "turn": turn,
                "state": "working",
                "opened": now,
                "refreshed": now,
            }
            turns[key] = record
            changed = True
        else:
            if record["state"] != "working" or record["refreshed"] != now:
                record["state"] = "working"
                record["refreshed"] = now
                changed = True
    elif event in ("PreToolUse", "PostToolUse"):
        if session is not None and turn is not None:
            record = turns.get((session, turn))
            if record is not None and (
                record["state"] != "working" or record["refreshed"] != now
            ):
                record["state"] = "working"
                record["refreshed"] = now
                changed = True
    elif event == "PermissionRequest":
        if session is not None and turn is not None:
            record = turns.get((session, turn))
            if record is not None and (
                record["state"] != "waiting" or record["refreshed"] != now
            ):
                record["state"] = "waiting"
                record["refreshed"] = now
                changed = True
    elif event in ("Stop", "Interrupt"):
        if session is not None and turn is not None:
            if turns.pop((session, turn), None) is not None:
                changed = True
    elif event == "SessionEnd":
        if session is not None:
            for key in list(turns):
                if key[0] == session:
                    del turns[key]
                    changed = True

    if changed:
        state["turns"] = _serialize_turns(turns)
        state["last_event"] = event
        state["updated"] = now
    return state, changed


# ---------------------------------------------------------------------------
# Locking and publication
# ---------------------------------------------------------------------------


def acquire_lock(state_dir):
    os.makedirs(state_dir, mode=0o700, exist_ok=True)
    try:
        os.chmod(state_dir, 0o700)
    except OSError:
        pass
    lock_path = os.path.join(state_dir, LOCK_FILE_NAME)
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        os.chmod(lock_path, 0o600)
    except OSError:
        pass
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    return descriptor


def read_state(state_dir):
    path = os.path.join(state_dir, STATE_FILE_NAME)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def write_state(state_dir, state):
    """Atomically publish the snapshot with owner-only permissions."""
    path = os.path.join(state_dir, STATE_FILE_NAME)
    temporary = os.path.join(state_dir, ".%s.tmp.%d" % (STATE_FILE_NAME, os.getpid()))
    payload = json.dumps(state, separators=(",", ":"), sort_keys=True).encode("utf-8")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def build_parser():
    parser = argparse.ArgumentParser(
        description="Codex Work Mode activity hook receiver (test flags only)."
    )
    parser.add_argument("--state-dir", default=None)
    parser.add_argument("--now", type=float, default=None)
    parser.add_argument("--process-table", default=None)
    parser.add_argument("--ancestry-start-pid", type=int, default=None)
    return parser


def _read_fixture_table(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return parse_process_table(handle.read())
    except Exception:
        return []


def main(argv=None):
    parser = build_parser()
    try:
        args, _unknown = parser.parse_known_args(argv)
    except SystemExit:
        return 0

    try:
        raw = sys.stdin.read()
        payload = json.loads(raw)
    except Exception:
        return 0
    if not isinstance(payload, dict):
        return 0

    event = payload.get("hook_event_name")
    if not isinstance(event, str) or event not in HANDLED_EVENTS:
        return 0
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return 0
    turn_id = payload.get("turn_id")
    if not isinstance(turn_id, str) or not turn_id:
        # Missing, empty, or non-string ids carry no closeable identity.
        turn_id = None

    now = args.now if args.now is not None else time.time()

    if args.process_table:
        records = _read_fixture_table(args.process_table)
    else:
        records = read_process_table()
    ancestry_pid = (
        args.ancestry_start_pid
        if args.ancestry_start_pid is not None
        else os.getpid()
    )
    owner = classify_owner(records, ancestry_pid)
    if owner is None:
        # Not a desktop-owned Codex task: stay silent and leave state alone.
        if event == "Stop":
            sys.stdout.write("{}\n")
        return 0

    state_dir = args.state_dir or default_state_dir()
    try:
        descriptor = acquire_lock(state_dir)
    except Exception:
        if event == "Stop":
            sys.stdout.write("{}\n")
        return 0
    try:
        state = read_state(state_dir)
        new_state, changed = reduce_state(
            state, event, session_id, turn_id, now, owner
        )
        if changed:
            write_state(state_dir, new_state)
    except Exception:
        pass
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass

    if event == "Stop":
        sys.stdout.write("{}\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # A hook must never break a Codex turn.
        sys.exit(0)
