#!/usr/bin/env python3
"""Render a user-portable Codex hooks template for the Coffee Work receiver.

The receiver command embeds an absolute path that contains a space
("Application Support"), so the path must be quoted for the shell that Codex
uses to run a command hook. This generator renders the command for a supplied
home directory (or an explicit receiver path) and validates the result before
writing it.

Safety rules, by design:

* It never merges with, edits, or overwrites a live hooks file. The output is
  created exclusively (``O_EXCL``), so an existing file, a symlink, or a file
  that appears between the check and the write is refused rather than
  clobbered. Any output path that resolves inside a ``.codex`` directory is
  refused outright, so ``~/.codex/hooks.json`` can never be written here, even
  when a symlinked parent hides the ``.codex`` component.
* The rendered command is passed through ``json.loads`` / ``json.dumps`` so the
  emitted file is always valid JSON.
* Paths are escaped for a POSIX single-quoted shell word, which keeps spaces and
  apostrophes intact and neutralizes ``$``, backticks, backslashes, and double
  quotes.

Use ``--output FILE`` to write to a new file, or omit it to print to stdout.
Installing the rendered template is a separate, manual step: preserve your
existing hooks and add or enable the seven Coffee handlers through your
supported Codex hooks interface.
"""

import argparse
import json
import os
import sys

PLACEHOLDER = "COFFEE_WORK_RECEIVER_COMMAND"
DEFAULT_TIMEOUT = 3
SUPPORT_FOLDER = os.path.join("Library", "Application Support", "Codex Work Mode")
RECEIVER_NAME = "activity-hook.py"
PYTHON = "/usr/bin/python3"


def quote_command_path(path):
    """Return `path` as one safely single-quoted POSIX shell word.

    Single quotes suppress every expansion, so only an apostrophe needs the
    standard ``'\\''`` escape. This keeps paths with spaces and apostrophes
    intact and neutralizes ``$``, backticks, backslashes, and double quotes.
    """
    if not path:
        raise ValueError("receiver path must not be empty")
    if any(character in path for character in ("\n", "\r", "\0")):
        raise ValueError("receiver path must not contain control characters")
    return "'" + path.replace("'", "'\\''") + "'"


def render_command(receiver):
    return PYTHON + " " + quote_command_path(receiver)


def load_template(path):
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
    if not isinstance(document, dict):
        raise ValueError("template is not a JSON object")
    return document


def substitute(document, command):
    """Replace every placeholder string value with the rendered command."""
    replaced = 0

    def walk(node):
        nonlocal replaced
        if isinstance(node, dict):
            return {key: walk(value) for key, value in node.items()}
        if isinstance(node, list):
            return [walk(item) for item in node]
        if node == PLACEHOLDER:
            replaced += 1
            return command
        return node

    result = walk(document)
    if replaced == 0:
        raise ValueError("template contains no %s placeholder" % PLACEHOLDER)
    return result


def validate(document, command):
    hooks = document.get("hooks")
    if not isinstance(hooks, dict) or not hooks:
        raise ValueError("rendered document has no hooks object")
    expected = {
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "Stop",
        "Interrupt",
        "SessionEnd",
    }
    if set(hooks) != expected:
        raise ValueError("unexpected hook event set: %r" % sorted(hooks))
    for event, entries in hooks.items():
        if not isinstance(entries, list) or not entries:
            raise ValueError("event %s has no matcher entries" % event)
        for entry in entries:
            for hook in entry.get("hooks", []):
                if hook.get("type") != "command":
                    raise ValueError("event %s has a non-command hook" % event)
                if hook.get("command") != command:
                    raise ValueError("event %s does not carry the rendered command" % event)
                if hook.get("timeout") != DEFAULT_TIMEOUT:
                    raise ValueError("event %s has an unexpected timeout" % event)


def refuse_unsafe_output(path):
    """Refuse a live hooks file or any output inside a ``.codex`` directory.

    The ``.codex`` check runs against the resolved real location, so a symlinked
    parent cannot smuggle the write into ``~/.codex`` under another spelling.
    The original absolute path is returned so the exclusive ``O_EXCL`` create in
    ``main`` still refuses an existing file or symlink at the exact name the
    caller asked for.
    """
    absolute = os.path.abspath(path)
    resolved = os.path.realpath(absolute)
    if ".codex" in resolved.split(os.sep):
        raise ValueError(
            "refusing to write inside a .codex directory (%s); render to stdout "
            "or a staging file and merge manually" % resolved
        )
    return absolute


def build_parser():
    parser = argparse.ArgumentParser(
        description="Render the Codex hooks template for the Coffee Work receiver."
    )
    parser.add_argument(
        "--home",
        default=os.environ.get("HOME", os.path.expanduser("~")),
        help="home directory used to locate the receiver (default: $HOME)",
    )
    parser.add_argument(
        "--receiver",
        default=None,
        help="explicit receiver path; overrides --home",
    )
    parser.add_argument(
        "--template",
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "hooks.template.json"),
        help="hooks template JSON with the %s placeholder" % PLACEHOLDER,
    )
    parser.add_argument(
        "--output",
        default=None,
        help="create this new file instead of printing to stdout (never overwrites)",
    )
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    home = os.path.abspath(os.path.expanduser(args.home))
    receiver = args.receiver or os.path.join(home, SUPPORT_FOLDER, RECEIVER_NAME)
    receiver = os.path.normpath(os.path.abspath(os.path.expanduser(receiver)))

    command = render_command(receiver)
    document = substitute(load_template(args.template), command)
    validate(document, command)
    rendered = json.dumps(document, indent=2) + "\n"

    if args.output is None:
        sys.stdout.write(rendered)
        return 0

    destination = refuse_unsafe_output(args.output)
    # Exclusive creation closes the check-then-open race: if anything appears at
    # this path after the refusal check, the create fails instead of truncating
    # it, and an existing symlink at the name is refused rather than followed.
    try:
        with open(destination, "x", encoding="utf-8") as handle:
            handle.write(rendered)
    except FileExistsError:
        raise ValueError(
            "refusing to overwrite an existing file (%s); choose a new path"
            % destination
        )
    sys.stderr.write("rendered hooks template: %s\n" % destination)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        sys.stderr.write("error: %s\n" % error)
        sys.exit(1)
