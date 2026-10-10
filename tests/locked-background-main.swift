// Drives production snapshot reading, session/power transitions, and owned
// child cleanup against private fixtures. No installed state, UI, system
// settings, screen-saver, input, sleep or display assertions are touched.
let testRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("WorkMode-locked-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: testRoot.appendingPathComponent("codex-activity"),
                                       withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: testRoot) }
var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL") \(name)")
    if !condition { failures += 1 }
}
func pump(_ seconds: Double = 0.12) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}
final class FixtureSession: SessionProviding {
    var state: SessionState = .active
    func sample() -> SessionState { state }
}
final class FixturePower: PowerSourceProviding {
    var availability: PowerAvailability = .external
    var onChange: (() -> Void)?
    func start() {}
    func sample() {}
    func stop() {}
}
let ownerPID = ProcessInfo.processInfo.processIdentifier
guard let signature = WorkModeApp.processStartSignature(pid: ownerPID) else {
    print("BLOCKED: the real fixture owner signature is unavailable; use the authorized host test run")
    exit(78)
}
let childTool = testRoot.appendingPathComponent("owned-child.zsh")
try Data("#!/bin/zsh\nexec /bin/sleep 60\n".utf8).write(to: childTool)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: childTool.path)
let app = WorkModeApp()
app.folder = testRoot
let session = FixtureSession()
let power = FixturePower()
app.sessionProvider = session
app.powerMonitor = power
app.sessionState = .active
app.sessionSnapshot = .active
app.powerAvailability = .external
app.autoEnabled = true
app.autoAssertionExecutable = childTool.path
var helperCalls: [String] = []
app.helperInvocationOverride = { mode, _, _ in
    helperCalls.append(mode)
    return (0, "OFF — normal sleep settings apply.\n")
}
app.guiTimer.makeProcess = { _ in
    let child = Process()
    child.executableURL = childTool
    return child
}
defer {
    app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    app.autoOwnerSource?.cancel()
    pump()
}
func writeSnapshot(_ state: String?, age: Double = 10, owner: String? = nil) throws {
    let now = Date().timeIntervalSince1970
    var turns: [[String: Any]] = []
    if let state {
        turns = [["session": "fixture", "turn": "fixture", "state": state,
                  "opened": now - age, "refreshed": now - 1]]
    }
    let snapshot: [String: Any] = ["version": 1,
        "owner": ["pid": ownerPID, "start": owner ?? signature], "turns": turns]
    try JSONSerialization.data(withJSONObject: snapshot).write(to: app.activityStateFile)
}
func refresh() { app.refreshActivity(); pump() }
func freshStart() { app.releaseAutoAwake(reason: "fixture_reset"); app.autoStartedAt = 0 }

try writeSnapshot("working")
refresh()
let first = app.autoProcess
check("valid unlocked task obtains an owned background child", first?.isRunning == true && app.autoHeld)
check("background child requests only a bounded idle hold and owner lifetime",
      first?.arguments == ["-i", "-t", "300", "-w", String(ownerPID)])
_ = app.guiTimer.start(seconds: 60, eligible: true)
let displayChild = app.guiTimer.process
app.handleSessionChange(.screenLocked)
pump()
check("lock keeps the same AC background child for valid work",
      app.sessionState == .locked && app.autoProcess === first && app.autoHeld)
check("lock releases GUI child while preserving its original deadline",
      displayChild?.isRunning == false && !app.guiTimer.held && app.guiTimer.configured)
check("locked holding status reports background protection without display hold",
      app.automaticMenuLine == "自动保持：锁屏后台工作中 · 不保持显示"
      && app.autoDetailLine == "Auto: holding — locked, verified work, AC")
app.handleSessionChange(.screenUnlocked)
pump()
check("unlock retains background child without resetting its lease", app.autoProcess === first)
app.guiTimer.stop(reason: "fixture_cleanup")
app.handleSessionChange(.screenLocked)
try writeSnapshot(nil)
refresh()
check("task completion while locked releases immediately without grace",
      first?.isRunning == false && !app.autoHeld && app.autoEngine.graceUntil == nil)
for state in ["waiting", "nonsense"] {
    freshStart()
    try writeSnapshot(state)
    refresh()
    check("locked \(state) state cannot acquire background protection", !app.autoHeld)
}
freshStart()
try FileManager.default.removeItem(at: app.activityStateFile)
refresh()
check("missing hooks never count as valid locked work", !app.autoHeld && app.activityStatus == .connectionNotSeen)
try Data("{bad-json".utf8).write(to: app.activityStateFile)
refresh()
check("malformed state never counts as valid locked work", !app.autoHeld && app.activityStatus == .unavailable)
try writeSnapshot("working", owner: "different-process-start")
refresh()
check("owner signature mismatch rejects otherwise working locked state", !app.autoHeld && app.activityStatus == .unavailable)
try writeSnapshot("working", age: ActivitySnapshotParser.maximumTurnAge + 1)
refresh()
check("expired task cannot acquire locked protection", !app.autoHeld && app.activityStatus == .idle)

freshStart()
try writeSnapshot("working")
refresh()
let batteryChild = app.autoProcess
power.availability = .battery
app.handlePowerChange()
pump()
check("unplugging releases locked background protection immediately",
      batteryChild?.isRunning == false && !app.autoHeld && app.autoEngine.graceUntil == nil)
refresh()
check("valid work cannot restart locked protection on battery", !app.autoHeld)
power.availability = .unknown
app.handlePowerChange()
pump()
check("unknown power is ineligible while locked", !app.autoHeld)
power.availability = .external
app.autoStartedAt = 0
app.handlePowerChange()
pump()
check("verified task can regain protection after AC returns", app.autoHeld)
let sleepChild = app.autoProcess
app.handleSessionChange(.willSleep)
pump()
check("actual sleep wins over the locked working allowance",
      app.sessionState == .sleeping && sleepChild?.isRunning == false && !app.autoHeld)
app.autoStartedAt = 0
app.handleSessionChange(.didWake)
pump()
check("wake still records locked identity and revalidates current work and AC",
      app.sessionState == .locked && app.autoHeld)
let inactiveChild = app.autoProcess
app.handleSessionChange(.resignedActive)
pump()
check("inactive user session wins over locked work",
      app.sessionState == .inactive && inactiveChild?.isRunning == false && !app.autoHeld)
app.autoStartedAt = 0
app.handleSessionChange(.becameActive)
pump()
check("returning to the same locked console rechecks protection eligibility", app.autoHeld)
let unknownChild = app.autoProcess
session.state = .unknown
app.handlePowerChange()
pump()
check("lock latch cannot conceal an unknown or non-console snapshot",
      app.sessionState == .unknown && unknownChild?.isRunning == false && !app.autoHeld)
session.state = .active
app.autoStartedAt = 0
app.handlePowerChange()
pump()
check("a trusted console snapshot retains the lock latch", app.sessionState == .locked && app.autoHeld)

let expiringChild = app.autoProcess
try writeSnapshot("working", age: ActivitySnapshotParser.maximumTurnAge + 1)
refresh()
check("task age expiry releases an existing locked child without grace",
      expiringChild?.isRunning == false && !app.autoHeld && app.renewTimer == nil)
freshStart()
try writeSnapshot("working")
refresh()
let unexpected = app.autoProcess
unexpected?.terminate()
pump(0.4)
check("unexpected lease exit clears effective holding", !app.autoHeld && app.autoProcess == nil)
refresh()
check("unexpected exit does not cause a tight renewal loop", !app.autoHeld)
freshStart()
refresh()
let cancelled = app.autoProcess
app.releaseAutoAwake(reason: "fixture_cancel")
pump()
check("cancellation releases child and both scheduled timers",
      cancelled?.isRunning == false && !app.autoHeld && app.renewTimer == nil && app.graceTimer == nil)
app.autoEnabled = false
refresh()
check("disabled automatic mode cannot acquire locked protection", !app.autoHeld)
app.autoEnabled = true
freshStart()
refresh()
let quitChild = app.autoProcess
app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
pump()
check("quit releases owned protection and invokes manual cleanup",
      quitChild?.isRunning == false && !app.autoHeld && app.renewTimer == nil
      && app.graceTimer == nil && helperCalls.last == "off")

// Unlocked grace survives as before; entering lock with no work cannot inherit it.
app.handleSessionChange(.screenUnlocked)
freshStart()
try writeSnapshot("working")
refresh()
try writeSnapshot(nil)
refresh()
check("unlocked task completion retains the original bounded grace", app.autoHeld && app.autoEngine.graceUntil != nil)
app.handleSessionChange(.screenLocked)
pump()
check("locking during unlocked grace clears it immediately", !app.autoHeld && app.autoEngine.graceUntil == nil)
check("manual and GUI starts remain ineligible while locked", !AwakeGate.sessionAllowsAssertion(.locked))
print("\(failures) locked-background failure(s)")
exit(failures == 0 ? 0 : 1)
