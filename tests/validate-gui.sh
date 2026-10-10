#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
out="$PWD/build/gui-validation"
mkdir -p "$out"
/usr/bin/sed '/^let app = NSApplication.shared$/,$d' MenuBar.swift > "$out/GUIWork.swift"
/bin/cat tests/gui-work-main.swift >> "$out/GUIWork.swift"
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -module-cache-path "$out/module-cache" \
    -framework AppKit -framework CoreGraphics -framework IOKit "$out/GUIWork.swift" -o "$out/GUIWork"
"$out/GUIWork" "$@" | tee "$out/GUIWork.log"
