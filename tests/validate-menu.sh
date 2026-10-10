#!/bin/zsh
# Constructs native menu objects and renders files only. No visible windows,
# status bar, installed app, accessibility actions, or power assertions.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$PWD/build/menu-validation"
mkdir -p "$out"
/usr/bin/sed '/^let app = NSApplication.shared$/,$d' MenuBar.swift > "$out/MenuUI.swift"
/bin/cat tests/menu-ui-main.swift >> "$out/MenuUI.swift"
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -module-cache-path "$PWD/build/compile-cache" \
    -framework AppKit -framework CoreGraphics -framework IOKit "$out/MenuUI.swift" -o "$out/MenuUI"
"$out/MenuUI" "$out/preview" | tee "$out/MenuUI.log"
