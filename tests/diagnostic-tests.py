"""Isolated metadata privacy, reason, rotation and failure tests."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("hook", root / "activity-hook.py")
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)
with tempfile.TemporaryDirectory(prefix="coffee-diagnostic-test-") as temporary:
    directory = Path(temporary)
    fixture = directory / "processes.txt"
    fixture.write_text("100 1 Fri Oct 2 23:22:23 2026 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT\n"
                       "101 100 Fri Oct 2 23:22:26 2026 /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex\n"
                       "102 101 Fri Oct 2 23:22:27 2026 /usr/bin/python3\n")
    state = directory / "state"
    arguments = ["/usr/bin/python3", str(root / "activity-hook.py"), "--state-dir", str(state),
                 "--process-table", str(fixture), "--ancestry-start-pid", "102"]
    payload = {"hook_event_name": "UserPromptSubmit", "session_id": "session-private",
               "turn_id": "turn-private", "prompt": "PRIVATE_SENTINEL", "credential": "PRIVATE_SENTINEL",
               "tool_output": "PRIVATE_SENTINEL", "image_path": "/PRIVATE_SENTINEL.jpg"}
    result = subprocess.run(arguments, input=json.dumps(payload), text=True, capture_output=True)
    assert result.returncode == 0 and result.stdout == ""
    path = state / "diagnostics/hook.jsonl"
    text = path.read_text()
    row = json.loads(text)
    assert "PRIVATE_SENTINEL" not in text and "session-private" not in text and "turn-private" not in text
    assert row["session_hash"] == hook._hash("session-private") and row["turn_hash"] == hook._hash("turn-private")
    assert row["owner_basis"] == "bundled_codex_under_desktop" and row["working_count"] == 1
    print("PASS accepted task basis and hashed identity; payload content excluded")
    rejected = subprocess.run(arguments[:-1] + ["999"], input=json.dumps(payload), text=True, capture_output=True)
    assert rejected.returncode == 0
    assert json.loads(path.read_text().splitlines()[-1])["reason"] == "desktop_ancestry_not_verified"
    print("PASS rejected ancestry has a diagnostic reason without changing state")
    assert len(json.loads((state / "state.json").read_text())["turns"]) == 1
    bad = directory / "file-instead-of-state"
    bad.touch()
    broken = arguments.copy()
    broken[broken.index("--state-dir") + 1] = str(bad)
    result = subprocess.run(broken, input=json.dumps(payload), text=True, capture_output=True)
    assert result.returncode == 0 and result.stdout == ""
    print("PASS diagnostic/state I/O failures do not break task execution")
    assert hook.LOG_MAX_BYTES == 256 * 1024 and hook.LOG_ARCHIVES == 3
    hook.LOG_MAX_BYTES = 512
    rotation = directory / "rotation"
    for _ in range(100):
        hook.diagnostic(str(rotation), "Stop", "private-session", "private-turn", reason="fixture")
    logs = sorted((rotation / "diagnostics").glob("hook.jsonl*"))
    assert len(logs) == 4
    for file in logs:
        assert file.stat().st_size <= hook.LOG_MAX_BYTES and file.stat().st_mode & 0o777 == 0o600
        for line in file.read_text().splitlines():
            json.loads(line)
    print("PASS bounded four-file rotation, complete JSON lines and owner-only permissions")
