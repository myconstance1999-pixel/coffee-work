#!/bin/bash
# Codex Work Mode — portable staged build.
#
# Builds "dist/Codex Work Mode.app" from this source tree alone: the checked-in
# bundle metadata and icon under bundle/, a fresh compile of MenuBar.swift, and
# an ad-hoc local signature. It then stages the hook receiver, the manual helper
# and a hooks template rendered for THIS user's home next to the bundle for the
# manual install step.
#
# The script never installs, launches, registers, or trusts anything, never
# writes under the user's live Codex or Application Support directories, and
# never touches the network. Ad-hoc signing is a local integrity signature, not
# Developer ID notarization.
#
# Idempotent: dist/ and build/ are removed first.

set -euo pipefail
cd "$(dirname "$0")"

APP="dist/Codex Work Mode.app"
BIN="$APP/Contents/MacOS/CodexWorkMode"
TARGET="arm64-apple-macosx13.0"
MINIMUM_SYSTEM_VERSION="13.0"
VERSION="1.5"
PYTHON="/usr/bin/python3"

echo "== cleaning dist/ build/ =="
rm -rf dist build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

echo "== staging public bundle metadata and icon =="
/bin/cp bundle/Info.plist "$APP/Contents/Info.plist"
/bin/cp bundle/PkgInfo "$APP/Contents/PkgInfo"
/bin/cp bundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "== compiling MenuBar.swift (-target $TARGET) =="
/usr/bin/swiftc -O -target "$TARGET" \
    -framework AppKit -framework CoreGraphics -framework IOKit \
    MenuBar.swift -o "$BIN"

echo "== stamping version $VERSION =="
/usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"

echo "== signing (ad-hoc, no identity, no timestamp, no network) =="
/usr/bin/codesign --force --sign - --timestamp=none "$APP"

echo "== validating the bundle =="
/bin/test -x "$BIN"
/bin/test -f "$APP/Contents/PkgInfo"
/bin/test -f "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = "local.plan.codex-work-mode" ]
[ "$(/usr/bin/plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")" = "CodexWorkMode" ]
minos=$(/usr/bin/vtool -show-build "$BIN" | awk '/minos/{print $2; exit}')
[ "$minos" = "$MINIMUM_SYSTEM_VERSION" ] || {
    echo "binary minos ${minos} != LSMinimumSystemVersion ${MINIMUM_SYSTEM_VERSION}" >&2
    exit 1
}
signed_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
[ "$signed_version" = "$VERSION" ] || {
    echo "bundle version ${signed_version} != ${VERSION}" >&2
    exit 1
}
/usr/bin/codesign --verify --strict --verbose=2 "$APP"

echo "== staging the hook receiver, helper and rendered hooks template =="
/bin/cp activity-hook.py dist/activity-hook.py
/bin/cp toggle.zsh dist/toggle.zsh
/bin/chmod 700 dist/activity-hook.py
/bin/chmod 700 dist/toggle.zsh
"$PYTHON" -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' activity-hook.py
/bin/zsh -n toggle.zsh
"$PYTHON" hooks/render-hooks.py --home "$HOME" --output dist/hooks.codex.json

# The staged receiver and helper must be byte-identical to the reviewed source.
cmp -s activity-hook.py dist/activity-hook.py || {
    echo "staged activity-hook.py differs from source" >&2
    exit 1
}
cmp -s toggle.zsh dist/toggle.zsh || {
    echo "staged toggle.zsh differs from source" >&2
    exit 1
}
# The rendered template must parse and must point at this user's staged receiver
# location, so a later manual install can copy it without editing paths by hand.
"$PYTHON" - "$HOME" dist/hooks.codex.json <<'PY'
import importlib.util, json, os, sys
home, path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "render_hooks", os.path.join("hooks", "render-hooks.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
receiver = os.path.join(home, "Library", "Application Support",
                        "Codex Work Mode", "activity-hook.py")
expected_command = module.render_command(receiver)
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
hooks = document.get("hooks")
assert isinstance(hooks, dict) and hooks, "hooks object missing"
expected = {"UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
            "Stop", "Interrupt", "SessionEnd"}
assert set(hooks) == expected, "unexpected hook event set: %r" % sorted(hooks)
for event, entries in hooks.items():
    for entry in entries:
        for hook in entry["hooks"]:
            assert hook["type"] == "command", "non-command hook in %s" % event
            assert hook["command"] == expected_command, \
                "rendered command mismatch in %s" % event
            assert hook["timeout"] == 3, "unexpected timeout in %s" % event
PY

printf 'staged hook receiver:   dist/activity-hook.py\n'
printf 'staged manual helper:   dist/toggle.zsh\n'
printf 'staged hooks template:  dist/hooks.codex.json (rendered for this user home)\n'
echo "== staged: $APP (bundle id local.plan.codex-work-mode, version $VERSION) =="
echo "== nothing was installed, launched, trusted, or registered =="
