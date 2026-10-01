// MARK: - QA acceptance anchor (QA-only; appended after the production source)
//
// The shipped app is a windowless accessory (LSUIElement) process, so CUA cannot
// bind to it. This QA-only window exists solely to give CUA a bindable, titled
// process window; its single button pops up the REAL NSStatusItem menu anchored
// to that window, so the production menu (including the status, automatic
// eligibility, power source and energy mode rows) is exercised. No menu, action,
// validation, or helper behavior is duplicated, faked, or simulated.
//
// The window is 760x420 with the menu anchor at (40, 360), which is large enough
// for the nested Details menu and the native Custom hours dialog without the
// screenshot clipping seen with the smaller v1.4.1 anchor. This is a QA-only
// canvas; the production menu and source are unchanged.
//
// QA-only adapter injection: the generated QA source replaces the two adapter
// initializers with the fixture implementations below, so the controller can set
// the power source and session state deterministically while leaving the shared
// gate, menu logic, and helper exactly as production. The production binary
// never contains these types, and with no fixture files present the QA adapters
// default to `unknown`/`unknown`, which fails closed. The QA state-dir
// placeholder below is replaced with the isolated QA state root by
// qa/build-qa.sh.

extension WorkModeApp {
    /// Small @objc target/action bridge that pops the production menu up inside
    /// the visible test window. Uses the same menu delegate callbacks as the
    /// real status-item click.
    @objc func qaOpenMenu(_ sender: Any?) {
        item.menu?.popUp(positioning: nil, at: NSPoint(x: 40, y: 360), in: qaWindow.contentView)
    }
}

// MARK: - QA-only power/session fixtures

let qaStateRoot = URL(fileURLWithPath: "__QA_STATE_DIR__")

func qaFixtureValue(_ name: String) -> String {
    let path = qaStateRoot.appendingPathComponent(name)
    return ((try? String(contentsOf: path, encoding: .utf8)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func qaFixtureSession() -> SessionState {
    switch qaFixtureValue("qa-session") {
    case "active": return .active
    case "locked": return .locked
    case "sleeping": return .sleeping
    case "inactive": return .inactive
    default: return .unknown
    }
}

func qaFixturePower() -> PowerAvailability {
    switch qaFixtureValue("qa-power") {
    case "external": return .external
    case "battery": return .battery
    default: return .unknown
    }
}

final class QASessionSampler: SessionProviding {
    func sample() -> SessionState { qaFixtureSession() }
}

/// QA-only power adapter. It reads the same fixture files on a short QA timer so
/// a fixture edit deterministically re-evaluates the shared gate without any
/// real notification. Production uses IOKit events only and never polls.
final class QAPowerSourceMonitor: PowerSourceProviding {
    private(set) var availability: PowerAvailability = .unknown
    var onChange: (() -> Void)?
    private var timer: DispatchSourceTimer?
    private var lastSignature: String?

    func start() {
        sample()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func sample() {
        let powerValue = qaFixtureValue("qa-power")
        let sessionValue = qaFixtureValue("qa-session")
        availability = qaFixturePower()
        let signature = "\(powerValue)|\(sessionValue)"
        if let last = lastSignature, last != signature {
            onChange?()
        }
        lastSignature = signature
    }
}

/// Strongly retained for the process lifetime (top-level `let`).
let qaWindow: NSWindow = {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Codex Work Mode QA"
    window.isReleasedWhenClosed = false
    window.center()

    let button = NSButton(
        title: "Open menu",
        target: delegate,
        action: #selector(WorkModeApp.qaOpenMenu(_:))
    )
    button.bezelStyle = .rounded
    button.keyEquivalent = "\r"
    button.frame = NSRect(x: 40, y: 340, width: 160, height: 32)
    window.contentView?.addSubview(button)

    let hint = NSTextField(labelWithString: "QA harness — opens the real status-item menu")
    hint.frame = NSRect(x: 40, y: 380, width: 400, height: 18)
    hint.alignment = .left
    hint.textColor = .secondaryLabelColor
    window.contentView?.addSubview(hint)

    let fixtureHint = NSTextField(
        labelWithString: "Fixtures: state/qa-power (external|battery|unknown) · "
            + "state/qa-session (active|locked|sleeping|inactive|unknown)"
    )
    fixtureHint.frame = NSRect(x: 40, y: 300, width: 680, height: 32)
    fixtureHint.alignment = .left
    fixtureHint.textColor = .tertiaryLabelColor
    fixtureHint.lineBreakMode = .byWordWrapping
    fixtureHint.maximumNumberOfLines = 2
    window.contentView?.addSubview(fixtureHint)

    return window
}()

// Let CUA bind: applicationDidFinishLaunching forces the accessory policy, so
// this deferred main-queue hop runs afterwards to promote the QA process to a
// normal app and show the window. QA-only; production behavior is untouched.
DispatchQueue.main.async {
    _ = NSApp.setActivationPolicy(.regular)
    qaWindow.makeKeyAndOrderFront(nil)
    if #available(macOS 14.0, *) {
        NSApp.activate()
    } else {
        NSApp.activate(ignoringOtherApps: true)
    }
}
