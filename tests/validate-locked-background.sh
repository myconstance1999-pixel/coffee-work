#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
out="$PWD/build/locked-background-validation"
mkdir -p "$out"
/usr/bin/sed '/^let app = NSApplication.shared$/,$d' MenuBar.swift > "$out/LockedBackground.swift"
/bin/cat tests/locked-background-main.swift >> "$out/LockedBackground.swift"
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -module-cache-path "$PWD/build/compile-cache" \
    -framework AppKit -framework CoreGraphics -framework IOKit "$out/LockedBackground.swift" -o "$out/LockedBackground"
"$out/LockedBackground" | tee "$out/LockedBackground.log"
