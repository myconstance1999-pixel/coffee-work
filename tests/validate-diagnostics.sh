#!/bin/zsh
# Compile production code and run only isolated tests; no installed app/UI.
set -eu
cd "$(dirname "$0")/.."
out="$PWD/build/diagnostics-validation"
mkdir -p "$out"
/usr/bin/python3 tests/activity-hook-tests.py > "$out/activity-hook.log"
/usr/bin/python3 tests/diagnostic-tests.py > "$out/hook-diagnostics.log"
for pair in AutoAwake:auto-awake Diagnostic:diagnostic; do
    name=${pair%%:*}
    test_name=${pair#*:}
    /usr/bin/sed '/^let app = NSApplication.shared$/,$d' MenuBar.swift > "$out/${name}.swift"
    /bin/cat "tests/${test_name}-main.swift" >> "$out/${name}.swift"
    /usr/bin/swiftc -O -target arm64-apple-macosx13.0 -module-cache-path "$out/module-cache" \
        -framework AppKit -framework CoreGraphics -framework IOKit "$out/${name}.swift" -o "$out/${name}"
    "$out/${name}" > "$out/${name}.log"
done
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -module-cache-path "$out/module-cache" \
    -framework AppKit -framework CoreGraphics -framework IOKit MenuBar.swift -o "$out/CodexWorkMode"
print 'PASS: receiver, privacy/rotation/export, existing awake behavior, and app compilation'
