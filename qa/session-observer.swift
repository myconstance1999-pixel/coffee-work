// Isolated read-only session/power observer (v1.5 QA/controller tool).
//
// This file is concatenated after the production source (with the trailing
// NSApplication bootstrap removed), so it uses the SAME SessionSampler,
// PowerSourceMonitor, SessionGate, and AwakeGate types the app uses. It never
// starts a caffeinate assertion, never writes any state, never changes a
// setting, and never reads Codex data. It only logs, for each observed
// transition, a timestamp, an event name, and eligibility booleans plus the
// coarse power/session categories — no pid, username, window title, or content.
//
// Build (see tests/validate.sh):
//   sed '/^let app = NSApplication.shared$/,$d' MenuBar.swift > build/ObserverPrefix.swift
//   cat qa/session-observer.swift >> build/ObserverPrefix.swift
//   swiftc -O -target arm64-apple-macosx13.0 -framework AppKit -framework CoreGraphics \
//       -framework IOKit build/ObserverPrefix.swift -o build/session-observer
// Run:
//   ./build/session-observer --seconds 60
//
// The controller can run it, then perform a real lock/unlock or power change,
// and compare the logged transitions with what the app reports. The observer is
// read-only and exits after the requested duration.

func observerSessionLabel(_ state: SessionState) -> String {
    switch state {
    case .active: return "active"
    case .locked: return "locked"
    case .sleeping: return "sleeping"
    case .inactive: return "inactive"
    case .unknown: return "unknown"
    }
}

func observerPowerLabel(_ power: PowerAvailability) -> String {
    switch power {
    case .external: return "external"
    case .battery: return "battery"
    case .unknown: return "unknown"
    }
}

let observerArguments = CommandLine.arguments
var observerSeconds = 20.0
if let index = observerArguments.firstIndex(of: "--seconds"),
   index + 1 < observerArguments.count,
   let value = Double(observerArguments[index + 1]),
   value > 0 {
    observerSeconds = min(value, 3600)
}

let observerFormatter = ISO8601DateFormatter()
var observerGate = SessionGate()
let observerSessionProvider = SessionSampler()
var observerSnapshot = SessionState.unknown

func observerReport(_ event: String) {
    let power = PowerSourceMonitor.providingPowerSource()
    let session = observerGate.resolve(snapshot: observerSnapshot)
    let autoEligible = AwakeGate.autoEligible(enabled: true, power: power, session: session)
    let manualEligible = AwakeGate.sessionAllowsAssertion(session)
    print("\(observerFormatter.string(from: Date())) event=\(event) "
        + "power=\(observerPowerLabel(power)) session=\(observerSessionLabel(session)) "
        + "autoEligible=\(autoEligible) manualEligible=\(manualEligible)")
    fflush(stdout)
}

func observerHandle(_ change: SessionChange, _ event: String) {
    observerGate.apply(change)
    switch change {
    case .willSleep, .resignedActive, .screenLocked:
        break
    case .didWake, .becameActive, .screenUnlocked:
        observerSnapshot = observerSessionProvider.sample()
    }
    observerReport(event)
}

let observerPowerMonitor = PowerSourceMonitor()
observerPowerMonitor.onChange = { observerReport("power-source") }
observerPowerMonitor.start()

let observerWorkspace = NSWorkspace.shared.notificationCenter
let observerWorkspaceMap: [(Notification.Name, SessionChange, String)] = [
    (NSWorkspace.willSleepNotification, .willSleep, "will-sleep"),
    (NSWorkspace.didWakeNotification, .didWake, "did-wake"),
    (NSWorkspace.sessionDidResignActiveNotification, .resignedActive, "session-resigned-active"),
    (NSWorkspace.sessionDidBecomeActiveNotification, .becameActive, "session-became-active"),
]
for (name, change, event) in observerWorkspaceMap {
    observerWorkspace.addObserver(forName: name, object: nil, queue: .main) { _ in
        observerHandle(change, event)
    }
}
let observerDistributed = DistributedNotificationCenter.default()
observerDistributed.addObserver(
    forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
) { _ in
    observerHandle(.screenLocked, "screen-locked")
}
observerDistributed.addObserver(
    forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
) { _ in
    observerHandle(.screenUnlocked, "screen-unlocked")
}

// Register before the initial snapshot, exactly like the app.
observerSnapshot = observerSessionProvider.sample()
observerReport("start")
RunLoop.main.run(until: Date().addingTimeInterval(observerSeconds))
observerReport("stop")
