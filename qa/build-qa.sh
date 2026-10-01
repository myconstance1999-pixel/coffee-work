#!/bin/bash
# Codex Work Mode QA — isolated acceptance-harness build (v1.5).
#
# Builds a SEPARATE "Codex Work Mode QA.app" from the exact current production
# MenuBar.swift. Only isolation/test seams change: the injected `folder`
# assignment, the two power/session adapter initializers (replaced by QA fixture
# implementations defined in qa-anchor.swift), and the QA-only window anchor.
# The helper used by the QA app, qa/state/toggle.zsh, is regenerated from the
# production toggle.zsh with the single `state_dir=` line substituted. The QA
# app's activity snapshots live under the same isolated root
# (`<QA_ROOT>/state/codex-activity`), and its preferences use the separate QA
# bundle id.
#
# QA_ROOT (default: this qa/ directory) is configurable so the controller can
# build and run the harness from a temporary location whose path is not blocked
# by macOS (Documents launch was blocked in v1.3). All generated artifacts then
# live under QA_ROOT and the live helper/state is still never referenced.
#
# The generated QA app points ONLY at QA_ROOT/state. The live helper/state under
# ~/Library/Application Support/Codex Work Mode is never referenced by the
# generated source, the generated helper, or the compiled binary; the gates
# below enforce that. The production source is asserted to contain none of the
# QA-only fixture types. Writes only under QA_ROOT. Never launches the app,
# never runs the helper, and never touches the real session, dist/, or installed
# files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd)"
QA_ROOT="${QA_ROOT:-$SCRIPT_DIR}"
/bin/mkdir -p "$QA_ROOT"
QA_ROOT="$(cd "$QA_ROOT" && /bin/pwd)"

APP="$QA_ROOT/dist/Codex Work Mode QA.app"
BIN="$APP/Contents/MacOS/CodexWorkModeQA"
SRC="$QA_ROOT/MenuBar.isolated.swift"
LEGACY_SRC="$QA_ROOT/MenuBar.qa.swift"
ANCHOR="$SCRIPT_DIR/qa-anchor.swift"
DIFF="$QA_ROOT/production-vs-qa.diff"
PROD="$SCRIPT_DIR/../MenuBar.swift"
PROD_HELPER="$SCRIPT_DIR/../toggle.zsh"
QA_STATE_DIR="$QA_ROOT/state"
QA_HELPER="$QA_STATE_DIR/toggle.zsh"
LIVE_FOLDER_LITERAL='Library/Application Support/Codex Work Mode'
ICON="$SCRIPT_DIR/../bundle/AppIcon.icns"
TARGET="arm64-apple-macosx13.0"
MINIMUM_SYSTEM_VERSION="13.0"
VERSION="1.5"

echo "== QA root: $QA_ROOT =="

# The production source must never expose the QA-only test controls.
if /usr/bin/grep -qE 'QAPowerSourceMonitor|QASessionSampler|qa-power|qa-session' "$PROD"; then
    echo "production MenuBar.swift contains QA-only test controls" >&2
    exit 1
fi
echo "production source carries no QA test controls"

echo "== regenerating isolated QA helper from production toggle.zsh =="
/bin/mkdir -p "$QA_STATE_DIR"
/usr/bin/awk -v dir="$QA_STATE_DIR" '
    /^state_dir=/ { print "state_dir=\"" dir "\""; next }
    { print }
' "$PROD_HELPER" > "$QA_HELPER"
/bin/chmod 700 "$QA_HELPER"

# Gate: exactly one state_dir line, and the helper differs from production only there.
[ "$(/usr/bin/grep -c '^state_dir=' "$PROD_HELPER")" = 1 ]
[ "$(/usr/bin/grep -c '^state_dir=' "$QA_HELPER")" = 1 ]
/usr/bin/diff \
    <(/usr/bin/sed -E 's|^state_dir=.*$|state_dir=REPLACED|' "$PROD_HELPER") \
    <(/usr/bin/sed -E 's|^state_dir=.*$|state_dir=REPLACED|' "$QA_HELPER")
/usr/bin/grep -q "^state_dir=\"$QA_STATE_DIR\"$" "$QA_HELPER"
if /usr/bin/grep -q "$LIVE_FOLDER_LITERAL" "$QA_HELPER"; then
    echo "QA helper still references the live state directory" >&2
    exit 1
fi
/bin/zsh -n "$QA_HELPER"
echo "isolated helper: $QA_HELPER"

# QA-only deterministic power/session fixtures. Defaults are external power and
# an active session; the controller can overwrite either file and the QA-only
# adapter will re-evaluate the shared gate within half a second. Production has
# no such files or controls.
if [ ! -f "$QA_STATE_DIR/qa-power" ]; then
    printf 'external\n' > "$QA_STATE_DIR/qa-power"
fi
if [ ! -f "$QA_STATE_DIR/qa-session" ]; then
    printf 'active\n' > "$QA_STATE_DIR/qa-session"
fi
echo "QA fixtures: $QA_STATE_DIR/qa-power, $QA_STATE_DIR/qa-session"

echo "== regenerating $SRC from production source + QA adapter injection + QA anchor =="
/usr/bin/awk -v dir="$QA_STATE_DIR" '
    /^app\.run\(\)$/ { next }
    /var folder = FileManager\.default\.homeDirectoryForCurrentUser/ {
        print "    var folder = URL(fileURLWithPath: \"" dir "\")"
        skip = 1
        next
    }
    skip == 1 { skip = 0; next }
    { print }
' "$PROD" > "$SRC"

# QA-only adapter injection. The shared eligibility gate, menu, timers, and
# helper path are untouched: only the two concrete adapters are replaced with
# the fixture implementations the QA anchor defines. The production binary never
# contains these types (gated above and below).
/usr/bin/sed -i '' \
    -e 's/= PowerSourceMonitor()/= QAPowerSourceMonitor()/' \
    -e 's/= SessionSampler()/= QASessionSampler()/' \
    "$SRC"
/usr/bin/sed -e "s|__QA_STATE_DIR__|$QA_STATE_DIR|g" "$ANCHOR" >> "$SRC"
printf 'app.run()\n' >> "$SRC"

# Gate: the generated source binds the QA state root and never the live folder.
[ "$(/usr/bin/grep -c 'var folder = ' "$SRC")" = 1 ]
/usr/bin/grep -q "var folder = URL(fileURLWithPath: \"$QA_STATE_DIR\")" "$SRC"
if /usr/bin/grep -q "appendingPathComponent(\"$LIVE_FOLDER_LITERAL\")" "$SRC"; then
    echo "QA source still binds the live helper directory" >&2
    exit 1
fi
# Gate: the fixture adapters are injected and the production adapters are gone.
/usr/bin/grep -q '= QAPowerSourceMonitor()' "$SRC"
/usr/bin/grep -q '= QASessionSampler()' "$SRC"
/usr/bin/grep -q "let qaStateRoot = URL(fileURLWithPath: \"$QA_STATE_DIR\")" "$SRC"
if /usr/bin/grep -q '= PowerSourceMonitor()' "$SRC"; then
    echo "QA source still constructs the production power adapter" >&2
    exit 1
fi
if /usr/bin/grep -q '= SessionSampler()' "$SRC"; then
    echo "QA source still constructs the production session adapter" >&2
    exit 1
fi
echo "isolated source: $SRC"

echo "== refreshing $DIFF (production vs generated QA source) =="
/usr/bin/diff -u "$PROD" "$SRC" > "$DIFF" || true

# The pre-isolation generated variant pointed at the live helper. Drop it so no
# stale artifact can be built or launched by mistake.
if [ -f "$LEGACY_SRC" ]; then
    /bin/rm -f "$LEGACY_SRC"
    echo "removed stale non-isolated $LEGACY_SRC"
fi

echo "== cleaning qa build outputs =="
rm -rf "$QA_ROOT/dist" "$QA_ROOT/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "== compiling QA app (-target $TARGET) =="
/usr/bin/swiftc -O -target "$TARGET" -framework AppKit -framework CoreGraphics -framework IOKit "$SRC" -o "$BIN"

echo "== copying icon from staged production bundle (read-only source) =="
if [ -f "$ICON" ]; then
    /bin/cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="AppIcon"
else
    echo "note: production icon missing; building without an icon" >&2
    ICON_KEY=""
fi

echo "== writing QA Info.plist =="
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Codex Work Mode QA</string>
	<key>CFBundleExecutable</key>
	<string>CodexWorkModeQA</string>
	<key>CFBundleIconFile</key>
	<string>${ICON_KEY}</string>
	<key>CFBundleIdentifier</key>
	<string>local.plan.codex-work-mode.qa20260924</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Codex Work Mode QA</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MINIMUM_SYSTEM_VERSION}</string>
	<key>LSUIElement</key>
	<false/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "== signing (ad-hoc, no identity, no timestamp, no network) =="
/usr/bin/codesign --force --sign - --timestamp=none "$APP"

echo "== validating =="
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/bin/test -x "$BIN"
/bin/test -f "$APP/Contents/PkgInfo"
if [ -n "$ICON_KEY" ]; then /bin/test -f "$APP/Contents/Resources/AppIcon.icns"; fi

# Gate: the compiled binary must not embed the live helper directory.
if /usr/bin/strings "$BIN" | /usr/bin/grep -q "$LIVE_FOLDER_LITERAL"; then
    echo "QA binary references the live helper directory" >&2
    exit 1
fi
# Gate: the compiled binary carries the QA-only fixture controls.
if ! /usr/bin/strings "$BIN" | /usr/bin/grep -q 'qa-power'; then
    echo "QA binary is missing the QA-only fixture controls" >&2
    exit 1
fi
if ! /usr/bin/strings "$BIN" | /usr/bin/grep -q 'qa-session'; then
    echo "QA binary is missing the QA-only session fixture control" >&2
    exit 1
fi

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

echo "== built: $APP (bundle id local.plan.codex-work-mode.qa20260924, version $VERSION) =="
echo "== QA state is isolated at $QA_STATE_DIR; live helper/state untouched =="
echo "== QA activity snapshots: $QA_STATE_DIR/codex-activity =="
