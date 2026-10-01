#!/usr/bin/env python3
"""Focused deterministic tests for hooks/render-hooks.py.

Covers the safety properties the portable renderer promises:

* shell quoting of a receiver path with spaces, an apostrophe, and shell
  metacharacters, checked with ``shlex`` and with a real ``/bin/sh`` round trip;
* rejection of empty and control-character paths;
* a normal new output file (valid JSON, seven events, the rendered command);
* an existing output file is refused and left byte-for-byte unchanged;
* a ``.codex`` output is refused, including through a symlinked parent and a
  symlinked output path, so the resolved destination is what is checked;
* exclusive creation (``O_EXCL``) refuses a dangling output symlink instead of
  following it and creating the target.

Everything runs in private temporary directories. No real home directory, no
``~/.codex`` config, and no global filesystem scan is used.
"""

import importlib.util
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RENDER_HOOKS = os.path.join(ROOT, "hooks", "render-hooks.py")
TEMPLATE = os.path.join(ROOT, "hooks", "hooks.template.json")
PYTHON = "/usr/bin/python3"
EVENTS = {
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "Stop",
    "Interrupt",
    "SessionEnd",
}

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


def load_renderer():
    spec = importlib.util.spec_from_file_location(
        "render_hooks_under_test", RENDER_HOOKS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_cli(*args):
    return subprocess.run(
        [PYTHON, RENDER_HOOKS, "--template", TEMPLATE] + list(args),
        capture_output=True,
        text=True,
    )


def quoting_checks(renderer):
    spaced = "/Users/Some One/Library/Application Support/Codex Work Mode/activity-hook.py"
    apostrophe = "/tmp/it's-here/Codex Work Mode/activity-hook.py"
    metacharacters = (
        '/tmp/$HOME/`cmd`/a;b|c&d*e"f\\g(h)i/activity-hook.py'
    )
    for label, path in (
        ("spaces", spaced),
        ("apostrophe", apostrophe),
        ("shell metacharacters", metacharacters),
    ):
        quoted = renderer.quote_command_path(path)
        check("quote %s: shlex splits back to the exact path" % label,
              shlex.split(quoted) == [path], quoted)
        command = renderer.render_command(path)
        check("quote %s: render_command is python3 plus one shell word" % label,
              command == renderer.PYTHON + " " + quoted, command)
        check("quote %s: command splits to [python3, path]" % label,
              shlex.split(command) == [renderer.PYTHON, path], command)
        completed = subprocess.run(
            ["/bin/sh", "-c", "printf %s " + quoted],
            capture_output=True, text=True)
        check("quote %s: real /bin/sh prints the exact path" % label,
              completed.returncode == 0 and completed.stdout == path,
              "rc=%s out=%r err=%r" % (
                  completed.returncode, completed.stdout, completed.stderr))

    for label, bad in (
        ("empty", ""),
        ("newline", "/tmp/a\nb"),
        ("carriage return", "/tmp/a\rb"),
        ("nul", "/tmp/a\0b"),
    ):
        try:
            renderer.quote_command_path(bad)
        except ValueError:
            check("quote rejects %s" % label, True)
        else:
            check("quote rejects %s" % label, False, "no error raised")


def read_text(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def output_checks(workdir, renderer):
    receiver = os.path.join(workdir, "Codex Work Mode", "activity-hook.py")
    expected_command = renderer.render_command(
        os.path.normpath(os.path.abspath(receiver)))

    # A normal new output file.
    fresh = os.path.join(workdir, "fresh", "hooks.json")
    os.makedirs(os.path.dirname(fresh))
    completed = run_cli("--receiver", receiver, "--output", fresh)
    check("new output: exit 0", completed.returncode == 0, completed.stderr)
    check("new output: file exists", os.path.isfile(fresh))
    document = None
    try:
        document = json.loads(read_text(fresh))
    except (OSError, ValueError) as error:
        check("new output: valid JSON", False, repr(error))
    else:
        check("new output: valid JSON object", isinstance(document, dict))
    if isinstance(document, dict):
        hooks = document.get("hooks")
        check("new output: exactly the seven Coffee events",
              isinstance(hooks, dict) and set(hooks) == EVENTS,
              repr(sorted(hooks)) if isinstance(hooks, dict) else repr(hooks))
        commands_ok = True
        if isinstance(hooks, dict):
            for entries in hooks.values():
                for entry in entries:
                    for hook in entry.get("hooks", []):
                        commands_ok = commands_ok and hook.get("command") == expected_command
        check("new output: every handler carries the quoted receiver command",
              commands_ok)

    # An existing output file is refused and unchanged.
    existing = os.path.join(workdir, "existing.json")
    sentinel = '{"keep": "this byte for byte"}\n'
    with open(existing, "w", encoding="utf-8") as handle:
        handle.write(sentinel)
    completed = run_cli("--receiver", receiver, "--output", existing)
    check("existing output: exit non-zero", completed.returncode != 0,
          "rc=%s" % completed.returncode)
    check("existing output: refusal names overwrite",
          "refusing to overwrite" in completed.stderr, completed.stderr)
    check("existing output: unchanged", read_text(existing) == sentinel,
          repr(read_text(existing)))

    # A literal .codex output is refused and nothing is created.
    codex_dir = os.path.join(workdir, ".codex")
    os.makedirs(codex_dir)
    codex_output = os.path.join(codex_dir, "hooks.json")
    completed = run_cli("--receiver", receiver, "--output", codex_output)
    check("literal .codex: exit non-zero", completed.returncode != 0,
          "rc=%s" % completed.returncode)
    check("literal .codex: refusal names .codex",
          ".codex" in completed.stderr, completed.stderr)
    check("literal .codex: no file created", not os.path.exists(codex_output))

    # A symlinked parent that resolves inside .codex is refused: the literal
    # argument contains no ".codex" component.
    real_codex = os.path.join(workdir, "real-parent", ".codex")
    os.makedirs(real_codex)
    link_parent = os.path.join(workdir, "link-parent")
    os.symlink(real_codex, link_parent)
    hidden_output = os.path.join(link_parent, "hooks.json")
    completed = run_cli("--receiver", receiver, "--output", hidden_output)
    check("symlinked .codex parent: exit non-zero", completed.returncode != 0,
          "rc=%s" % completed.returncode)
    check("symlinked .codex parent: refusal names .codex",
          ".codex" in completed.stderr, completed.stderr)
    check("symlinked .codex parent: no file created",
          not os.path.exists(os.path.join(real_codex, "hooks.json")))

    # A symlinked output path whose target sits inside .codex is refused even
    # though the target does not exist yet.
    dangling_codex = os.path.join(workdir, "dangling-codex.json")
    os.symlink(os.path.join(codex_dir, "hooks.json"), dangling_codex)
    completed = run_cli("--receiver", receiver, "--output", dangling_codex)
    check("symlinked .codex output: exit non-zero", completed.returncode != 0,
          "rc=%s" % completed.returncode)
    check("symlinked .codex output: refusal names .codex",
          ".codex" in completed.stderr, completed.stderr)

    # Exclusive creation refuses a dangling symlink instead of following it, so
    # the link target is never created by a plain "w" open. This is the
    # check-then-open race the renderer must not lose.
    race_target = os.path.join(workdir, "race-target.json")
    race_link = os.path.join(workdir, "race-output.json")
    os.symlink(race_target, race_link)
    completed = run_cli("--receiver", receiver, "--output", race_link)
    check("dangling symlink: exit non-zero", completed.returncode != 0,
          "rc=%s" % completed.returncode)
    check("dangling symlink: refusal names overwrite",
          "refusing to overwrite" in completed.stderr, completed.stderr)
    check("dangling symlink: target was never created",
          not os.path.exists(race_target))

    # Omitting --output still prints to stdout and creates nothing.
    completed = run_cli("--receiver", receiver)
    check("stdout mode: exit 0", completed.returncode == 0, completed.stderr)
    try:
        streamed = json.loads(completed.stdout)
    except ValueError as error:
        check("stdout mode: valid JSON", False, repr(error))
    else:
        check("stdout mode: valid JSON object", isinstance(streamed, dict))


def main():
    renderer = load_renderer()
    workdir = tempfile.mkdtemp(prefix="render-hooks-tests-")
    try:
        quoting_checks(renderer)
        output_checks(workdir, renderer)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print("\n%d checks, %d failure(s)" % (checks, failures))
    if failures:
        print("FAILED: render hooks generator")
        return 1
    print("PASS: render hooks generator")
    return 0


if __name__ == "__main__":
    sys.exit(main())
