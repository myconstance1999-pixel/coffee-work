#!/usr/bin/python3
"""Deterministic tests for the v1.4 activity hook receiver.

Covers the pure ancestry filter and state reducer, the installed receiver's
stdin/output/exit behavior, secure permissions and atomic publication, fcntl
locking under concurrent hooks, the absence of sensitive fields in the snapshot,
and the desktop-vs-CLI/headless owner filter.

Everything runs against temporary state directories and fixture process tables;
no real `ps`, no home state, no model call, and no Codex file is touched.
"""

import importlib.util
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(ROOT, "activity-hook.py")
RENDER_HOOKS = os.path.join(ROOT, "hooks", "render-hooks.py")
HOOKS_TEMPLATE = os.path.join(ROOT, "hooks", "hooks.template.json")
PY = "/usr/bin/python3"
MAIN = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex"
CODEX_APP_MAIN = "/Applications/Codex.app/Contents/MacOS/Codex"
CODEX_APP_CODEX = "/Applications/Codex.app/Contents/Resources/codex"
# Current desktop layout: a nested CodexCLI.app helper under codex-cli.
CODEX_NEW = (
    "/Applications/ChatGPT.app/Contents/Resources/codex-cli/"
    "CodexCLI.app/Contents/MacOS/codex"
)
CODEX_APP_NEW = (
    "/Applications/Codex.app/Contents/Resources/codex-cli/"
    "CodexCLI.app/Contents/MacOS/codex"
)

failures = 0
checks = 0


def check(name, condition, detail=""):
    global failures, checks
    checks += 1
    if condition:
        print("PASS %s" % name)
    else:
        failures += 1
        print("FAIL %s%s" % (name, (" :: " + detail) if detail else ""))


def load_module():
    spec = importlib.util.spec_from_file_location("activity_hook_under_test", HOOK)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_renderer():
    spec = importlib.util.spec_from_file_location("render_hooks_under_test", RENDER_HOOKS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def proc_line(pid, ppid, comm, start="Thu Sep 25 10:00:00 2026"):
    return "%d %d %s %s" % (pid, ppid, start, comm)


def table(*lines):
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Pure ancestry filter
# ---------------------------------------------------------------------------


def ancestry_checks(mod):
    print("\n== ancestry filter (fixture process tables) ==")

    desktop = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(14831, 1, MAIN),
        proc_line(14864, 14831, CODEX),
        proc_line(500, 14864, "/usr/bin/python3"),
    )
    owner = mod.classify_owner(mod.parse_process_table(desktop), 500)
    check(
        "desktop main -> bundled codex is accepted",
        owner is not None and owner["pid"] == 14864 and owner["main_pid"] == 14831,
        repr(owner),
    )

    codex_app = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(900, 1, CODEX_APP_MAIN),
        proc_line(901, 900, CODEX_APP_CODEX),
        proc_line(500, 901, "/usr/bin/python3"),
    )
    owner = mod.classify_owner(mod.parse_process_table(codex_app), 500)
    check(
        "Codex.app equivalent is accepted",
        owner is not None and owner["pid"] == 901 and owner["app"].endswith("Codex.app"),
        repr(owner),
    )

    # Current desktop layout: the codex binary lives in a nested CodexCLI.app.
    new_layout = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(49912, 1, MAIN),
        proc_line(49964, 49912, CODEX_NEW),
        proc_line(500, 49964, "/usr/bin/python3"),
    )
    owner = mod.classify_owner(mod.parse_process_table(new_layout), 500)
    check(
        "new ChatGPT layout nested codex is accepted",
        owner is not None and owner["pid"] == 49964 and owner["main_pid"] == 49912,
        repr(owner),
    )

    new_codex_app = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(900, 1, CODEX_APP_MAIN),
        proc_line(901, 900, CODEX_APP_NEW),
        proc_line(500, 901, "/usr/bin/python3"),
    )
    owner = mod.classify_owner(mod.parse_process_table(new_codex_app), 500)
    check(
        "new Codex.app layout nested codex is accepted",
        owner is not None and owner["pid"] == 901 and owner["app"].endswith("Codex.app"),
        repr(owner),
    )

    new_layout_service = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(49912, 1, MAIN),
        proc_line(
            49913,
            49912,
            "/Applications/ChatGPT.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/CodexHelper",
        ),
        proc_line(49964, 49913, CODEX_NEW),
        proc_line(500, 49964, "/usr/bin/python3"),
    )
    owner = mod.classify_owner(mod.parse_process_table(new_layout_service), 500)
    check(
        "new layout nested codex owned by an app-bundle service is accepted",
        owner is not None and owner["pid"] == 49964 and owner["main_pid"] == 49912,
        repr(owner),
    )

    service = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(14831, 1, MAIN),
        proc_line(
            14850,
            14831,
            "/Applications/ChatGPT.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/CodexHelper",
        ),
        proc_line(14864, 14850, CODEX),
        proc_line(500, 14864, "/usr/bin/python3"),
    )
    owner = mod.classify_owner(mod.parse_process_table(service), 500)
    check(
        "app-bundle service owner is accepted",
        owner is not None and owner["pid"] == 14864 and owner["main_pid"] == 14831,
        repr(owner),
    )

    nested = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(14831, 1, MAIN),
        proc_line(14864, 14831, CODEX),
        proc_line(14870, 14864, CODEX),
        proc_line(500, 14870, "/usr/bin/python3"),
    )
    owner = mod.classify_owner(mod.parse_process_table(nested), 500)
    check(
        "nested subagent codex resolves to the top app-server",
        owner is not None and owner["pid"] == 14864,
        repr(owner),
    )

    headless = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(7777, 1, "/Applications/Pinland.app/Contents/MacOS/Pinland"),
        proc_line(7778, 7777, CODEX),
        proc_line(500, 7778, "/usr/bin/python3"),
    )
    check(
        "headless/Pinland bundled codex is rejected",
        mod.classify_owner(mod.parse_process_table(headless), 500) is None,
    )

    cli = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(14831, 1, MAIN),
        proc_line(4000, 14831, "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        proc_line(5000, 4000, "/usr/local/bin/codex"),
        proc_line(500, 5000, "/usr/bin/python3"),
    )
    check(
        "CLI codex with a desktop outer ancestor is rejected",
        mod.classify_owner(mod.parse_process_table(cli), 500) is None,
    )

    terminal_bundled = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(14831, 1, MAIN),
        proc_line(4000, 14831, "/bin/zsh"),
        proc_line(14864, 4000, CODEX),
        proc_line(500, 14864, "/usr/bin/python3"),
    )
    check(
        "bundled codex parented outside the app bundle is rejected",
        mod.classify_owner(mod.parse_process_table(terminal_bundled), 500) is None,
    )

    new_terminal = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(49912, 1, MAIN),
        proc_line(4000, 49912, "/bin/zsh"),
        proc_line(49964, 4000, CODEX_NEW),
        proc_line(500, 49964, "/usr/bin/python3"),
    )
    check(
        "new-layout codex parented by a terminal is rejected",
        mod.classify_owner(mod.parse_process_table(new_terminal), 500) is None,
    )

    new_headless = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(7777, 1, "/Applications/Pinland.app/Contents/MacOS/Pinland"),
        proc_line(7778, 7777, CODEX_NEW),
        proc_line(500, 7778, "/usr/bin/python3"),
    )
    check(
        "new-layout codex parented by headless/Pinland is rejected",
        mod.classify_owner(mod.parse_process_table(new_headless), 500) is None,
    )

    # The new binary used as a standalone CLI under a node tool process, even
    # with the desktop main app as an outer ancestor.
    new_cli_node = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(49912, 1, MAIN),
        proc_line(4000, 49912, "/opt/homebrew/bin/node"),
        proc_line(49964, 4000, CODEX_NEW),
        proc_line(500, 49964, "/usr/bin/python3"),
    )
    check(
        "standalone new-layout codex under a node tool process is rejected",
        mod.classify_owner(mod.parse_process_table(new_cli_node), 500) is None,
    )

    # Malicious prefix/suffix lookalikes must not match the exact admitted path.
    for label, fake in (
        ("prefixed", "/tmp/Applications/ChatGPT.app" + CODEX_NEW[len("/Applications/ChatGPT.app"):]),
        ("suffixed", CODEX_NEW + "-evil"),
        ("bundle-suffixed", "/Applications/ChatGPT.app-evil" + CODEX_NEW[len("/Applications/ChatGPT.app"):]),
    ):
        lookalike = table(
            proc_line(1, 0, "/sbin/launchd"),
            proc_line(49912, 1, MAIN),
            proc_line(49964, 49912, fake),
            proc_line(500, 49964, "/usr/bin/python3"),
        )
        check(
            "lookalike %s path is rejected" % label,
            mod.classify_owner(mod.parse_process_table(lookalike), 500) is None,
        )

    # Unrelated install directories are not desktop bundles.
    unrelated = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(49912, 1, MAIN),
        proc_line(
            4000,
            49912,
            "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex",
        ),
        proc_line(500, 4000, "/usr/bin/python3"),
    )
    check(
        "unrelated install-directory codex is rejected",
        mod.classify_owner(mod.parse_process_table(unrelated), 500) is None,
    )

    no_codex = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(500, 1, "/usr/bin/python3"),
    )
    check(
        "no codex ancestor is rejected",
        mod.classify_owner(mod.parse_process_table(no_codex), 500) is None,
    )


# ---------------------------------------------------------------------------
# Pure state reducer
# ---------------------------------------------------------------------------


def turn_states(state):
    return sorted(t["state"] for t in state.get("turns", []))


def turns_for(state, session, turn):
    for item in state.get("turns", []):
        if item["session"] == mod_hash(session) and item["turn"] == mod_hash(turn):
            return item
    return None


_MOD = None


def mod_hash(value):
    return _MOD._hash(value)


def reducer_checks(mod):
    global _MOD
    _MOD = mod
    print("\n== state reducer ==")
    owner = {"pid": 14864, "start": "Thu Sep 25 10:00:00 2026", "main_pid": 14831,
             "main_start": "Thu Sep 25 09:59:00 2026", "app": "/Applications/ChatGPT.app"}

    state = None
    state, changed = mod.reduce_state(state, "UserPromptSubmit", "s1", "t1", 1000, owner)
    check("UserPromptSubmit opens a working turn", changed and turn_states(state) == ["working"])

    state, changed = mod.reduce_state(state, "PermissionRequest", "s1", "t1", 1010, owner)
    check("PermissionRequest marks a known turn waiting", changed and turn_states(state) == ["waiting"])

    state, changed = mod.reduce_state(state, "PreToolUse", "s1", "t1", 1020, owner)
    check("PreToolUse resumes a waiting turn to working", changed and turn_states(state) == ["working"])

    state, changed = mod.reduce_state(state, "PostToolUse", "s1", "t1", 1030, owner)
    check("PostToolUse refreshes a known turn", changed and turn_states(state) == ["working"])

    state, changed = mod.reduce_state(state, "Stop", "s1", "t1", 1040, owner)
    check("Stop closes the exact turn", changed and state["turns"] == [])

    # Duplicate and out-of-order events.
    state, changed = mod.reduce_state(state, "PostToolUse", "s1", "t1", 1050, owner)
    check("PostToolUse cannot invent a turn after Stop", not changed and state["turns"] == [])
    state, changed = mod.reduce_state(state, "PreToolUse", "s1", "t1", 1051, owner)
    check("PreToolUse cannot invent a turn", not changed and state["turns"] == [])
    state, changed = mod.reduce_state(state, "Stop", "s1", "t1", 1052, owner)
    check("duplicate Stop is a no-op", not changed)

    # Multiple tasks and old Stop vs newer turn.
    state, _ = mod.reduce_state(state, "UserPromptSubmit", "s1", "t1", 1100, owner)
    state, _ = mod.reduce_state(state, "UserPromptSubmit", "s1", "t2", 1110, owner)
    state, _ = mod.reduce_state(state, "UserPromptSubmit", "s2", "t3", 1120, owner)
    check("multiple tasks aggregate", len(state["turns"]) == 3)
    state, changed = mod.reduce_state(state, "Stop", "s1", "t1", 1130, owner)
    check(
        "an old Stop clears only its own turn",
        changed and turns_for(state, "s1", "t2") is not None
        and turns_for(state, "s2", "t3") is not None
        and turns_for(state, "s1", "t1") is None,
    )
    state, changed = mod.reduce_state(state, "Stop", "s1", "t2", 1140, owner)
    check("a second Stop clears the newer turn", changed and len(state["turns"]) == 1)

    # Duplicates of open events.
    state, first = mod.reduce_state(state, "UserPromptSubmit", "s2", "t3", 1150, owner)
    opened = turns_for(state, "s2", "t3")["opened"]
    state, duplicate = mod.reduce_state(state, "UserPromptSubmit", "s2", "t3", 1160, owner)
    check(
        "duplicate UserPromptSubmit keeps the original open time",
        duplicate and turns_for(state, "s2", "t3")["opened"] == opened
        and len(state["turns"]) == 1,
    )

    # SessionEnd.
    state, _ = mod.reduce_state(state, "UserPromptSubmit", "s2", "t4", 1170, owner)
    state, _ = mod.reduce_state(state, "UserPromptSubmit", "s3", "t5", 1180, owner)
    state, changed = mod.reduce_state(state, "SessionEnd", "s2", None, 1190, owner)
    check(
        "SessionEnd clears one session and keeps others",
        changed and turns_for(state, "s3", "t5") is not None and len(state["turns"]) == 1,
    )

    # A UserPromptSubmit without a nonempty turn id must open nothing: a
    # synthesized id could never be named by a later Stop, so the turn would
    # stay awake forever.
    state = None
    for label, missing in (("missing", None), ("empty", ""), ("non-string", 12345)):
        state, _ = mod.reduce_state(state, "UserPromptSubmit", "s-noid", missing, 1000, owner)
        check("UserPromptSubmit with %s turn id opens no turn" % label,
              state.get("turns", []) == [], repr(state.get("turns")))
    state, changed = mod.reduce_state(state, "Stop", "s-noid", None, 1001, owner)
    check("a Stop with no turn id leaves no stale turn behind",
          state.get("turns", []) == [])

    # Ignored events.
    state, changed = mod.reduce_state(state, "SessionStart", "s9", "t9", 1200, owner)
    check("SessionStart is ignored", not changed and turns_for(state, "s9", "t9") is None)
    state, changed = mod.reduce_state(state, "Bogus", "s9", "t9", 1201, owner)
    check("unknown event is ignored", not changed)

    # Owner change resets records.
    other_owner = dict(owner, pid=99999, start="Fri Sep 26 10:00:00 2026")
    state, changed = mod.reduce_state(state, "UserPromptSubmit", "s4", "t6", 1300, other_owner)
    check(
        "owner pid/signature change discards older records",
        changed and len(state["turns"]) == 1 and turns_for(state, "s4", "t6") is not None,
    )

    # 24 hour cap.
    state = None
    state, _ = mod.reduce_state(state, "UserPromptSubmit", "s1", "t1", 0, owner)
    state, _ = mod.reduce_state(state, "PreToolUse", "s1", "t1", 86399, owner)
    check("a known turn under the 24h cap survives sparse events",
          turns_for(state, "s1", "t1") is not None)
    state, changed = mod.reduce_state(state, "PreToolUse", "s1", "t1", 86401, owner)
    check("a turn older than 24h is discarded", state["turns"] == [])


# ---------------------------------------------------------------------------
# Receiver process behavior
# ---------------------------------------------------------------------------


def write_fixture(directory, text, name="ps-table"):
    path = os.path.join(directory, name + ".txt")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return path


def run_hook(state_dir, fixture, payload, now=1000.0, start_pid=500):
    command = [
        PY, HOOK,
        "--state-dir", state_dir,
        "--now", str(now),
        "--process-table", fixture,
        "--ancestry-start-pid", str(start_pid),
    ]
    return subprocess.run(
        command,
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        timeout=15,
    )


def receiver_checks(mod, workdir):
    print("\n== receiver process, privacy, permissions, locking ==")
    desktop = table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(14831, 1, MAIN),
        proc_line(14864, 14831, CODEX),
        proc_line(500, 14864, "/usr/bin/python3"),
    )

    # Full work -> idle sequence.
    state_dir = os.path.join(workdir, "seq")
    fixture = write_fixture(workdir, desktop, "desktop")
    result = run_hook(state_dir, fixture, {
        "hook_event_name": "UserPromptSubmit", "session_id": "s1", "turn_id": "t1",
        "prompt": "hello",
    })
    check("receiver UserPromptSubmit exits 0 and stays silent",
          result.returncode == 0 and result.stdout == "", repr(result.stdout))
    with open(os.path.join(state_dir, "state.json"), encoding="utf-8") as handle:
        state = json.load(handle)
    check("receiver records one working turn", turn_states(state) == ["working"])

    run_hook(state_dir, fixture, {
        "hook_event_name": "Stop", "session_id": "s1", "turn_id": "t1",
        "last_assistant_message": "should be discarded",
    }, now=1010.0)
    with open(os.path.join(state_dir, "state.json"), encoding="utf-8") as handle:
        state = json.load(handle)
    check("receiver Stop yields no open turns (app then applies 120s grace)",
          state["turns"] == [])

    # End-to-end: the current nested-CodexCLI layout must classify and publish.
    new_dir = os.path.join(workdir, "new-layout")
    new_fixture = write_fixture(workdir, table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(49912, 1, MAIN),
        proc_line(49964, 49912, CODEX_NEW),
        proc_line(500, 49964, "/usr/bin/python3"),
    ), "desktop-new")
    result = run_hook(new_dir, new_fixture, {
        "hook_event_name": "UserPromptSubmit", "session_id": "s-new", "turn_id": "t-new",
    })
    new_state_path = os.path.join(new_dir, "state.json")
    check("receiver publishes for the new nested-CodexCLI layout",
          result.returncode == 0 and os.path.exists(new_state_path))
    if os.path.exists(new_state_path):
        with open(new_state_path, encoding="utf-8") as handle:
            new_state = json.load(handle)
        check("new-layout snapshot records the nested codex owner",
              new_state["owner"]["pid"] == 49964
              and new_state["owner"]["main_pid"] == 49912
              and new_state["owner"]["app"] == "/Applications/ChatGPT.app",
              repr(new_state.get("owner")))
        check("new-layout snapshot records one working turn",
              turn_states(new_state) == ["working"])

    # The same binary as a standalone CLI under node must stay unclassified.
    new_cli_dir = os.path.join(workdir, "new-layout-cli")
    new_cli_fixture = write_fixture(workdir, table(
        proc_line(1, 0, "/sbin/launchd"),
        proc_line(49912, 1, MAIN),
        proc_line(4000, 49912, "/opt/homebrew/bin/node"),
        proc_line(49964, 4000, CODEX_NEW),
        proc_line(500, 49964, "/usr/bin/python3"),
    ), "desktop-new-cli")
    result = run_hook(new_cli_dir, new_cli_fixture, {
        "hook_event_name": "UserPromptSubmit", "session_id": "s-new", "turn_id": "t-new",
    })
    check("receiver publishes nothing for the new binary as a node-hosted CLI",
          result.returncode == 0
          and not os.path.exists(os.path.join(new_cli_dir, "state.json")))

    # Stop prints exactly the documented empty object.
    result = run_hook(state_dir, fixture, {
        "hook_event_name": "Stop", "session_id": "s1", "turn_id": "t1",
        "last_assistant_message": None,
    }, now=1011.0)
    check("Stop returns {} and exit 0",
          result.returncode == 0 and result.stdout.strip() == "{}", repr(result.stdout))

    # Receiver CLI: a UserPromptSubmit with a missing, empty, or non-string turn
    # id must not open a turn (there would be no id for a later Stop to close).
    for label, bad_turn in (("missing", None), ("empty", ""), ("non-string", 12345)):
        noid_dir = os.path.join(workdir, "noid-" + label)
        noid_payload = {"hook_event_name": "UserPromptSubmit", "session_id": "s-noid"}
        if bad_turn is not None:
            noid_payload["turn_id"] = bad_turn
        result = run_hook(noid_dir, fixture, noid_payload, now=1020.0)
        opened = []
        state_path = os.path.join(noid_dir, "state.json")
        if os.path.exists(state_path):
            with open(state_path, encoding="utf-8") as handle:
                opened = json.load(handle).get("turns", [])
        check("receiver ignores UserPromptSubmit with %s turn id" % label,
              result.returncode == 0 and opened == [], repr(opened))
        run_hook(noid_dir, fixture, {
            "hook_event_name": "Stop", "session_id": "s-noid",
        }, now=1021.0)
        if os.path.exists(state_path):
            with open(state_path, encoding="utf-8") as handle:
                opened_after = json.load(handle).get("turns", [])
        else:
            opened_after = []
        check("receiver leaves no stale turn after a Stop with %s turn id" % label,
              opened_after == [], repr(opened_after))

    # Privacy: none of these values may reach the snapshot.
    secret_dir = os.path.join(workdir, "privacy")
    secrets = [
        "SUPERSECRETPROMPT",
        "SUPERSECRETCWD",
        "SUPERSECRETTRANSCRIPT",
        "SUPERSECRETMODEL",
        "SUPERSECRETTOOLINPUT",
        "SUPERSECRETTOOLOUTPUT",
        "SUPERSECRETASSISTANT",
    ]
    payload = {
        "hook_event_name": "PreToolUse",
        "session_id": "sess-privacy",
        "turn_id": "turn-privacy",
        "prompt": "SUPERSECRETPROMPT",
        "cwd": "/tmp/SUPERSECRETCWD",
        "transcript_path": "/tmp/SUPERSECRETTRANSCRIPT",
        "model": "gpt-5-SUPERSECRETMODEL",
        "permission_mode": "never",
        "tool_name": "shell",
        "tool_input": {"command": "SUPERSECRETTOOLINPUT"},
        "tool_response": "SUPERSECRETTOOLOUTPUT",
        "last_assistant_message": "SUPERSECRETASSISTANT",
    }
    # Seed a known turn first so the tool event is accepted.
    run_hook(secret_dir, fixture, {
        "hook_event_name": "UserPromptSubmit", "session_id": "sess-privacy",
        "turn_id": "turn-privacy", "prompt": "SUPERSECRETPROMPT",
    })
    run_hook(secret_dir, fixture, payload, now=1001.0)
    with open(os.path.join(secret_dir, "state.json"), encoding="utf-8") as handle:
        raw_state = handle.read()
    check("no sensitive payload value is persisted",
          all(secret not in raw_state for secret in secrets), raw_state)
    state = json.loads(raw_state)
    check("snapshot has only the documented top-level keys",
          set(state) <= {"version", "updated", "last_event", "owner", "turns"}, repr(set(state)))
    check("snapshot turn has only the documented keys",
          all(set(t) <= {"session", "turn", "state", "opened", "refreshed"} for t in state["turns"]))
    check("snapshot owner has only the documented keys",
          set(state["owner"]) <= {"pid", "start", "main_pid", "main_start", "app"})
    check("owner pid/start recorded", state["owner"]["pid"] == 14864
          and bool(state["owner"]["start"]))

    # Permissions.
    mode_dir = os.stat(state_dir).st_mode & 0o777
    check("state directory is 0700", mode_dir == 0o700, oct(mode_dir))
    mode_file = os.stat(os.path.join(state_dir, "state.json")).st_mode & 0o777
    check("state file is 0600", mode_file == 0o600, oct(mode_file))
    mode_lock = os.stat(os.path.join(state_dir, "lock")).st_mode & 0o777
    check("lock file is 0600", mode_lock == 0o600, oct(mode_lock))

    # No leftover temp files.
    leftovers = [n for n in os.listdir(state_dir) if n.startswith(".")]
    check("no temporary publication files remain", leftovers == [], repr(leftovers))

    # Ignored events and malformed input never publish state.
    for name, payload in (
        ("SessionStart", {"hook_event_name": "SessionStart", "session_id": "s", "turn_id": "t"}),
        ("unknown", {"hook_event_name": "NotAnEvent", "session_id": "s", "turn_id": "t"}),
        ("malformed", None),
    ):
        ignored_dir = os.path.join(workdir, "ignored-" + name)
        if payload is None:
            command = [PY, HOOK, "--state-dir", ignored_dir, "--now", "1",
                       "--process-table", fixture, "--ancestry-start-pid", "500"]
            result = subprocess.run(command, input="{not json", capture_output=True,
                                    text=True, timeout=15)
        else:
            result = run_hook(ignored_dir, fixture, payload, now=1.0)
        check("%s is ignored without publishing" % name,
              result.returncode == 0
              and not os.path.exists(os.path.join(ignored_dir, "state.json")))

    # A process table without a desktop codex publishes nothing.
    no_codex_fixture = write_fixture(workdir, table(proc_line(500, 1, "/usr/bin/python3")), "no-codex")
    rejected_dir = os.path.join(workdir, "rejected")
    result = run_hook(rejected_dir, no_codex_fixture, {
        "hook_event_name": "UserPromptSubmit", "session_id": "s", "turn_id": "t",
    })
    check("non-desktop source publishes nothing",
          result.returncode == 0
          and not os.path.exists(os.path.join(rejected_dir, "state.json")))

    # Concurrency: several hooks racing on one snapshot keep every turn.
    concurrent_dir = os.path.join(workdir, "concurrent")
    results = []

    def worker(index):
        result = run_hook(concurrent_dir, fixture, {
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session-%d" % index,
            "turn_id": "turn-%d" % index,
        }, now=2000.0 + index)
        results.append(result.returncode)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(6)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    check("concurrent hooks all exit 0", results == [0] * 6, repr(results))
    with open(os.path.join(concurrent_dir, "state.json"), encoding="utf-8") as handle:
        concurrent_state = json.load(handle)
    check("fcntl lock keeps every concurrent turn",
          len(concurrent_state["turns"]) == 6, str(len(concurrent_state["turns"])))

    # The shipped hooks template renders to valid JSON, hooks exactly the
    # documented events, uses absolute /usr/bin/python3, and caps every timeout
    # at 3s. It is rendered with the real generator for a home directory that
    # contains both a space and an apostrophe, which is the hard portability case.
    renderer = load_renderer()
    receiver = os.path.join(
        "/tmp/coffee work's home", "Library", "Application Support",
        "Codex Work Mode", "activity-hook.py")
    command = renderer.render_command(receiver)
    check("rendered receiver command quotes a spaced apostrophe path",
          shlex.split(command) == [PY, receiver], repr(command))
    template = renderer.substitute(
        renderer.load_template(HOOKS_TEMPLATE), command)
    renderer.validate(template, command)
    events = set(template.get("hooks", {}))
    expected = {"UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                "Stop", "Interrupt", "SessionEnd"}
    check("hooks template documents exactly the seven events", events == expected, repr(events))
    timeouts = []
    handler_ok = True
    for groups in template["hooks"].values():
        for group in groups:
            for handler in group.get("hooks", []):
                timeouts.append(handler.get("timeout"))
                handler_ok = handler_ok and handler.get("type") == "command"
                handler_ok = handler_ok and handler.get("command") == command
                handler_ok = handler_ok and "async" not in handler
    check("hooks template handlers are synchronous commands via /usr/bin/python3", handler_ok)
    check("hooks template timeouts are at most 3s",
          bool(timeouts) and all(t is not None and t <= 3 for t in timeouts), repr(timeouts))


def main():
    mod = load_module()
    workdir = tempfile.mkdtemp(prefix="codex-activity-tests-")
    try:
        ancestry_checks(mod)
        reducer_checks(mod)
        receiver_checks(mod, workdir)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print("\n%d checks, %d failure(s)" % (checks, failures))
    if failures:
        print("FAILED: activity hook receiver")
        return 1
    print("PASS: activity hook receiver")
    return 0


if __name__ == "__main__":
    sys.exit(main())
