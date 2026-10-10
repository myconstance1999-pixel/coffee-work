// Exercises the real reader with isolated corrupt/owner-invalid snapshot files.
// No hooks, installed files, native menus or power assertions are used.
let availabilityRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("WorkMode-availability-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: availabilityRoot.appendingPathComponent("codex-activity"),
                                       withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: availabilityRoot) }
let availabilityApp = WorkModeApp()
availabilityApp.folder = availabilityRoot
var availabilityFailures = 0
func availabilityCheck(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL") \(name)")
    if !condition { availabilityFailures += 1 }
}
let availabilityNow = Date().timeIntervalSince1970
availabilityCheck("missing snapshot is not a verified idle observation",
                  availabilityApp.readActivitySnapshot(now: availabilityNow).status != .idle)
for (name, json) in [("malformed", "{not-json"),
                     ("owner invalid", "{\"version\":1,\"owner\":{\"pid\":0,\"start\":\"invalid\"},\"turns\":[]}")] {
    try Data(json.utf8).write(to: availabilityApp.activityStateFile)
    let observation = availabilityApp.readActivitySnapshot(now: availabilityNow)
    print("observed \(name): \(observation.status)")
    availabilityCheck("\(name) snapshot is not reported idle", observation.status != .idle)
    availabilityCheck("\(name) snapshot never counts as working", !observation.isWorking)
    availabilityCheck("\(name) snapshot does not retain an owner watch", observation.ownerPID == nil)
    availabilityApp.activityStatus = observation.status
    availabilityCheck("\(name) task label does not claim no activity",
                      !availabilityApp.localTaskMenuLine.contains("暂无活动"))
    availabilityApp.sessionState = .active
    availabilityApp.powerAvailability = .external
    availabilityApp.autoEnabled = true
    availabilityCheck("\(name) automatic label does not claim verified idle",
                      !availabilityApp.automaticMenuLine.contains("等待已连接的任务"))
    availabilityCheck("\(name) diagnostic reason does not claim idle",
                      !availabilityApp.autoDetailLine.contains("local hooks idle"))
    availabilityApp.statusReadable = true
    let availabilityMenu = NSMenu()
    availabilityMenu.autoenablesItems = false
    availabilityApp.populateMenu(availabilityMenu)
    let availabilityDetails = availabilityMenu.items.first { $0.title == "更多状态与日志" }?.submenu
    availabilityCheck("\(name) native details menu states uncertainty",
                      availabilityDetails?.items.contains { $0.title == "已连接任务：状态暂无法确认" } == true)
    availabilityCheck("\(name) native details menu preserves Work/dot limitation",
                      availabilityDetails?.items.contains { $0.title == "Work/圆点任务：暂不能自动识别" } == true)
}
let availabilityLog = availabilityRoot.appendingPathComponent("diagnostics/app.jsonl")
let availabilityRecords = (try String(contentsOf: availabilityLog, encoding: .utf8))
    .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
availabilityCheck("malformed and invalid-owner reasons remain distinct",
                  availabilityRecords.contains { $0["reason"] as? String == "snapshot_unreadable_or_malformed" }
                  && availabilityRecords.contains { $0["reason"] as? String == "desktop_owner_not_valid" })
exit(availabilityFailures == 0 ? 0 : 1)
