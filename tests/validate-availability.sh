#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
out="$PWD/build/availability-validation"
mkdir -p "$out"
/usr/bin/sed '/^let app = NSApplication.shared$/,$d' MenuBar.swift > "$out/Availability.swift"
/bin/cat tests/activity-availability-main.swift >> "$out/Availability.swift"
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -module-cache-path "$out/module-cache" \
    -framework AppKit -framework CoreGraphics -framework IOKit "$out/Availability.swift" -o "$out/Availability"
"$out/Availability" | tee "$out/Availability.log"
