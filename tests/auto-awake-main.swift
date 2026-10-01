// QA-only behavioral checks for the production v1.4 auto-awake engine and the
// activity snapshot parser.
//
// This file is concatenated after the production source (with the trailing
// NSApplication bootstrap removed), so it exercises the real MenuBar.swift
// types with a fake clock and fixture JSON. No `ps`, no Codex file, and no
// model call. Two sections deliberately use controlled, short-lived
// process/async behavior: the effective-assertion section starts and kills one
// real owned `caffeinate` (isolated and terminated before exit), and the
// reconciliation section drives the real async helper-command path through the
// production `helperInvocationOverride` seam with a deterministic delayed fake
// helper. Nothing here touches the installed helper, the live state file, or
// the production app.

var autoFailures = 0

func autoCheck(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("PASS \(name)")
    } else {
        autoFailures += 1
        print("FAIL \(name)\(detail.isEmpty ? "" : " :: \(detail)")")
    }
}

func snapshot(_ json: String, now: Double) -> ActivitySnapshot? {
    ActivitySnapshotParser.parse(data: Data(json.utf8), now: now)
}

func workingJSON(opened: Double, refreshed: Double) -> String {
    """
    {"version":1,"updated":\(refreshed),"last_event":"PreToolUse",
     "owner":{"pid":14864,"start":"Thu Sep 25 10:00:00 2026","main_pid":14831,
              "main_start":"Thu Sep 25 09:59:00 2026","app":"/Applications/ChatGPT.app"},
     "turns":[{"session":"s1","turn":"t1","state":"working","opened":\(opened),"refreshed":\(refreshed)}]}
    """
}

// MARK: - Snapshot parsing

let now: Double = 10_000

autoCheck("working snapshot parses", snapshot(workingJSON(opened: now - 100, refreshed: now - 5), now: now)?.status == .working)
autoCheck("owner pid and signature parse",
          snapshot(workingJSON(opened: now - 100, refreshed: now - 5), now: now)?.ownerPID == 14864
          && snapshot(workingJSON(opened: now - 100, refreshed: now - 5), now: now)?.ownerSignature == "Thu Sep 25 10:00:00 2026")
autoCheck("working snapshot isWorking", snapshot(workingJSON(opened: now - 100, refreshed: now - 5), now: now)?.isWorking == true)

let waitingJSON = """
{"version":1,"owner":{"pid":1,"start":"x"},"turns":[{"session":"a","turn":"b","state":"waiting","opened":\(now - 10),"refreshed":\(now - 1)}]}
"""
autoCheck("waiting-only snapshot is waiting", snapshot(waitingJSON, now: now)?.status == .waiting)
autoCheck("waiting is not working", snapshot(waitingJSON, now: now)?.isWorking == false)

let emptyJSON = """
{"version":1,"owner":{"pid":1,"start":"x"},"turns":[]}
"""
autoCheck("empty turns is idle", snapshot(emptyJSON, now: now)?.status == .idle)

let mixedJSON = """
{"version":1,"owner":{"pid":1,"start":"x"},"turns":[
 {"session":"a","turn":"b","state":"waiting","opened":\(now - 10),"refreshed":\(now - 1)},
 {"session":"c","turn":"d","state":"working","opened":\(now - 20),"refreshed":\(now - 2)}]}
"""
autoCheck("multiple turns aggregate to working", snapshot(mixedJSON, now: now)?.status == .working)

autoCheck("turn older than 24h is discarded",
          snapshot(workingJSON(opened: now - 86_401, refreshed: now - 1), now: now)?.status == .idle)
autoCheck("turn just under 24h survives sparse events",
          snapshot(workingJSON(opened: now - 86_399, refreshed: now - 86_000), now: now)?.status == .working)
autoCheck("implausible future turn is ignored",
          snapshot(workingJSON(opened: now + 120, refreshed: now + 120), now: now)?.status == .idle)

autoCheck("malformed JSON is rejected", snapshot("{not json", now: now) == nil)

let badStateJSON = """
{"version":1,"owner":{"pid":1,"start":"x"},"turns":[{"session":"a","turn":"b","state":"nonsense","opened":\(now)}]}
"""
autoCheck("unknown turn state is not counted", snapshot(badStateJSON, now: now)?.status == .idle)

// MARK: - Auto awake engine (fake clock)

var engine = AutoAwakeEngine()
autoCheck("engine starts idle", engine.asserting == false && engine.graceUntil == nil)
autoCheck("work asserts immediately", engine.step(working: true, eligible: true, now: 0) == true)
autoCheck("work clears any grace", engine.graceUntil == nil)

autoCheck("stopping keeps asserting and starts 120s grace",
          engine.step(working: false, eligible: true, now: 10) == true && engine.graceUntil == 130)
autoCheck("grace still asserting just before deadline",
          engine.step(working: false, eligible: true, now: 129.9) == true)
autoCheck("grace releases at the deadline",
          engine.step(working: false, eligible: true, now: 130) == false && engine.asserting == false
          && engine.graceUntil == nil)

// New work cancels grace.
_ = engine.step(working: true, eligible: true, now: 200)
_ = engine.step(working: false, eligible: true, now: 210)
autoCheck("grace pending", engine.graceUntil == 330)
autoCheck("new work cancels grace",
          engine.step(working: true, eligible: true, now: 250) == true && engine.graceUntil == nil)

// A waiting-only period behaves like a stop (no working turn) and is covered by
// the same grace, then resume re-asserts.
_ = engine.step(working: false, eligible: true, now: 260)
autoCheck("waiting-only period starts grace", engine.graceUntil == 380)
autoCheck("resume from waiting cancels grace", engine.step(working: true, eligible: true, now: 300) == true)

// Disable releases; re-enable re-asserts with current work.
engine.enabled = false
autoCheck("disabled engine never asserts", engine.step(working: true, eligible: true, now: 400) == false
          && engine.asserting == false && engine.graceUntil == nil)
engine.enabled = true
autoCheck("re-enabled engine asserts again", engine.step(working: true, eligible: true, now: 410) == true)

// Quit/reset releases the automatic assertion.
engine.reset()
autoCheck("reset (quit) releases automatic assertion",
          engine.asserting == false && engine.graceUntil == nil)

// MARK: - Manual/automatic independence and the cup

autoCheck("cup filled by manual only", CupState.filled(manual: true, automatic: false))
autoCheck("cup filled by automatic only", CupState.filled(manual: false, automatic: true))
autoCheck("cup filled by both", CupState.filled(manual: true, automatic: true))
autoCheck("cup empty when neither", CupState.filled(manual: false, automatic: false) == false)

var manualEngine = AutoAwakeEngine()
_ = manualEngine.step(working: false, eligible: true, now: 0)
autoCheck("auto engine ignores manual state and stays idle",
          manualEngine.asserting == false && manualEngine.graceUntil == nil)
autoCheck("manual awake still fills the cup while auto is idle",
          CupState.filled(manual: true, automatic: manualEngine.asserting))

// MARK: - Overall menu status label

autoCheck("menu status is normal sleep when neither source is on",
          WorkModeApp.menuStatus(manualActive: false, manualPaused: false, manualLine: "Normal sleep", automatic: false)
          == "Normal sleep")
autoCheck("menu status names the automatic assertion when only it is on",
          WorkModeApp.menuStatus(manualActive: false, manualPaused: false, manualLine: "Normal sleep", automatic: true)
          == "Automatic awake")
autoCheck("menu status keeps the manual line with its end time when manual is on",
          WorkModeApp.menuStatus(manualActive: true, manualPaused: false, manualLine: "Awake until 17:00", automatic: false)
          == "Awake until 17:00")
autoCheck("menu status keeps the manual line even while auto also asserts",
          WorkModeApp.menuStatus(manualActive: true, manualPaused: false, manualLine: "Awake until 17:00", automatic: true)
          == "Awake until 17:00")

// MARK: - Owner validity (dead / reused pid)

autoCheck("matching owner pid and start signature is valid",
          WorkModeApp.ownerMatches(storedPID: 14864, storedSignature: "Thu Sep 25 10:00:00 2026",
                                   currentSignature: "Thu Sep 25 10:00:00 2026"))
autoCheck("reused pid with a different start signature is invalid",
          WorkModeApp.ownerMatches(storedPID: 14864, storedSignature: "Thu Sep 25 10:00:00 2026",
                                   currentSignature: "Fri Sep 26 10:00:00 2026") == false)
autoCheck("dead owner (no current signature) is invalid",
          WorkModeApp.ownerMatches(storedPID: 14864, storedSignature: "Thu Sep 25 10:00:00 2026",
                                   currentSignature: nil) == false)
autoCheck("missing stored pid is invalid",
          WorkModeApp.ownerMatches(storedPID: nil, storedSignature: "Thu Sep 25 10:00:00 2026",
                                   currentSignature: "Thu Sep 25 10:00:00 2026") == false)
autoCheck("missing stored signature is invalid",
          WorkModeApp.ownerMatches(storedPID: 14864, storedSignature: "",
                                   currentSignature: "Thu Sep 25 10:00:00 2026") == false)

// MARK: - Start-signature normalization (the production path ownerIsValid uses)

// The hook receiver builds the stored owner "start" with Python's
// whitespace-collapsing `split()`/`join`, so this normalization must collapse
// the doubled space `ps` prints before a single-digit day of month.
autoCheck("single-digit-day start signature collapses internal whitespace",
          WorkModeApp.normalizeStartSignature("Fri Sep  5 10:11:12 2025")
          == "Fri Sep 5 10:11:12 2025")
autoCheck("start-signature normalization trims surrounding whitespace",
          WorkModeApp.normalizeStartSignature("  Thu Sep 25 10:00:00 2026\n")
          == "Thu Sep 25 10:00:00 2026")
autoCheck("blank start signature normalizes to nil",
          WorkModeApp.normalizeStartSignature("  \n\t ") == nil)
autoCheck("normalized single-digit day matches the stored signature",
          WorkModeApp.ownerMatches(
              storedPID: 14864,
              storedSignature: "Fri Sep 5 10:11:12 2025",
              currentSignature: WorkModeApp.normalizeStartSignature("Fri Sep  5 10:11:12 2025")))
autoCheck("uncollapsed doubled-space signature would wrongly invalidate the owner",
          WorkModeApp.ownerMatches(
              storedPID: 14864,
              storedSignature: "Fri Sep 5 10:11:12 2025",
              currentSignature: "Fri Sep  5 10:11:12 2025") == false)

// MARK: - Activity directory watch (event-driven, burst-safe)
//
// The receiver publishes each snapshot atomically (write a hidden temp file,
// then `rename` it over `state.json`), so a rapid burst produces several
// directory writes within milliseconds. These checks exercise the real
// `ActivityDirectoryWatch` on a temporary directory and a dedicated queue: no
// app, no run loop, no Codex file and no caffeinate process is involved.

func watchTestRoot(_ name: String) -> String {
    let path = NSTemporaryDirectory()
        + "codex-work-mode-watch-\(name)-\(ProcessInfo.processInfo.processIdentifier)"
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// Atomic publish, exactly like the receiver: temp file, then `rename` over it.
func publish(_ text: String, to root: String) {
    let temporary = root + "/.state.json.tmp"
    try? Data(text.utf8).write(to: URL(fileURLWithPath: temporary))
    _ = rename(temporary, root + "/state.json")
}

func readPublished(_ root: String) -> String {
    (try? String(contentsOfFile: root + "/state.json", encoding: .utf8)) ?? ""
}

// Registering the same path again must keep the live registration: while the
// descriptor is never removed, no event can fall between a read and a re-open.
do {
    let first = watchTestRoot("stable-a")
    let second = watchTestRoot("stable-b")
    var resolved = first
    let watch = ActivityDirectoryWatch(
        queue: DispatchQueue(label: "local.plan.codex-work-mode.watch-test.stable")
    )
    watch.start(resolvePath: { resolved }, read: {})
    watch.arm()
    watch.arm()
    autoCheck("re-arming an unchanged path keeps the live registration",
              watch.registrations == 1 && watch.watchedPath == first,
              "registrations=\(watch.registrations) path=\(watch.watchedPath ?? "nil")")
    resolved = second
    watch.arm()
    autoCheck("a changed target replaces the registration",
              watch.registrations == 2 && watch.watchedPath == second,
              "registrations=\(watch.registrations) path=\(watch.watchedPath ?? "nil")")
}

// A burst of atomic publishes, with a read that costs about as much as
// `refreshActivity` (its synchronous owner `ps` probe) — the exact window the
// old cancel-then-open re-arm fell into. The final snapshot must still be read.
do {
    let root = watchTestRoot("burst")
    let queue = DispatchQueue(label: "local.plan.codex-work-mode.watch-test.burst")
    let lock = NSLock()
    var observed: [String] = []
    let watch = ActivityDirectoryWatch(queue: queue)
    watch.start(resolvePath: { root }, read: {
        let text = readPublished(root)
        lock.lock()
        observed.append(text)
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.25)
    })
    publish("turn B working", to: root)
    publish("stop A", to: root)
    publish("stop B idle", to: root)

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        lock.lock()
        let last = observed.last
        lock.unlock()
        if last == "stop B idle" { break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    queue.sync {}
    lock.lock()
    let last = observed.last
    let count = observed.count
    lock.unlock()
    autoCheck("rapid atomic publishes are caught without polling",
              last == "stop B idle", "last=\(last ?? "nil") observations=\(count)")
    autoCheck("a burst never replaces the live registration",
              watch.registrations == 1, "registrations=\(watch.registrations)")
}

// The activity folder appearing is the one case that does replace the
// registration, and the read that follows must already be on the new target:
// the first snapshot published with the folder is never lost in the switch.
do {
    let fallback = watchTestRoot("appear")
    let preferred = fallback + "/codex-activity"
    let queue = DispatchQueue(label: "local.plan.codex-work-mode.watch-test.appear")
    let lock = NSLock()
    var observations: [(path: String, text: String)] = []
    let watch = ActivityDirectoryWatch(queue: queue)
    watch.start(
        resolvePath: { FileManager.default.fileExists(atPath: preferred) ? preferred : fallback },
        read: {
            let path = watch.watchedPath ?? "nil"
            let text = readPublished(preferred)
            lock.lock()
            observations.append((path, text))
            lock.unlock()
        }
    )
    try? FileManager.default.createDirectory(atPath: preferred, withIntermediateDirectories: true)
    publish("first snapshot", to: preferred)

    func caughtOnNewTarget() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return observations.contains { $0.text == "first snapshot" && $0.path == preferred }
    }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && !caughtOnNewTarget() {
        Thread.sleep(forTimeInterval: 0.02)
    }
    queue.sync {}
    autoCheck("the watch moves to the activity folder before reading it",
              caughtOnNewTarget(), "observed paths=\(observations.map { $0.path })")
}

// MARK: - Shared awake gate (power + session eligibility)

autoCheck("only an active session allows an assertion",
          AwakeGate.sessionAllowsAssertion(.active)
          && AwakeGate.sessionAllowsAssertion(.locked) == false
          && AwakeGate.sessionAllowsAssertion(.sleeping) == false
          && AwakeGate.sessionAllowsAssertion(.inactive) == false
          && AwakeGate.sessionAllowsAssertion(.unknown) == false)

autoCheck("auto eligible only with the toggle, external power, and an active session",
          AwakeGate.autoEligible(enabled: true, power: .external, session: .active))
autoCheck("auto ineligible on battery",
          AwakeGate.autoEligible(enabled: true, power: .battery, session: .active) == false)
autoCheck("auto ineligible on unknown power",
          AwakeGate.autoEligible(enabled: true, power: .unknown, session: .active) == false)
autoCheck("auto ineligible while locked",
          AwakeGate.autoEligible(enabled: true, power: .external, session: .locked) == false)
autoCheck("auto ineligible while asleep",
          AwakeGate.autoEligible(enabled: true, power: .external, session: .sleeping) == false)
autoCheck("auto ineligible while the session is inactive",
          AwakeGate.autoEligible(enabled: true, power: .external, session: .inactive) == false)
autoCheck("auto ineligible while the session is unknown",
          AwakeGate.autoEligible(enabled: true, power: .external, session: .unknown) == false)
autoCheck("auto ineligible while the toggle is off",
          AwakeGate.autoEligible(enabled: false, power: .external, session: .active) == false)
// Manual awake is an explicit user request: the same active session allows it
// while the very same power state keeps automatic awake ineligible.
autoCheck("manual eligibility is independent of power",
          AwakeGate.sessionAllowsAssertion(.active)
          && AwakeGate.autoEligible(enabled: true, power: .battery, session: .active) == false
          && AwakeGate.autoEligible(enabled: true, power: .unknown, session: .active) == false)

autoCheck("detail names a locked pause",
          AwakeGate.autoDetail(enabled: true, power: .external, session: .locked,
                               working: true, asserting: false, held: false, gracePending: false)
          == "Auto: paused — screen locked")
autoCheck("detail names battery",
          AwakeGate.autoDetail(enabled: true, power: .battery, session: .active,
                               working: true, asserting: false, held: false, gracePending: false)
          == "Auto: paused — on battery")
autoCheck("detail names an unknown power source",
          AwakeGate.autoDetail(enabled: true, power: .unknown, session: .active,
                               working: true, asserting: false, held: false, gracePending: false)
          == "Auto: paused — power source unavailable")
autoCheck("detail names an unknown session",
          AwakeGate.autoDetail(enabled: true, power: .external, session: .unknown,
                               working: true, asserting: false, held: false, gracePending: false)
          == "Auto: paused — session unavailable")
autoCheck("detail names no work",
          AwakeGate.autoDetail(enabled: true, power: .external, session: .active,
                               working: false, asserting: false, held: false, gracePending: false)
          == "Auto: ready — no Codex work")
autoCheck("detail names a held assertion",
          AwakeGate.autoDetail(enabled: true, power: .external, session: .active,
                               working: true, asserting: true, held: true, gracePending: false)
          == "Auto: holding")
autoCheck("detail names a held grace",
          AwakeGate.autoDetail(enabled: true, power: .external, session: .active,
                               working: false, asserting: true, held: true, gracePending: true)
          == "Auto: holding (120s grace)")
// The engine may intend an assertion while the owned process is unavailable
// (spawn failed or exited early): the intent is never reported as holding.
autoCheck("detail reports an unavailable assertion instead of holding",
          AwakeGate.autoDetail(enabled: true, power: .external, session: .active,
                               working: true, asserting: true, held: false, gracePending: false)
          == "Auto: not holding — assertion unavailable")
autoCheck("detail names a disabled toggle",
          AwakeGate.autoDetail(enabled: false, power: .battery, session: .locked,
                               working: false, asserting: false, held: false, gracePending: false)
          == "Auto: off")

// MARK: - Session sampler validation (fail closed)

func sessionDictionary(
    onConsole: Any? = NSNumber(value: true),
    loginDone: Any? = NSNumber(value: true),
    user: Any? = "plan",
    screenLocked: Any? = nil
) -> [String: Any] {
    var dictionary: [String: Any] = [:]
    if let onConsole = onConsole { dictionary["kCGSSessionOnConsoleKey"] = onConsole }
    if let loginDone = loginDone { dictionary["kCGSessionLoginDoneKey"] = loginDone }
    if let user = user { dictionary["kCGSSessionUserNameKey"] = user }
    if let screenLocked = screenLocked { dictionary["CGSSessionScreenIsLocked"] = screenLocked }
    return dictionary
}

autoCheck("valid console session is active",
          SessionSampler.evaluate(sessionDictionary()) == .active)
autoCheck("missing session dictionary is unknown",
          SessionSampler.evaluate(nil) == .unknown)
autoCheck("missing console flag is unknown",
          SessionSampler.evaluate(sessionDictionary(onConsole: nil)) == .unknown)
autoCheck("non-console session is unknown",
          SessionSampler.evaluate(sessionDictionary(onConsole: NSNumber(value: false))) == .unknown)
autoCheck("numeric console flag is not a boolean and fails closed",
          SessionSampler.evaluate(sessionDictionary(onConsole: NSNumber(value: 1))) == .unknown)
autoCheck("string console flag fails closed",
          SessionSampler.evaluate(sessionDictionary(onConsole: "true")) == .unknown)
autoCheck("missing login user is unknown",
          SessionSampler.evaluate(sessionDictionary(user: nil)) == .unknown)
autoCheck("blank login user is unknown",
          SessionSampler.evaluate(sessionDictionary(user: "   ")) == .unknown)
autoCheck("non-string login user is unknown",
          SessionSampler.evaluate(sessionDictionary(user: NSNumber(value: 501))) == .unknown)
autoCheck("explicit login-not-done fails closed",
          SessionSampler.evaluate(sessionDictionary(loginDone: NSNumber(value: false))) == .unknown)
autoCheck("numeric login flag fails closed",
          SessionSampler.evaluate(sessionDictionary(loginDone: NSNumber(value: 1))) == .unknown)
autoCheck("absent login flag is tolerated in a valid console session",
          SessionSampler.evaluate(sessionDictionary(loginDone: nil)) == .active)
autoCheck("documented lock key true is locked",
          SessionSampler.evaluate(sessionDictionary(screenLocked: NSNumber(value: true))) == .locked)
autoCheck("documented lock key false is active",
          SessionSampler.evaluate(sessionDictionary(screenLocked: NSNumber(value: false))) == .active)
autoCheck("absent undocumented lock key is treated as unlocked",
          SessionSampler.evaluate(sessionDictionary(screenLocked: nil)) == .active)
autoCheck("malformed undocumented lock key fails closed",
          SessionSampler.evaluate(sessionDictionary(screenLocked: "yes")) == .unknown)
autoCheck("numeric undocumented lock key fails closed",
          SessionSampler.evaluate(sessionDictionary(screenLocked: NSNumber(value: 1))) == .unknown)

// MARK: - Separate sleep / inactive / lock latches

var latches = SessionGate()
autoCheck("latches start clear", latches.sleeping == false && latches.inactive == false && latches.locked == false)
autoCheck("a clear gate passes the snapshot through", latches.resolve(snapshot: .locked) == .locked)

latches.apply(.willSleep)
autoCheck("sleep latch wins over an active snapshot", latches.resolve(snapshot: .active) == .sleeping)
latches.apply(.screenLocked)
latches.apply(.didWake)
autoCheck("wake alone cannot resume while the lock latch is set",
          latches.resolve(snapshot: .active) == .locked)
latches.apply(.screenUnlocked)
autoCheck("unlock plus didWake returns to the snapshot",
          latches.resolve(snapshot: .active) == .active)

latches.apply(.screenLocked)
latches.apply(.screenLocked)
autoCheck("duplicate lock notifications are idempotent",
          latches.resolve(snapshot: .active) == .locked)
latches.apply(.resignedActive)
latches.apply(.screenUnlocked)
autoCheck("an inactive latch still wins after unlock",
          latches.resolve(snapshot: .active) == .inactive)
latches.apply(.becameActive)
autoCheck("becoming active clears the inactive latch",
          latches.resolve(snapshot: .active) == .active)

// A stale sampled snapshot must never override a just-delivered lock.
latches.apply(.screenLocked)
autoCheck("a stale active snapshot cannot override the lock latch",
          latches.resolve(snapshot: .active) == .locked)
latches.apply(.screenUnlocked)
var sleepOnly = SessionGate()
sleepOnly.apply(.willSleep)
autoCheck("a sleeping session still fails the shared gate",
          AwakeGate.autoEligible(enabled: true, power: .external,
                                 session: sleepOnly.resolve(snapshot: .active)) == false)

// MARK: - Authorization-aware automatic engine

var gated = AutoAwakeEngine()
autoCheck("ineligible work never asserts",
          gated.step(working: true, eligible: false, now: 0) == false
          && gated.asserting == false && gated.graceUntil == nil)
autoCheck("eligible work asserts",
          gated.step(working: true, eligible: true, now: 1) == true)
autoCheck("losing eligibility releases at once and clears grace",
          gated.step(working: false, eligible: false, now: 2) == false
          && gated.asserting == false && gated.graceUntil == nil)
autoCheck("new work cannot restart while ineligible",
          gated.step(working: true, eligible: false, now: 3) == false
          && gated.asserting == false && gated.graceUntil == nil)
autoCheck("work restarts once eligibility returns",
          gated.step(working: true, eligible: true, now: 4) == true)

var gatedGrace = AutoAwakeEngine()
_ = gatedGrace.step(working: true, eligible: true, now: 0)
_ = gatedGrace.step(working: false, eligible: true, now: 10)
autoCheck("work-to-idle starts the 120s grace while eligible", gatedGrace.graceUntil == 130)
autoCheck("a lock during grace releases before the deadline",
          gatedGrace.step(working: true, eligible: false, now: 20) == false
          && gatedGrace.asserting == false && gatedGrace.graceUntil == nil)
autoCheck("waking while locked still cannot resume",
          gatedGrace.step(working: true, eligible: false, now: 30) == false)
autoCheck("unlocking with current work resumes",
          gatedGrace.step(working: true, eligible: true, now: 31) == true)

// MARK: - Manual helper state parsing and paused presentation

autoCheck("parse an active helper status",
          ManualState.parse("ON — system idle sleep prevented.\nAutomatic stop: 2026-09-27 10:00 PDT\n")
          == .active(expiry: "2026-09-27 10:00 PDT"))
autoCheck("parse a paused helper status with remaining seconds",
          ManualState.parse("PAUSED — held.\nAutomatic stop: 2026-09-27 10:00 PDT\nRemaining: 42\n")
          == .paused(expiry: "2026-09-27 10:00 PDT", remaining: 42))
autoCheck("parse an off helper status",
          ManualState.parse("OFF — normal sleep settings apply.\n") == .off)
autoCheck("empty helper status is unreadable",
          ManualState.parse("") == nil)
autoCheck("unknown helper status is unreadable",
          ManualState.parse("garbage\n") == nil)
autoCheck("a paused timer is not an active assertion",
          ManualState.paused(expiry: "x", remaining: 5).isActive == false
          && ManualState.paused(expiry: "x", remaining: 5).isPaused == true)
autoCheck("a paused timer does not fill the cup",
          CupState.filled(manual: ManualState.paused(expiry: "x", remaining: 5).isActive,
                          automatic: false) == false)
autoCheck("a paused manual line is kept with its original deadline",
          WorkModeApp.menuStatus(manualActive: false, manualPaused: true,
                                 manualLine: "Timer paused — until 17:00", automatic: false)
          == "Timer paused — until 17:00")
autoCheck("a paused manual line wins over an automatic assertion",
          WorkModeApp.menuStatus(manualActive: false, manualPaused: true,
                                 manualLine: "Timer paused — until 17:00", automatic: true)
          == "Timer paused — until 17:00")

// MARK: - Absolute paused deadline (never extended by a status read)

let pausedEpoch = 50_000.0
let pausedStatusA = "PAUSED — held.\nAutomatic stop: 2040-01-01 00:00 PST\nExpires: 50000\nRemaining: 900\n"
let pausedStatusB = "PAUSED — held.\nAutomatic stop: 2040-01-01 00:00 PST\nExpires: 50000\nRemaining: 5\n"
autoCheck("a published epoch is the scheduling deadline",
          ManualState.deadline(from: pausedStatusA, now: 1) == pausedEpoch)
autoCheck("a later status with a smaller remaining cannot move the deadline",
          ManualState.deadline(from: pausedStatusB, now: 40_000) == pausedEpoch)
autoCheck("status keeps the helper's current remaining",
          ManualState.parse(pausedStatusB) == .paused(expiry: "2040-01-01 00:00 PST", remaining: 5))
let legacyPausedStatus = "PAUSED — held.\nAutomatic stop: 2040-01-01 00:00 PST\nRemaining: 900\n"
autoCheck("a legacy record without an epoch falls back to now + remaining",
          ManualState.deadline(from: legacyPausedStatus, now: 1_000) == 1_900)
autoCheck("an active record's epoch is its deadline",
          ManualState.deadline(from: "ON — awake\nExpires: 12345\n", now: 1) == 12_345)
autoCheck("an off status has no deadline",
          ManualState.deadline(from: "OFF — normal sleep settings apply.\n", now: 1) == nil)

// MARK: - Effective owned-assertion state (spawn failure / early exit)

final class TestPowerProvider: PowerSourceProviding {
    var availability: PowerAvailability = .external
    var onChange: (() -> Void)?
    func start() {}
    func sample() {}
}

func pumpMainRunLoop(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

func uniqueTestFolder(_ name: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()
        + "codex-work-mode-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// A spawn that cannot even be launched must never be reported as holding, and
// the next attempt must be deferred to the renewal boundary rather than retried
// in a tight loop.
do {
    let assertionApp = WorkModeApp()
    assertionApp.folder = uniqueTestFolder("assertion")
    assertionApp.powerMonitor = TestPowerProvider()
    assertionApp.autoEnabled = true
    assertionApp.helperInvocationOverride = { _, _, _ in
        (0, "OFF — normal sleep settings apply.\n")
    }

    let t0 = Date().timeIntervalSince1970
    assertionApp.autoAssertionExecutable = "/nonexistent/caffeinate-for-test"
    assertionApp.startAutoProcess(now: t0)
    autoCheck("a failed spawn is never reported as holding",
              assertionApp.autoHeld == false && assertionApp.autoProcess == nil)
    autoCheck("a failed spawn anchors the bounded backoff",
              assertionApp.autoStartedAt == t0)
    assertionApp.ensureAutoAssertion(now: t0 + 10)
    autoCheck("no retry is attempted inside the renewal window",
              assertionApp.autoStartedAt == t0 && assertionApp.autoProcess == nil)
    assertionApp.ensureAutoAssertion(now: t0 + AutoAwakeEngine.renewalSeconds)
    autoCheck("exactly one retry is attempted at the renewal boundary",
              assertionApp.autoStartedAt == t0 + AutoAwakeEngine.renewalSeconds)

    assertionApp.autoAssertionExecutable = "/usr/bin/caffeinate"
    let t1 = Date().timeIntervalSince1970
    assertionApp.startAutoProcess(now: t1)
    autoCheck("a real owned assertion is running and reported as holding",
              assertionApp.autoProcess?.isRunning == true && assertionApp.autoHeld == true)
    let owned = assertionApp.autoProcess
    owned?.terminate()
    pumpMainRunLoop(3)
    autoCheck("an unexpected early exit clears the effective held state",
              assertionApp.autoHeld == false && assertionApp.autoProcess == nil)
    autoCheck("an early exit anchors a bounded backoff, not a retry loop",
              assertionApp.autoStartedAt > 0)
    assertionApp.stopAutoProcess()
}

// MARK: - Delayed helper vs. session transition (async reconciliation)

final class RaceSessionProvider: SessionProviding {
    var state: SessionState = .active
    func sample() -> SessionState { return state }
}

final class DelayedFakeHelper {
    private let lock = NSLock()
    private var calls: [String] = []
    private var recordState = "paused"
    private var expires = Int(Date().timeIntervalSince1970) + 600
    private var remaining = 600
    var blockingMode: String?
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func setState(_ value: String) {
        lock.lock()
        recordState = value
        lock.unlock()
    }

    func callList() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func perform(_ mode: String) -> (Int32, String) {
        lock.lock()
        calls.append(mode)
        let blocks = (mode == blockingMode)
        lock.unlock()
        if blocks {
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        lock.lock()
        switch mode {
        case "resume":
            recordState = "active"
        case "suspend":
            recordState = "paused"
            remaining = 500
        case "off":
            recordState = "off"
        default:
            break
        }
        let text: String
        switch recordState {
        case "active":
            text = "ON — system idle sleep prevented.\n"
                + "Automatic stop: 2040-01-01 00:00 PST\nExpires: \(expires)\n"
        case "paused":
            text = "PAUSED — held.\n"
                + "Automatic stop: 2040-01-01 00:00 PST\nExpires: \(expires)\n"
                + "Remaining: \(remaining)\n"
        default:
            text = "OFF — normal sleep settings apply.\n"
        }
        lock.unlock()
        return (0, text)
    }
}

func waitForCall(_ helper: DelayedFakeHelper, _ mode: String, seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if helper.callList().contains(mode) { return true }
        pumpMainRunLoop(0.05)
    }
    return helper.callList().contains(mode)
}

// A lock that arrives while a resume is still in flight must not be lost: the
// completion has to reconcile the newest gate state and suspend again.
do {
    let app = WorkModeApp()
    app.folder = uniqueTestFolder("race-lock")
    app.powerMonitor = TestPowerProvider()
    app.autoEnabled = false
    let session = RaceSessionProvider()
    session.state = .active
    app.sessionProvider = session
    let helper = DelayedFakeHelper()
    helper.blockingMode = "resume"
    app.helperInvocationOverride = { mode, _, _ in helper.perform(mode) }

    app.refresh()   // paused manual session -> resume starts and blocks
    autoCheck("the delayed resume reached the fake helper",
              helper.entered.wait(timeout: .now() + 5) == .success)
    app.handleSessionChange(.screenLocked)
    autoCheck("a lock delivered while the helper is busy is remembered",
              app.reconcilePending == true && app.busy == true)
    helper.release.signal()
    autoCheck("the pending lock is reconciled once the helper returns",
              waitForCall(helper, "suspend", seconds: 5))
    let calls = helper.callList()
    autoCheck("a resume is never left final while the session is locked",
              (calls.lastIndex(of: "resume") ?? -1) < (calls.lastIndex(of: "suspend") ?? -1))
    app.stopAutoProcess()
}

// The mirror case: an unlock during a suspend must reconcile into a resume.
do {
    let app = WorkModeApp()
    app.folder = uniqueTestFolder("race-unlock")
    app.powerMonitor = TestPowerProvider()
    app.autoEnabled = false
    let session = RaceSessionProvider()
    session.state = .active
    app.sessionProvider = session
    app.sessionGate.apply(.screenLocked)
    app.sessionState = .locked
    let helper = DelayedFakeHelper()
    helper.setState("active")
    helper.blockingMode = "suspend"
    app.helperInvocationOverride = { mode, _, _ in helper.perform(mode) }

    app.refresh()   // active manual session + locked -> suspend starts and blocks
    autoCheck("the delayed suspend reached the fake helper",
              helper.entered.wait(timeout: .now() + 5) == .success)
    app.handleSessionChange(.screenUnlocked)
    autoCheck("an unlock delivered while the helper is busy is remembered",
              app.reconcilePending == true && app.busy == true)
    helper.release.signal()
    autoCheck("the pending unlock is reconciled into a resume once the helper returns",
              waitForCall(helper, "resume", seconds: 5))
    let calls = helper.callList()
    autoCheck("a suspend is never left final while the session is unlocked",
              (calls.lastIndex(of: "suspend") ?? -1) < (calls.lastIndex(of: "resume") ?? -1))
    app.stopAutoProcess()
}

// MARK: - Unstarted monitor fails closed

// A monitor with no successfully installed notification source (start() never
// called, or setup failed) must keep failing closed: sample() may not trust a
// one-off read, so an unlock/wake-triggered sample can never hold automatic
// awake without live power notifications. The result must stay unknown
// regardless of the host's actual power source; the static read-only probe
// remains an independent read.
do {
    let unstarted = PowerSourceMonitor()
    autoCheck("an unstarted monitor starts unknown", unstarted.availability == .unknown)
    unstarted.sample()
    autoCheck("sample() with no installed source stays unknown", unstarted.availability == .unknown)
    unstarted.sample()
    autoCheck("repeated sample() with no installed source stays unknown", unstarted.availability == .unknown)
    let firstProbe = PowerSourceMonitor.providingPowerSource()
    let secondProbe = PowerSourceMonitor.providingPowerSource()
    autoCheck("the static read-only probe is independent and side-effect free",
              firstProbe == secondProbe && unstarted.availability == .unknown)
}

// MARK: - Bounds

autoCheck("grace is 120 seconds", AutoAwakeEngine.graceSeconds == 120)
autoCheck("assertion bound is 300 seconds", AutoAwakeEngine.assertionSeconds == 300)
autoCheck("renewal happens before the bound",
          AutoAwakeEngine.renewalSeconds < AutoAwakeEngine.assertionSeconds)

if autoFailures > 0 {
    print("FAILED: \(autoFailures) auto-awake check(s)")
    exit(1)
}
print("PASS: all auto-awake behavioral checks")
exit(0)
