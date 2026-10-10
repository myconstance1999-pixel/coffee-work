// Production timer checks with isolated logs and owned short-lived children.
let root = FileManager.default.temporaryDirectory.appendingPathComponent("coffee-gui-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
func pump(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}
// A child lifetime test uses the real production timer, never NSApplication.
if CommandLine.arguments.contains("--gui-owner") {
    guard SessionSampler().sample() == .active else { exit(78) }
    let timer = GUIWorkTimer(diagnostics: DiagnosticLog(directory: root))
    guard timer.start(seconds: 8, eligible: true), let child = timer.process else { exit(1) }
    FileHandle.standardOutput.write(Data("\(child.processIdentifier)\n".utf8))
    try FileHandle.standardOutput.close()
    pump(9)
    timer.stop(reason: "test_cleanup")
    exit(0)
}
var failures = 0
func check(_ name: String, _ value: Bool) {
    print("\(value ? "PASS" : "FAIL") \(name)")
    if !value { failures += 1 }
}
let timer = GUIWorkTimer(diagnostics: DiagnosticLog(directory: root))
defer { timer.stop(reason: "test_cleanup") }
var clock = 1000.0
timer.now = { clock }
var arguments: [[String]] = []
timer.makeProcess = { args in
    arguments.append(args)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["60"]
    return child
}
check("invalid bounds and locked starts create no child", !timer.start(seconds: 0, eligible: true)
      && !timer.start(seconds: 86401, eligible: true) && !timer.start(seconds: 120, eligible: false)
      && arguments.isEmpty && !timer.configured)
check("eligible request holds and records a fixed deadline", timer.start(seconds: 120, eligible: true)
      && timer.held && timer.deadline == 1120)
check("duplicate request cannot extend the deadline", !timer.start(seconds: 3600, eligible: true)
      && timer.deadline == 1120 && arguments.count == 1)
let first = timer.process!
check("bounded child has display/idle assertions and owner lifetime", arguments[0] ==
      ["-d", "-i", "-t", "120", "-w", String(ProcessInfo.processInfo.processIdentifier)])
clock = 1040
timer.reconcile(eligible: false)
pump(0.1)
check("session pause releases child and preserves deadline", !first.isRunning && !timer.held
      && timer.configured && timer.deadline == 1120)
clock = 1100
timer.reconcile(eligible: true)
check("resume uses only the remaining time", timer.held && timer.deadline == 1120
      && arguments.last?[3] == "20")
let resumed = timer.process!
clock = 1120
timer.reconcile(eligible: true)
pump(0.1)
check("deadline releases child and clears request", !resumed.isRunning && !timer.configured && !timer.held)
clock = 2000
_ = timer.start(seconds: 120, eligible: true)
timer.reconcile(eligible: false)
clock = 2121
timer.reconcile(eligible: false)
timer.reconcile(eligible: true)
check("expired paused timer cannot revive", !timer.configured && !timer.held && arguments.count == 3)
clock = 3000
_ = timer.start(seconds: 120, eligible: true)
let cancelled = timer.process!
timer.stop(reason: "user_cancelled")
timer.stop(reason: "user_cancelled")
pump(0.1)
check("cancel is immediate and idempotent", !cancelled.isRunning && !timer.configured && !timer.held)
timer.makeProcess = { _ in
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/nonexistent-coffee-test")
    return child
}
check("spawn failure clears request rather than claiming held", !timer.start(seconds: 120, eligible: true)
      && !timer.configured && !timer.held)
check("a failed initial until-stopped spawn clears the request instead of arming a later hold",
      !timer.startUntilStopped(eligible: true) && !timer.configured && !timer.untilStopped
      && !timer.held && !timer.awaitingLeaseRetry)
timer.reconcile(eligible: true)
check("a failed initial until-stopped spawn leaves no pending retry to fire later",
      !timer.configured && !timer.held && !timer.awaitingLeaseRetry)
timer.makeProcess = { _ in
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/false")
    return child
}
_ = timer.start(seconds: 120, eligible: true)
pump(0.2)
timer.reconcile(eligible: true)
check("unexpected child exit ends request without retry", !timer.configured && !timer.held)

// v1.8: extended finite bounds, the until-stopped request, and independence
// between the explicit display request, the background timer and power state.
final class GUIFixtureSession: SessionProviding {
    var state: SessionState = .active
    func sample() -> SessionState { state }
}
func sleepChild() -> Process {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["60"]
    return child
}
let owner = String(ProcessInfo.processInfo.processIdentifier)

let extended = GUIWorkTimer(diagnostics: DiagnosticLog(directory: root))
defer { extended.stop(reason: "test_cleanup") }
var extendedClock = 5000.0
extended.now = { extendedClock }
var extendedArguments: [[String]] = []
extended.makeProcess = { args in
    extendedArguments.append(args)
    return sleepChild()
}
check("a 24 hour display request is accepted within the shared bound",
      extended.start(seconds: 86400, eligible: true) && extended.configured && extended.held
      && extended.deadline == 5000 + 86400)
check("a 24 hour request still uses one bounded owner-tied display child",
      extendedArguments.first == ["-d", "-i", "-t", "86400", "-w", owner])
extended.stop(reason: "test_cleanup")
check("a display request beyond 24 hours is rejected",
      !extended.start(seconds: 86401, eligible: true) && !extended.configured && extendedArguments.count == 1)

let forever = GUIWorkTimer(diagnostics: DiagnosticLog(directory: root))
defer { forever.stop(reason: "test_cleanup") }
var foreverClock = 10000.0
forever.now = { foreverClock }
var foreverArguments: [[String]] = []
forever.makeProcess = { args in
    foreverArguments.append(args)
    return sleepChild()
}
check("until-stopped starts one bounded owner-tied display lease",
      forever.startUntilStopped(eligible: true) && forever.untilStopped && forever.held
      && foreverArguments == [["-d", "-i", "-t", "300", "-w", owner]])
let firstLease = forever.process!
check("a duplicate until-stopped request starts no second child",
      !forever.startUntilStopped(eligible: true) && foreverArguments.count == 1 && forever.held)
forever.reconcile(eligible: false)
pump(0.1)
check("until-stopped pauses without losing the request",
      !firstLease.isRunning && !forever.held && forever.configured && forever.untilStopped)
forever.reconcile(eligible: true)
check("until-stopped resumes with a fresh bounded lease",
      forever.held && foreverArguments.count == 2 && foreverArguments.last?[3] == "300")
let resumedLease = forever.process!
foreverClock += 240
forever.reconcile(eligible: true)
pump(0.1)
check("until-stopped renews before the 300 second lease bound expires",
      forever.held && foreverArguments.count == 3 && !resumedLease.isRunning
      && foreverArguments.last?[3] == "300")
let liveLease = forever.process!
resumedLease.terminate()
pump(0.2)
forever.reconcile(eligible: true)
check("a stale exit from a replaced lease cannot stop or duplicate the live lease",
      forever.held && forever.process === liveLease && foreverArguments.count == 3)
liveLease.terminate()
pump(0.3)
forever.reconcile(eligible: true)
check("an unexpected lease exit keeps the request without a duplicate child",
      forever.configured && forever.untilStopped && !forever.held && foreverArguments.count == 3)
foreverClock += 240
forever.reconcile(eligible: true)
check("one bounded retry re-arms a single lease after the exit",
      forever.held && foreverArguments.count == 4)
let rearmed = forever.process!
forever.stop(reason: "user_cancelled")
pump(0.1)
check("until-stopped cancellation releases the child and clears the state",
      !forever.configured && !forever.held && !forever.untilStopped && !rearmed.isRunning)
forever.reconcile(eligible: true)
check("a cancelled until-stopped request never revives",
      !forever.configured && !forever.held && foreverArguments.count == 4)

// Defect regression: a lease that ends on its own must be published through the
// onChange callback with the state that actually holds, and the bounded retry
// must be scheduled against the injected clock rather than unrelated wall time.
let reported = GUIWorkTimer(diagnostics: DiagnosticLog(directory: root))
defer { reported.stop(reason: "test_cleanup") }
var reportedClock = 12000.0
reported.now = { reportedClock }
var exitChangeCount = 0
var lastReportedHeld: Bool?
var lastReportedRetry = false
reported.onChange = {
    exitChangeCount += 1
    lastReportedHeld = reported.held
    lastReportedRetry = reported.awaitingLeaseRetry
    _ = reported.configured
}
reported.makeProcess = { _ in
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["0.15"]
    return child
}
check("a fixture until-stopped request reports its running lease", reported.startUntilStopped(eligible: true)
      && reported.held && exitChangeCount == 1 && lastReportedHeld == true)
pump(0.6)
check("an unexpected lease exit republishes the unheld state through the callback",
      !reported.held && lastReportedHeld == false && exitChangeCount >= 2)
check("the bounded retry is scheduled on the injected clock, not wall time",
      reported.configured && reported.untilStopped && reported.awaitingLeaseRetry
      && lastReportedRetry && !reported.held)
let changesAfterExit = exitChangeCount
reportedClock = 12240
reported.reconcile(eligible: true)
check("the one bounded retry re-arms a lease once the injected renewal instant arrives",
      reported.held && !reported.awaitingLeaseRetry && exitChangeCount == changesAfterExit + 1
      && lastReportedHeld == true)
reported.stop(reason: "user_cancelled")
pump(0.1)

// A late callback from an already-dead lease must never mutate the newer
// request or publish a false unheld state on top of the live lease. The live
// lease uses a long-lived child so the stale notification is the only event.
reportedClock = 30000
reported.makeProcess = { _ in sleepChild() }
_ = reported.startUntilStopped(eligible: true)
let replacedLease = reported.process!
let changesBeforeStale = exitChangeCount
reportedClock = 30240
reported.reconcile(eligible: true)
check("a renewal replaces the lease exactly once",
      reported.held && reported.process !== replacedLease && exitChangeCount == changesBeforeStale + 1
      && lastReportedHeld == true)
replacedLease.terminate()
pump(0.3)
check("a stale callback from a replaced lease cannot mutate the live request",
      reported.process !== replacedLease && reported.held && exitChangeCount == changesBeforeStale + 1)
reported.stop(reason: "test_cleanup")
pump(0.1)

let coexist = WorkModeApp()
coexist.folder = root
coexist.sessionProvider = GUIFixtureSession()
coexist.sessionState = .active
coexist.powerAvailability = .battery
coexist.powerStatus = PowerStatus(source: .battery, energyMode: .lowPower)
coexist.statusReadable = true
coexist.manualState = .active(expiry: "fixture")
coexist.manualExpiryDeadline = 20000
coexist.guiTimer.now = { 20000 }
coexist.guiTimer.makeProcess = { _ in sleepChild() }
var helperCalls: [String] = []
coexist.helperInvocationOverride = { mode, _, _ in
    helperCalls.append(mode)
    return (0, "OFF — fixture\n")
}
coexist.startDisplayHold(seconds: 1800)
check("display hold starts on battery and in Low Power Mode beside a background timer",
      coexist.guiTimer.configured && coexist.guiTimer.held
      && coexist.manualState.isActive && coexist.manualExpiryDeadline == 20000 && helperCalls.isEmpty)
let coexistChild = coexist.guiTimer.process
coexist.stopGUIWork()
pump(0.1)
check("stopping the display hold leaves the background timer untouched",
      !coexist.guiTimer.configured && !(coexistChild?.isRunning ?? false)
      && coexist.manualState.isActive && coexist.manualExpiryDeadline == 20000 && helperCalls.isEmpty)

let reverse = WorkModeApp()
reverse.folder = root
reverse.sessionProvider = GUIFixtureSession()
reverse.sessionState = .active
reverse.statusReadable = true
reverse.guiTimer.now = { 21000 }
reverse.guiTimer.makeProcess = { _ in sleepChild() }
_ = reverse.guiTimer.start(seconds: 1800, eligible: true)
let reverseDeadline = reverse.guiTimer.deadline
let reverseChild = reverse.guiTimer.process
reverse.helperInvocationOverride = { _, _, _ in
    (0, "ON — fixture\nAutomatic stop: 2026-01-01 00:00:00\nExpires: 9999999999\n")
}
let preset = NSMenuItem()
preset.tag = 3600
reverse.startFromMenu(preset)
pump(0.3)
check("starting the background timer is no longer blocked by a display request",
      reverse.statusReadable && reverse.manualState.isActive)
check("starting the background timer leaves the display deadline and child alone",
      reverse.guiTimer.configured && reverse.guiTimer.deadline == reverseDeadline
      && reverse.guiTimer.process === reverseChild)
reverse.guiTimer.stop(reason: "test_cleanup")
reverse.manualExpiryTimer?.cancel()

let app = WorkModeApp()
app.folder = root
app.activityStatus = .idle
check("idle status states local scope", app.activityLine == "Local hooks: idle")
app.guiTimer.now = { 4000 }
app.guiTimer.makeProcess = { _ in
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["60"]
    return child
}
_ = app.guiTimer.start(seconds: 120, eligible: true)
check("overall display status names the hold and deadline", app.overallStatusLine.contains("Screen display until ")
      && app.overallStatusLine.contains("display on"))
app.guiTimer.reconcile(eligible: false)
check("paused display status retains the deadline", app.overallStatusLine.contains("Screen display paused — ends at "))
app.guiTimer.stop(reason: "test_cleanup")
let session = SessionSampler().sample()
print("REAL_SESSION \(session)")
if session == .active && !CommandLine.arguments.contains("--fixtures-only") {
    let real = GUIWorkTimer(diagnostics: DiagnosticLog(directory: root))
    let started = real.start(seconds: 2, eligible: true)
    let child = real.process
    pump(2.5)
    check("real caffeinate expires without a long GUI session", started && !real.configured
          && child?.isRunning == false)
    real.stop(reason: "test_cleanup")
    let owner = Process()
    let pipe = Pipe()
    owner.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    owner.arguments = ["--gui-owner"]
    owner.standardOutput = pipe
    try owner.run()
    let response = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let orphan = Int32(response.trimmingCharacters(in: .whitespacesAndNewlines))
    if owner.isRunning { owner.terminate() }
    owner.waitUntilExit()
    pump(0.5)
    check("real assertion exits when its owner dies", orphan != nil && kill(orphan!, 0) != 0)
} else {
    print("SKIP real display assertions: fixtures-only or no unlocked active desktop")
}
print("\(failures) GUI failure(s)")
exit(failures == 0 ? 0 : 1)
