// QA-only boundary checks for the production CustomHours parser.
// This file is concatenated after the production source (with the trailing
// NSApplication bootstrap removed), so it exercises the real MenuBar.swift code.

var failures = 0

func check(_ raw: String, _ expected: Int?) {
    let got = CustomHours.parse(raw)
    let ok = got == expected
    if !ok { failures += 1 }
    let shown = raw.isEmpty ? "<empty>" : raw
    let gotText = got.map(String.init) ?? "nil"
    let wantText = expected.map(String.init) ?? "nil"
    print("\(ok ? "PASS" : "FAIL") parse(\"\(shown)\") -> \(gotText) (expected \(wantText))")
}

// In range, whole hours.
check("1", 1)
check("8", 8)
check("24", 24)
check(" 12 ", 12)

// Below, above, and non-whole / non-numeric / signed / empty.
check("0", nil)
check("25", nil)
check("-1", nil)
check("+5", nil)
check("1.5", nil)
check("1e2", nil)
check("abc", nil)
check("", nil)
check("   ", nil)
check("86400", nil) // 86400 is the helper's seconds bound, not an hour count.

// Contract constants.
print("range = \(CustomHours.minimum)...\(CustomHours.maximum), default = \(CustomHours.default)")
if CustomHours.minimum != 1 { failures += 1; print("FAIL minimum != 1") }
if CustomHours.maximum != 24 { failures += 1; print("FAIL maximum != 24") }
if CustomHours.default != 8 { failures += 1; print("FAIL default != 8") }
if CustomHours.maximum * 3600 != 86400 { failures += 1; print("FAIL upper bound is not the helper's 86400s") }

if failures > 0 {
    print("FAILED: \(failures) CustomHours check(s)")
    exit(1)
}
print("PASS: all CustomHours boundary checks")
exit(0)
