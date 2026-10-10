// Isolated production logger checks. No app launch, menu, helper, or home state.
let root = FileManager.default.temporaryDirectory.appendingPathComponent("coffee-diagnostics-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
var failures = 0
func check(_ name: String, _ value: Bool) {
    print("\(value ? "PASS" : "FAIL") \(name)")
    if !value { failures += 1 }
}
let directory = root.appendingPathComponent("diagnostics")
let log = DiagnosticLog(directory: directory)
let path = directory.appendingPathComponent("app.jsonl")
log.record("display_off", fields: ["reason": "notification", "prompt": "PRIVATE_SENTINEL", "tool_output": "PRIVATE_SENTINEL"])
log.record("session_event", fields: ["reason": "screenLocked"])
log.record("session_event", fields: ["reason": "willSleep"])
var contents = try String(contentsOf: path, encoding: .utf8)
check("prompt and tool output are excluded", !contents.contains("PRIVATE_SENTINEL"))
check("display, lock, and sleep retain distinct evidence", contents.contains("display_off") && contents.contains("screenLocked") && contents.contains("willSleep"))
log.observation("awake_decision", fields: ["held": "false", "reason": "battery"])
log.observation("awake_decision", fields: ["held": "false", "reason": "battery"])
log.observation("awake_decision", fields: ["held": "true", "reason": "working"])
contents = try String(contentsOf: path, encoding: .utf8)
check("state observations preserve transitions and suppress duplicates", contents.components(separatedBy: "awake_decision").count - 1 == 2)
for _ in 0..<9000 { log.record("rotation_fixture", fields: ["reason": String(repeating: "x", count: 120)]) }
let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
check("rotation retains at most four files", names.sorted() == ["app.jsonl", "app.jsonl.1", "app.jsonl.2", "app.jsonl.3"])
for name in names {
    let file = directory.appendingPathComponent(name)
    let data = try Data(contentsOf: file)
    check("bounded complete JSON lines: \(name)", data.count <= DiagnosticLog.maximumBytes && data.split(separator: 10).allSatisfy { (try? JSONSerialization.jsonObject(with: $0)) != nil })
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    check("owner-only log permissions: \(name)", (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}
let hook = root.appendingPathComponent("hook")
try FileManager.default.createDirectory(at: hook, withIntermediateDirectories: true)
try "{\"event\":\"UserPromptSubmit\"}\n".write(to: hook.appendingPathComponent("hook.jsonl"), atomically: true, encoding: .utf8)
let privateFile = hook.appendingPathComponent("credentials.txt")
try "PRIVATE_SENTINEL".write(to: privateFile, atomically: true, encoding: .utf8)
try FileManager.default.createSymbolicLink(at: hook.appendingPathComponent("hook.jsonl.1"), withDestinationURL: privateFile)
try Data(repeating: 88, count: DiagnosticLog.maximumBytes + 1).write(to: hook.appendingPathComponent("hook.jsonl.2"))
let archive = root.appendingPathComponent("export.zip")
try log.export(to: archive, hookDirectory: hook)
let unzip = Process()
let pipe = Pipe()
unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
unzip.arguments = ["-Z1", archive.path]
unzip.standardOutput = pipe
try unzip.run()
let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
unzip.waitUntilExit()
check("export includes both log producers", listing.contains("app.jsonl") && listing.contains("hook.jsonl"))
check("export excludes arbitrary, symlink, and oversized files", !listing.contains("credentials") && !listing.contains("hook.jsonl.1") && !listing.contains("hook.jsonl.2"))
let bad = root.appendingPathComponent("not-a-directory")
try Data().write(to: bad)
DiagnosticLog(directory: bad.appendingPathComponent("blocked")).record("failure_fixture")
check("failed logging does not change the awake gate", AwakeGate.autoEligible(enabled: true, power: .external, session: .active, working: false) && !AwakeGate.autoEligible(enabled: true, power: .external, session: .locked, working: false))
print("\(failures) diagnostic failure(s)")
exit(failures == 0 ? 0 : 1)
