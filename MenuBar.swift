// Codex Work Mode — menu-bar front end.
//
// A compact, fixed-width status item (monochrome template SF Symbol) plus one
// concise menu. There is no status window and no duplicated set of controls.
//
// This app is a thin, bounded front end for the installed helper at
// ~/Library/Application Support/Codex Work Mode/toggle.zsh, which owns the
// session state and the bounded caffeinate process. The app itself never sets
// power or lock policy, never polls, never installs anything, never registers a
// login item, and never touches the network.
//
// Version 1.3 adds two read-only informational rows: the current power source
// and the active energy mode, obtained from one read-only
// `system_profiler SPPowerDataType -json` run and one read-only
// `pmset -g custom` run at launch and each time the menu opens. The `pmset`
// value (`0`/`1`/`2`) is authoritative where present, because the profiler's
// `HighPowerMode` / `LowPowerMode` flags are unreliable on current macOS;
// elsewhere the strict profiler flags are used. Nothing is written, polled, or
// elevated.
//
// Version 1.4 adds automatic awake for local Codex desktop work. A separate
// hook receiver (activity-hook.py, owned by the install step) writes one
// minimal snapshot under `codex-activity/` in this app's support folder. The
// app only reads that snapshot, watches the directory and the owning process,
// and runs its own bounded `caffeinate -i -t 300 -w <app pid>` while a turn
// works or during the 120 second grace after the last turn stops. The manual
// helper session (toggle.zsh) stays completely separate: its 1/4/8/custom
// timers, Stop action, and manual lock behavior are untouched, and the cup is
// filled when either awake source is active. The app never starts automatic
// awake while the Auto awake toggle is off, persists only that toggle, never
// changes native energy profiles, and releases its own assertion on quit.
//
// Version 1.4.1 is a presentation-only change: the same rows and the same
// targets/actions are regrouped so the menu stays short. The overall status
// stays the top read-only row (a manual session still shows its end time
// there), the Auto awake toggle stays one click away, the 1/4/8/custom timer
// choices move into one "Keep awake for" submenu (replaced by a direct "Stop
// timer" row while a manual session runs), and the read-only Codex activity,
// power source and energy mode rows move into a "Details" submenu. Neither
// submenu has a menu delegate, so opening one never refreshes state, rebuilds
// the parent menu, or starts another power probe; the existing
// `powerSourceItem`/`energyModeItem` references still retitle those nested rows
// in place when an asynchronous read completes. No timer, automatic-awake,
// helper, receiver, or hook behavior changes.
//
// Version 1.5 makes both awake sources session- and power-aware, and switches
// ordinary caffeinate requests to system idle-sleep prevention only (`-i`); the
// normal mode never holds the display on, so it may turn off and a dark
// screen is never treated as a lock. Version 1.6 adds an explicit bounded GUI
// timer (`-d -i`), with the same session gate. Version 1.7.2 permits automatic
// idle-sleep protection while locked only on AC with a valid working hook
// snapshot. Manual and GUI timers still require an unlocked session. Sleep,
// inactive/unknown sessions, and unavailable power remain ineligible.
//
// Version 1.8 makes the two explicit awake sources independent and extends the
// explicit display request:
//   * the manual background timer, the explicit display hold, and automatic
//     background work may all be configured at the same time; starting or
//     stopping one never changes another source's deadline or process, and the
//     compact menu carries one truthful status and one stop action per source;
//   * the "保持屏幕显示" submenu offers 30 minutes, 1/4/8 hours, a custom whole
//     hour count from 1 through 24, and an until-stopped request. It is offered
//     on battery and in Low Power Mode because eligibility is the current
//     unlocked active session alone, never the power source or energy mode, and
//     no OS energy setting is written;
//   * a finite display request keeps one absolute deadline that survives pauses
//     unchanged and never revives after expiry or cancellation. An until-stopped
//     request is a distinct, memory-only state covered by bounded owner-tied
//     `-d -i -t 300 -w <app pid>` leases renewed every 240 seconds, so a hung app
//     can never leave a stray indefinite child behind. Every display child uses
//     `-d -i -t <= 86400 -w <app pid>`, never `-u` or `-s` and never simulated
//     input, and an app restart never restores a display request;
//   * a user-invoked "立即启动屏保" row opens the installed system
//     ScreenSaverEngine through NSWorkspace. It ends only this app's explicit
//     display hold so Coffee does not fight the user's choice, leaves background
//     and automatic awake work untouched, writes no screen saver, timeout,
//     password or energy setting, and never claims the screen saver is running
//     when the launcher fails.
//
// The original manual and GUI gate requires:
//   * the current login session must be the active console session, unlocked
//     and past login, read through the same `SessionSampler` adapter used by
//     the isolated session observer;
//   * automatic awake additionally requires external power, read through the
//     IOKit power-source API with an event-only `IOPSNotificationCreateRunLoopSource`
//     (no polling, no menu gating), and fails closed when the source is
//     unavailable;
//   * manual awake is an explicit user request, so it ignores power, but it is
//     still suspended while the session is locked, asleep, inactive, or
//     unknown. The helper keeps the original deadline and remaining seconds, so
//     resuming never extends the timer.
// Sleep, inactive, and lock latches are tracked separately, so waking while
// still locked cannot resume an assertion. The app never writes the helper
// state file: it asks the helper to suspend or resume and re-reads the current
// activity snapshot and power source before resuming.

import AppKit
import CoreGraphics
import Dispatch
import IOKit.ps
import UniformTypeIdentifiers

/// Local metadata only. Four 256 KiB files per producer; logging failures never
/// participate in an awake decision. Logs live below the watched directories,
/// so appends do not trigger a refresh loop.
final class DiagnosticLog {
    static let maximumBytes = 256 * 1024
    static let archives = 3
    static let fieldNames: Set<String> = [
        "reason", "status", "session", "power", "enabled", "held", "requested",
        "owner_pid", "pid", "exit_code", "error_code", "mode", "paused",
        "grace_until", "working_count", "waiting_count", "version", "expires"
    ]
    let directory: URL
    let lock = NSLock()
    private var lastObservations: [String: [String: String]] = [:]

    init(directory: URL) { self.directory = directory }

    func record(_ event: String, fields: [String: Any] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        append(event, fields: fields)
    }

    /// Repeated state reads are not events; preserve transitions without
    /// producing a line for every file notification or menu refresh.
    func observation(_ event: String, fields: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        guard lastObservations[event] != fields else { return }
        lastObservations[event] = fields
        append(event, fields: fields)
    }

    private func append(_ event: String, fields: [String: Any]) {
        var row: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()),
                                  "producer": "app", "event": String(event.prefix(64))]
        for (key, value) in fields where Self.fieldNames.contains(key) {
            if let string = value as? String { row[key] = String(string.prefix(120)) }
            else if value is NSNumber { row[key] = value }
        }
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(10)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let path = directory.appendingPathComponent("app.jsonl")
            let size = (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size + data.count > Self.maximumBytes {
                for index in stride(from: Self.archives, through: 1, by: -1) {
                    let destination = directory.appendingPathComponent("app.jsonl.\(index)")
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    let source = index == 1 ? path : directory.appendingPathComponent("app.jsonl.\(index - 1)")
                    if FileManager.default.fileExists(atPath: source.path) {
                        try FileManager.default.moveItem(at: source, to: destination)
                    }
                }
            }
            let fd = open(path.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            _ = fchmod(fd, 0o600)
            data.withUnsafeBytes { bytes in _ = write(fd, bytes.baseAddress, bytes.count) }
        } catch { /* Best effort: diagnostic I/O cannot change policy. */ }
    }

    /// Export only the two known producers' bounded files, never arbitrary
    /// support files, snapshots, raw payloads, or hidden lock files.
    func export(to destination: URL, hookDirectory: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = temporary.appendingPathComponent("Coffee Work Diagnostics")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (producer, source) in [("app", directory), ("hook", hookDirectory)] {
            for suffix in [""] + (1...Self.archives).map({ ".\($0)" }) {
                let name = producer + ".jsonl" + suffix
                let file = source.appendingPathComponent(name)
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      (values.fileSize ?? 0) <= Self.maximumBytes else { continue }
                if let data = try? Data(contentsOf: file) {
                    try data.write(to: package.appendingPathComponent(name))
                }
            }
        }
        let note = "Local diagnostic metadata. Times are UTC. Display-off is distinct from screen lock and system sleep. Missing events are not proof that an event did not occur; crashes cannot log their own termination. No prompt/tool/media content is collected.\n"
        try note.write(to: package.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", package.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CoffeeWorkDiagnostics", code: Int(process.terminationStatus))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

/// Undocumented key used by `CGSessionCopyCurrentDictionary` to expose the
/// current screen-lock state. It is not declared in a public header, so it is
/// spelled out here and its handling is documented at the read site.
let cgSessionScreenIsLockedKey = "CGSSessionScreenIsLocked"

/// Coarse power availability for the shared awake gate.
///
/// `unknown` is a distinct, fail-closed value: an unreadable or unrecognized
/// power source can never authorize automatic awake. Manual awake is an
/// explicit user request and is deliberately independent of power.
enum PowerAvailability: Equatable {
    case external
    case battery
    case unknown
}

/// Coarse state of the current graphical login session.
enum SessionState: Equatable {
    case active
    case locked
    case sleeping
    case inactive
    case unknown
}

/// Pure session and task eligibility rules. Manual and GUI holds require an
/// unlocked session; automatic background holds have a narrow locked allowance.
enum AwakeGate {
    /// Manual and GUI assertions require the active, unlocked console session.
    static func sessionAllowsAssertion(_ state: SessionState) -> Bool {
        state == .active
    }

    /// A locked session additionally requires a currently verified working
    /// task. Idle, approval waits, invalid snapshots and grace never qualify
    /// while locked. Actual sleep and inactive/unknown sessions always win.
    static func autoEligible(
        enabled: Bool,
        power: PowerAvailability,
        session: SessionState,
        working: Bool
    ) -> Bool {
        enabled && power == .external
            && (sessionAllowsAssertion(session) || (session == .locked && working))
    }

    /// Human-readable reason the automatic assertion is or is not held, for the
    /// Details submenu. Session reasons come first because a lock or sleep is
    /// the most actionable, then power, then Codex work. `held` is the effective
    /// state of the owned process, not the engine's intent: a requested
    /// assertion whose process failed to start or exited early is reported as
    /// not holding.
    static func autoDetail(
        enabled: Bool,
        power: PowerAvailability,
        session: SessionState,
        working: Bool,
        asserting: Bool,
        held: Bool,
        gracePending: Bool
    ) -> String {
        guard enabled else { return "Auto: off" }
        switch session {
        case .sleeping: return "Auto: paused — asleep"
        case .locked:
            guard working else { return "Auto: paused — screen locked, no verified work" }
            break
        case .inactive: return "Auto: paused — session inactive"
        case .unknown: return "Auto: paused — session unavailable"
        case .active: break
        }
        switch power {
        case .battery: return "Auto: paused — on battery"
        case .unknown: return "Auto: paused — power source unavailable"
        case .external: break
        }
        if held {
            if session == .locked { return "Auto: holding — locked, verified work, AC" }
            return gracePending ? "Auto: holding (120s grace)" : "Auto: holding"
        }
        if asserting { return "Auto: not holding — assertion unavailable" }
        return working ? "Auto: starting" : "Auto: ready — local hooks idle"
    }
}

/// Adapter for the current login session. The production implementation reads
/// `CGSessionCopyCurrentDictionary`; the isolated session observer and the QA
/// harness reuse this exact type (or a QA fixture implementation of the same
/// protocol), so the acceptance observer and the app never disagree about the
/// rule being tested.
protocol SessionProviding: AnyObject {
    func sample() -> SessionState
}

/// Production session sampler. Strict and fail-closed: a missing dictionary, a
/// non-console session, a missing/blank user, a malformed login flag, a
/// malformed lock value, or a present `false` login flag all yield `.unknown`.
final class SessionSampler: SessionProviding {
    func sample() -> SessionState {
        SessionSampler.evaluate(CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    /// Pure evaluation of one `CGSessionCopyCurrentDictionary` payload.
    ///
    /// Validation, in order:
    ///   * `kCGSessionOnConsoleKey` must be present and have boolean type, and
    ///     must be true; the current session must own the console.
    ///   * `kCGSessionUserNameKey` must be a non-empty string; a login session
    ///     with no user is not a usable desktop session.
    ///   * `kCGSessionLoginDoneKey` is normally present as `true`. Some macOS
    ///     releases omit it in an otherwise valid console session, so absence
    ///     is tolerated; a present non-boolean or `false` value fails closed.
    ///   * The undocumented `CGSSessionScreenIsLocked` key is authoritative
    ///     when present: `true` is `.locked`, `false` is `.active`. Absence in
    ///     an otherwise valid active console session is treated as unlocked
    ///     (the screen is not locked); the distributed lock/unlock
    ///     notifications cover the actual transitions. A present value of any
    ///     other type fails closed to `.unknown`.
    static func evaluate(_ dictionary: [String: Any]?) -> SessionState {
        guard let dictionary = dictionary else { return .unknown }
        guard let onConsole = boolean(dictionary[kCGSessionOnConsoleKey]), onConsole else {
            return .unknown
        }
        guard
            let userName = dictionary[kCGSessionUserNameKey] as? String,
            !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .unknown }
        if let raw = dictionary[kCGSessionLoginDoneKey] {
            guard let loginDone = boolean(raw), loginDone else { return .unknown }
        }
        if let raw = dictionary[cgSessionScreenIsLockedKey] {
            guard let locked = boolean(raw) else { return .unknown }
            return locked ? .locked : .active
        }
        return .active
    }

    /// Reads one value only when it is a real boolean (an `NSNumber` of
    /// `CFBoolean` type), never a numeric `0`/`1` and never a string.
    private static func boolean(_ value: Any?) -> Bool? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }
}

/// Adapter for the current power source. The production implementation is an
/// event-only IOKit run-loop source; the QA harness may substitute a fixture
/// implementation of the same protocol.
protocol PowerSourceProviding: AnyObject {
    var availability: PowerAvailability { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func sample()
}

/// Read-only IOKit power-source monitor.
///
/// The current source is sampled with the read-only `IOPSCopyPowerSourcesInfo`
/// / `IOPSGetProvidingPowerSourceType` pair, and changes are delivered by
/// `IOPSNotificationCreateRunLoopSource` on the main run loop. There is no
/// polling, no menu-only gating, and no write: the API only reports whether the
/// adapter or the battery is currently providing power. Charging state is
/// deliberately ignored, so a full or paused charge still counts as external
/// power. Anything unreadable or unrecognized is `.unknown`.
final class PowerSourceMonitor: PowerSourceProviding {
    private(set) var availability: PowerAvailability = .unknown
    var onChange: (() -> Void)?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context = context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.sample()
            monitor.onChange?()
        }
        // Register the source BEFORE the first sample, so a transition that
        // lands between the two is still delivered. The source is added in
        // common modes so a power change is handled while the menu is tracking
        // (menu tracking runs in the event-tracking mode, not the default one).
        guard
            let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue()
        else {
            // No notification source: the sampled value can no longer be kept
            // current, so the gate must fail closed instead of trusting a stale
            // "external" reading.
            availability = .unknown
            onChange?()
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        sample()
    }

    func sample() {
        // Only a successfully installed notification source keeps a sampled
        // value current. Without one (start() failed, or was never called),
        // a wake/unlock re-sample must not trust a single read: stay unknown
        // so the gate keeps failing closed.
        guard runLoopSource != nil else {
            availability = .unknown
            return
        }
        availability = PowerSourceMonitor.providingPowerSource()
    }

    /// The single read-only probe used both for the initial sample and for
    /// every notification-triggered recheck.
    static func providingPowerSource() -> PowerAvailability {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue() as String?
        else { return .unknown }
        if type == kIOPSACPowerValue { return .external }
        if type == kIOPSBatteryPowerValue { return .battery }
        return .unknown
    }
}

/// One observed session transition. These are triggers only: the app re-reads
/// the source of truth it can trust and never infers eligibility from the
/// notification alone.
enum SessionChange {
    case willSleep
    case didWake
    case resignedActive
    case becameActive
    case screenLocked
    case screenUnlocked
}

/// Separately latched sleep, inactive, and lock state.
///
/// The latches preserve lock identity across wake and prevent a stale sampled
/// active snapshot from overriding a just-delivered lock or sleep notification.
/// A lock latch cannot upgrade an unknown/non-console snapshot to eligibility.
/// A latch is only cleared by its
/// matching counterpart notification (`willSleep`/`didWake`,
/// `resignedActive`/`becameActive`, `screenLocked`/`screenUnlocked`), never by
/// a snapshot read.
struct SessionGate {
    private(set) var sleeping = false
    private(set) var inactive = false
    private(set) var locked = false

    mutating func apply(_ change: SessionChange) {
        switch change {
        case .willSleep: sleeping = true
        case .didWake: sleeping = false
        case .resignedActive: inactive = true
        case .becameActive: inactive = false
        case .screenLocked: locked = true
        case .screenUnlocked: locked = false
        }
    }

    /// Resolves the effective session state. Sleep and inactive latches win
    /// over the lock latch, and all three win over the sampled snapshot; only a
    /// transition clear plus a fresh snapshot can return to `.active`.
    func resolve(snapshot: SessionState) -> SessionState {
        if sleeping { return .sleeping }
        if inactive { return .inactive }
        if locked {
            return snapshot == .active || snapshot == .locked ? .locked : snapshot
        }
        return snapshot
    }
}

/// The manual helper session as the app needs to render and reconcile it.
enum ManualState: Equatable {
    case off
    case active(expiry: String)
    case paused(expiry: String, remaining: Int)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    var expiry: String {
        switch self {
        case .off: return ""
        case .active(let value), .paused(let value, _): return value
        }
    }

    var remaining: Int? {
        if case .paused(_, let value) = self { return value }
        return nil
    }

    /// Parses the helper's status output. The first non-empty line selects the
    /// state (`ON…` / `PAUSED…` / `OFF…`); `Automatic stop:` carries the
    /// original absolute deadline in every live state (`Expires:` is the same
    /// value as an epoch). A paused timer also reports its remaining whole
    /// seconds. Unknown or empty output is `nil`, which the app treats as an
    /// unreadable status rather than guessing.
    static func parse(_ output: String) -> ManualState? {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first(where: { !$0.isEmpty }) else { return nil }
        let expiry = lines.first(where: { $0.hasPrefix("Automatic stop:") })
            .map {
                String($0.dropFirst("Automatic stop:".count))
                    .trimmingCharacters(in: .whitespaces)
            } ?? ""
        if first.hasPrefix("ON") { return .active(expiry: expiry) }
        if first.hasPrefix("PAUSED") {
            let remaining = lines.first(where: { $0.hasPrefix("Remaining:") })
                .flatMap {
                    Int(String($0.dropFirst("Remaining:".count))
                        .trimmingCharacters(in: .whitespaces))
                } ?? 0
            return .paused(expiry: expiry, remaining: remaining)
        }
        if first.hasPrefix("OFF") { return .off }
        return nil
    }

    /// The absolute epoch the helper publishes for the current record, if any.
    /// A legacy three-line record has no epoch and returns nil.
    static func epoch(from output: String) -> Double? {
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Expires:") {
                let value = String(trimmed.dropFirst("Expires:".count))
                    .trimmingCharacters(in: .whitespaces)
                return Double(value)
            }
        }
        return nil
    }

    /// The single absolute deadline a paused timer must be scheduled against.
    /// The helper's `Expires:` epoch is authoritative, so a later status read
    /// can never move the deadline. Only a record without an epoch (a legacy
    /// record) falls back to `now + remaining`.
    static func deadline(from output: String, now: Double) -> Double? {
        if let epoch = epoch(from: output) { return epoch }
        if case .paused(_, let remaining) = parse(output), remaining > 0 {
            return now + Double(remaining)
        }
        return nil
    }
}

/// UserDefaults key for the only setting v1.4 persists: the Auto awake toggle.
let autoAwakeDefaultsKey = "autoAwakeForCodex"

/// Bounded contract for the Custom hours… choice.
///
/// The menu offers whole hours only, 1 through 24, defaulting to 8. The helper
/// independently rejects any duration outside 1...86400 seconds, so an
/// out-of-range value can never start a longer session even if this parser were
/// bypassed. There is deliberately no infinite mode.
enum CustomHours {
    static let minimum = 1
    static let maximum = 24
    static let `default` = 8

    /// Accepts an exact whole-hour count within 1...24 after trimming
    /// surrounding whitespace. Rejects empty, signed, fractional, exponential,
    /// non-numeric, and out-of-range input.
    static func parse(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let value = Int(trimmed), (minimum...maximum).contains(value) else { return nil }
        return value
    }
}

/// The two places the bounded 1...24 whole-hour input is used. Only the wording
/// differs; the parser contract is shared.
enum CustomHoursPurpose {
    case background
    case display

    var heading: String {
        switch self {
        case .background: return "后台工作保持多久？"
        case .display: return "保持屏幕显示多久？"
        }
    }

    var detail: String {
        switch self {
        case .background: return "屏保与息屏照常；锁屏/睡眠时暂停。"
        case .display: return "保持显示与电脑唤醒；自动屏保会暂缓；电池供电同样可用；锁屏/睡眠时暂停，原结束时间不变。"
        }
    }
}

/// Read-only power source and energy mode, as reported by the system.
///
/// Version 1.3 adds two informational menu rows. Nothing here writes a power
/// setting: the only interaction is one read-only `system_profiler
/// SPPowerDataType -json` run plus one read-only `pmset -g custom` run at
/// launch and each time the menu opens. Values that are missing, unrecognized,
/// or mutually contradictory stay `.unavailable`, and the UI never guesses.
struct PowerStatus: Equatable {
    enum Source: String {
        case powerAdapter = "Power Adapter"
        case battery = "Battery"
        case unavailable = "Unavailable"
    }

    enum EnergyMode: String {
        case highPower = "High Power"
        case lowPower = "Low Power"
        case automatic = "Automatic"
        case unavailable = "Unavailable"
    }

    let source: Source
    let energyMode: EnergyMode

    static let unavailable = PowerStatus(source: .unavailable, energyMode: .unavailable)
}

/// Strict, side-effect-free parser for the two read-only probes.
///
/// Both probes are already-completed output; nothing here runs a command.
///
/// `system_profiler SPPowerDataType -json` is the source selector. The real
/// payload carries an `SPPowerDataType` array; the entry named
/// `sppower_information` holds `AC Power` and `Battery Power` sub-dictionaries.
/// The selection rule is deliberately narrow:
///   * the active source is the single sub-dictionary whose `Current Power
///     Source` is exactly the string `TRUE`;
///   * an absent key, a wrong type, both or neither source active, or an
///     unknown source value yields `.unavailable` rather than a guess. Charging
///     state is deliberately ignored, so a plugged-in Mac that is not charging
///     still reports `Power Adapter`.
///
/// `pmset -g custom` is the authoritative energy-mode source. Its `AC Power:`
/// and `Battery Power:` sections expose `powermode` (`0` Automatic, `1` Low
/// Power, `2` High Power). The values come from separate files on every
/// machine, never from inside the `system_profiler` payload, so the section
/// matching the selected source is split out on its own (`section(_:in:)`)
/// before it is read: a value in the other, unselected section can never be
/// consulted.
///
/// Mode precedence for a readable source:
///   * selected section present and `powermode` present: exactly one value that
///     is exactly `0`, `1`, or `2` is authoritative, even when the
///     `system_profiler` `HighPowerMode` / `LowPowerMode` flags contradict it
///     (macOS 27 reports those flags incorrectly). Any other count or value —
///     unknown, duplicate, non-numeric, malformed — is `Unavailable`, never a
///     fallback.
///   * selected section present and `powermode` absent: legacy path. Only the
///     exact profiler strings `Yes` / `No` are accepted: `Yes`/`No` → High
///     Power, `No`/`Yes` → Low Power, `No`/`No` → Automatic; a missing flag, a
///     wrong type, or any other string is `Unavailable`.
///   * `pmset` failed or the selected section is missing: the mode is
///     `Unavailable` while a valid profiler source is preserved.
enum PowerStatusParser {
    /// Maps two finished probes to a status. A non-zero `system_profiler` exit
    /// status, a failed `pmset`, or unreadable output is `Unavailable`; the
    /// parser never looks at partial output.
    static func status(
        exitStatus: Int32,
        data: Data,
        pmsetExitStatus: Int32 = 0,
        pmsetData: Data = Data()
    ) -> PowerStatus {
        guard exitStatus == 0 else { return .unavailable }
        return parse(
            json: data,
            pmsetExitStatus: pmsetExitStatus,
            pmsetData: pmsetData
        )
    }

    /// Parses the JSON payload alone (legacy fixtures with no `pmset` output).
    /// Malformed JSON is `Unavailable`.
    static func parse(json data: Data) -> PowerStatus {
        parse(json: data, pmsetExitStatus: 0, pmsetData: Data())
    }

    /// Parses both probe payloads. Malformed JSON is `Unavailable`.
    static func parse(json data: Data, pmsetExitStatus: Int32, pmsetData: Data) -> PowerStatus {
        guard
            let root = try? JSONSerialization.jsonObject(with: data),
            let info = powerInformation(in: root)
        else { return .unavailable }

        let active = ["AC Power", "Battery Power"].filter {
            ((info[$0] as? [String: Any])?["Current Power Source"] as? String) == "TRUE"
        }
        guard active.count == 1, let section = info[active[0]] as? [String: Any] else {
            return .unavailable
        }

        let source: PowerStatus.Source = active[0] == "AC Power" ? .powerAdapter : .battery
        let pmsetSection = pmsetExitStatus == 0
            ? Self.section(active == ["AC Power"] ? "AC Power" : "Battery Power", in: pmsetData)
            : nil
        return PowerStatus(
            source: source,
            energyMode: energyMode(in: section, pmsetSection: pmsetSection)
        )
    }

    /// Splits one named `pmset -g custom` section (`AC Power:` or
    /// `Battery Power:`) out of the whole command output. The section runs from
    /// its `Name:` header line to the next header line or the end of output, so
    /// a value outside it can never be read. Header matching is
    /// case-insensitive and tolerates surrounding whitespace; an absent header
    /// is `nil`.
    static func section(_ name: String, in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: .newlines)
        let headers = ["Battery Power:", "AC Power:"]
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name + ":") == .orderedSame
        }) else { return nil }
        let end = lines[(start + 1)...].firstIndex(where: {
            headers.contains($0.trimmingCharacters(in: .whitespaces))
        }) ?? lines.count
        lines = Array(lines[(start + 1)..<end])
        return lines.joined(separator: "\n")
    }

    /// How a selected `pmset` section reads. The distinction between a missing
    /// `powermode` key and an unusable one is what decides between the legacy
    /// fallback and `Unavailable`.
    private enum PmsetMode {
        case authoritative(PowerStatus.EnergyMode)
        case absent
        case invalid
    }

    /// Precedence for a readable source. A failed `pmset`, a missing selected
    /// section, or a malformed `powermode` yields `Unavailable` and never falls
    /// back; a selected section with no `powermode` key uses the strict legacy
    /// profiler flags.
    private static func energyMode(
        in legacySection: [String: Any],
        pmsetSection: String?
    ) -> PowerStatus.EnergyMode {
        guard let pmsetSection = pmsetSection else { return .unavailable }

        switch interpret(pmsetSection) {
        case .authoritative(let mode):
            return mode
        case .invalid:
            return .unavailable
        case .absent:
            return legacyEnergyMode(in: legacySection) ?? .unavailable
        }
    }

    /// Reads the single `powermode` value out of one isolated section. Exactly
    /// one value that is exactly `0`, `1`, or `2` is authoritative; several
    /// `powermode` keys, an unknown value, or a non-integer value is invalid;
    /// no `powermode` key at all is absent.
    private static func interpret(_ section: String) -> PmsetMode {
        var found: PmsetMode?
        for line in section.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.first == "powermode" else { continue }
            guard
                found == nil,
                parts.count == 2,
                let value = Int(parts[1]),
                (0...2).contains(value)
            else { return .invalid }
            found = .authoritative(
                value == 2 ? .highPower : (value == 1 ? .lowPower : .automatic)
            )
        }
        return found ?? .absent
    }

    /// Locates the `sppower_information` entry inside `SPPowerDataType`. Any
    /// other shape counts as unreadable.
    private static func powerInformation(in root: Any) -> [String: Any]? {
        guard
            let root = root as? [String: Any],
            let entries = root["SPPowerDataType"] as? [[String: Any]]
        else { return nil }
        for entry in entries where entry["_name"] as? String == "sppower_information" {
            return entry
        }
        return nil
    }

    /// Legacy mode from the profiler flags. High Power wins over Low Power.
    /// `No`/`No` is Automatic. Both flags on, a missing flag, or any value other
    /// than an exact `Yes` / `No` is unreadable.
    private static func legacyEnergyMode(in section: [String: Any]) -> PowerStatus.EnergyMode? {
        guard
            let high = section["HighPowerMode"] as? String,
            let low = section["LowPowerMode"] as? String,
            high == "Yes" || high == "No",
            low == "Yes" || low == "No"
        else { return nil }

        switch (high, low) {
        case ("Yes", "No"): return .highPower
        case ("No", "Yes"): return .lowPower
        case ("No", "No"): return .automatic
        default: return nil   // ("Yes", "Yes") cannot both be true.
        }
    }
}

/// What the Codex activity snapshot currently says about local desktop work.
///
/// `connectionNotSeen` means the snapshot is missing; `unavailable` means its
/// contents or owner cannot be verified. `idle` requires a valid snapshot with
/// no live turn open; `waiting` means at least one
/// known turn is waiting for approval and none is working; `working` means at
/// least one known turn is actively working.
enum ActivityStatus: Equatable {
    case connectionNotSeen
    case unavailable
    case idle
    case waiting
    case working
}

/// One parsed, owner-validated view of the hook receiver's snapshot.
struct ActivitySnapshot: Equatable {
    let status: ActivityStatus
    let ownerPID: Int32?
    let ownerSignature: String?
    let freshestRefresh: Double?

    static let connectionNotSeen = ActivitySnapshot(
        status: .connectionNotSeen,
        ownerPID: nil,
        ownerSignature: nil,
        freshestRefresh: nil
    )

    static let idle = ActivitySnapshot(
        status: .idle,
        ownerPID: nil,
        ownerSignature: nil,
        freshestRefresh: nil
    )

    static let unavailable = ActivitySnapshot(
        status: .unavailable,
        ownerPID: nil,
        ownerSignature: nil,
        freshestRefresh: nil
    )

    var isWorking: Bool { status == .working }
}

/// Strict, side-effect-free parser for the hook receiver's `state.json`.
///
/// Only the documented minimal fields are read. Each turn is capped at 24 hours
/// of age, so a missed Stop can never keep the Mac awake forever; a long tool
/// is never cut for lack of events, because activity is judged by turn age, not
/// by how recently an event arrived. Malformed JSON is rejected (`nil`) and the
/// app reports the snapshot as unavailable rather than guessing.
enum ActivitySnapshotParser {
    static let maximumTurnAge: Double = 24 * 60 * 60
    static let maximumClockSkew: Double = 60

    static func parse(data: Data, now: Double) -> ActivitySnapshot? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else { return nil }

        var ownerPID: Int32?
        var ownerSignature: String?
        if let owner = root["owner"] as? [String: Any] {
            if let number = owner["pid"] as? NSNumber {
                let value = number.int32Value
                ownerPID = value > 0 ? value : nil
            }
            if let start = owner["start"] as? String, !start.isEmpty {
                ownerSignature = start
            }
        }

        var working = false
        var waiting = false
        var freshest: Double?
        if let turns = root["turns"] as? [[String: Any]] {
            for turn in turns {
                guard let opened = (turn["opened"] as? NSNumber)?.doubleValue else { continue }
                let age = now - opened
                guard age <= maximumTurnAge, age >= -maximumClockSkew else { continue }
                let state = turn["state"] as? String
                guard state == "working" || state == "waiting" else { continue }
                if state == "working" { working = true } else { waiting = true }
                let refreshed = (turn["refreshed"] as? NSNumber)?.doubleValue ?? opened
                if freshest == nil || refreshed > freshest! { freshest = refreshed }
            }
        }

        return ActivitySnapshot(
            status: working ? .working : (waiting ? .waiting : .idle),
            ownerPID: ownerPID,
            ownerSignature: ownerSignature,
            freshestRefresh: freshest
        )
    }
}

/// Pure, clock-injected automatic-awake state machine.
///
/// `step(working:eligible:now:)` is fed whether any known Codex turn is actively
/// working and whether the automatic gate (toggle on, external power, active
/// session or locked with verified work) currently allows an assertion. While
/// a turn works and the gate is eligible the automatic assertion is held immediately. When no turn
/// works (all stopped, or only waiting for approval) the engine keeps the
/// assertion for a 120 second grace period and then releases it; new work
/// cancels the grace at once. The grace survives only while the gate stays
/// eligible: battery/unknown power, a lock without work, or sleep releases the
/// assertion and clears the grace immediately, and new work cannot restart it while
/// ineligible. Manual helper state is deliberately not an input: the two awake
/// sources are independent.
struct AutoAwakeEngine {
    static let graceSeconds: Double = 120
    static let assertionSeconds: Double = 300
    static let renewalSeconds: Double = 240

    var enabled: Bool = true
    private(set) var asserting: Bool = false
    private(set) var graceUntil: Double?

    /// Applies one observation and returns whether the automatic assertion
    /// should currently be held. `eligible` is the shared gate's decision and
    /// is required in addition to `enabled`; an ineligible step releases
    /// immediately, with no grace and no revival from `working`.
    mutating func step(working: Bool, eligible: Bool, now: Double) -> Bool {
        guard enabled, eligible else {
            asserting = false
            graceUntil = nil
            return false
        }
        if working {
            graceUntil = nil
            asserting = true
            return true
        }
        guard asserting else { return false }
        if let deadline = graceUntil {
            if now < deadline { return true }
        } else {
            graceUntil = now + Self.graceSeconds
            return true
        }
        asserting = false
        graceUntil = nil
        return false
    }

    /// Releases the automatic assertion (quit, or the toggle switched off).
    mutating func reset() {
        asserting = false
        graceUntil = nil
    }

    /// True when the owned assertion process may be (re)started now. A start
    /// inside the renewal window is never repeated: that is what bounds retries
    /// after a spawn failure or an early process exit to at most one per renewal
    /// period, with no polling and no tight loop.
    static func mayStart(startedAt: Double, now: Double) -> Bool {
        startedAt <= 0 || now - startedAt >= renewalSeconds
    }
}

/// Which awake sources fill the cup. Manual and automatic are independent.
enum CupState {
    static func filled(manual: Bool, automatic: Bool) -> Bool {
        manual || automatic
    }
}

/// One event-driven vnode watch on the receiver's snapshot directory.
///
/// The receiver publishes each snapshot atomically (write a hidden temp file,
/// then `rename` it over `state.json`), so a rapid burst of events produces
/// several directory writes within milliseconds. The watched path is resolved
/// immediately before every read (`resolvePath`), and the registration is
/// replaced only when that resolution actually changes — the activity folder
/// appearing or disappearing. While the path is unchanged the live descriptor
/// and source are left in place, so a publish that lands during a read is still
/// queued on the same source and delivered after the read returns. The previous
/// shape cancelled and re-opened the descriptor on every event, so a publish
/// arriving between its read and its fresh `open` was attached to a descriptor
/// that no longer existed and was simply lost until some other write or a menu
/// open happened to trigger another read. Nothing here polls: directory events
/// alone drive the reads.
final class ActivityDirectoryWatch {
    private let queue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?
    private var wantedPath: (() -> String)?
    private var read: (() -> Void)?

    /// The path currently watched, or nil before the first successful install.
    private(set) var watchedPath: String?
    /// How many descriptor/source pairs were actually created. Re-targeting to
    /// the same path is not a new registration.
    private(set) var registrations = 0

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    /// Installs the watch and its handling. `read` is only ever called after a
    /// successful install or re-target, so a publish cannot fall between the
    /// two.
    func start(resolvePath: @escaping () -> String, read: @escaping () -> Void) {
        wantedPath = resolvePath
        self.read = read
        arm()
    }

    /// Points the watch at whatever `resolvePath` returns now and keeps it
    /// otherwise. Safe to call at any time; a no-op while the path is
    /// unchanged.
    func arm() {
        guard let path = wantedPath?(), !path.isEmpty else { return }
        if source != nil, watchedPath == path { return }
        source?.cancel()   // the cancel handler closes the old descriptor
        source = nil
        watchedPath = nil
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        watchedPath = path
        registrations += 1
        let next = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        next.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Re-target first (a no-op unless the activity folder appeared or
            // disappeared), then read the latest snapshot: a publish before the
            // read is seen by the read, one after it by the live registration.
            self.arm()
            self.read?()
        }
        next.setCancelHandler { close(descriptor) }
        next.resume()
        source = next
    }
}

/// User-facing presentation only; this never changes an awake decision.
struct MenuPresentation {
    let heading: String
    let timing: String
    let effect: String
    let note: String

    /// An until-stopped display request has no deadline at all, so its row shows
    /// this stable state instead of a fabricated countdown or end time.
    static let untilStoppedTiming = "直到我关闭"

    var compactSummary: String {
        // Closed-menu tooltips use the fixed end time, never a stale countdown.
        let end = timing.components(separatedBy: " · ").last ?? ""
        return [heading, end, effect].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func timing(deadline: Double?, now: Double) -> String {
        guard let deadline = deadline else { return "结束时间暂时无法读取" }
        let remaining = max(0, Int(ceil(deadline - now)))
        let clock = remaining >= 3600
            ? String(format: "%d:%02d:%02d", remaining / 3600, remaining / 60 % 60, remaining % 60)
            : String(format: "%02d:%02d", remaining / 60, remaining % 60)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "剩余 \(clock) · \(formatter.string(from: Date(timeIntervalSince1970: deadline))) 结束"
    }
}

/// A read-only native status card. Live clocks retitle its labels in place,
/// leaving menu actions stable while the user is selecting an item.
final class WorkMenuStatusView: NSView {
    let heading = NSTextField(labelWithString: "")
    let timing = NSTextField(labelWithString: "")
    let effect = NSTextField(labelWithString: "")
    let note = NSTextField(labelWithString: "")

    init(_ presentation: MenuPresentation) {
        let detailed = !presentation.timing.isEmpty || !presentation.note.isEmpty
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: detailed ? 100 : 62))
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.textColor = .labelColor
        timing.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        timing.textColor = .labelColor
        effect.font = .systemFont(ofSize: 12)
        effect.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11.5)
        note.textColor = .secondaryLabelColor
        for label in [heading, timing, effect, note] {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        heading.frame = NSRect(x: 16, y: detailed ? 75 : 35, width: 308, height: 21)
        timing.frame = NSRect(x: 16, y: 53, width: 308, height: 19)
        effect.frame = NSRect(x: 16, y: detailed ? 31 : 12, width: 308, height: 19)
        note.frame = NSRect(x: 16, y: 10, width: 308, height: 18)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        update(presentation)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic native menu view") }

    func update(_ presentation: MenuPresentation) {
        heading.stringValue = presentation.heading
        timing.stringValue = presentation.timing
        effect.stringValue = presentation.effect
        note.stringValue = presentation.note
        timing.isHidden = presentation.timing.isEmpty
        note.isHidden = presentation.note.isEmpty
        setAccessibilityLabel(presentation.heading)
        setAccessibilityChildren([heading, timing, effect, note].filter { !$0.isHidden })
    }
}

/// An explicit, memory-only display request. It shares the session gate and
/// logger with ordinary timers, but additionally holds display idle sleep.
///
/// Two shapes are supported, and both are memory-only (an app restart never
/// restores a display request):
///   * a finite request with one absolute deadline, covered by a single bounded
///     `-d -i -t <remaining> -w <app pid>` child whose timeout is at most the
///     helper's own 86400 second limit; and
///   * an until-stopped request, which is a distinct state with no deadline at
///     all, covered by bounded owner-tied `-t 300` leases renewed every 240
///     seconds so a hung app can never leave a stray indefinite child behind.
///
/// The finite deadline survives pauses unchanged and never revives after
/// expiry or cancellation. An until-stopped request pauses and resumes while it
/// remains configured, and a late callback from a released or replaced child can
/// never revive or cancel the request now in force.
///
/// Every transition a running child ends on is published through `onChange`
/// with an observation of the state that actually holds afterwards, so the
/// status item and menu can never claim an active display hold that no child is
/// covering. An until-stopped request that loses its lease keeps the request
/// and defers exactly one bounded retry to the renewal boundary, and it reports
/// that released state rather than a session pause. A start that never
/// succeeded is never described as if it had produced a hold: a failed initial
/// spawn clears the request outright, like the finite shape already does. All
/// elapsed lease arithmetic uses `now()`, the same injected clock the tests
/// drive, so a deterministic test clock can never re-fire a timer from unrelated
/// wall time.
final class GUIWorkTimer {
    /// Shared with the helper's own 1...86400 second duration limit, so a whole
    /// hour request can never exceed the bound a child is allowed to assert.
    static let minimumSeconds = 1
    static let maximumSeconds = 86400
    /// Every until-stopped child is one bounded, owner-tied lease.
    static let leaseSeconds = 300
    static let renewalSeconds: Double = 240

    let diagnostics: DiagnosticLog
    var onChange: (() -> Void)?
    var now: () -> Double = { Date().timeIntervalSince1970 }
    // Isolated tests can substitute a harmless process; production uses only
    // the system caffeinate executable with the exact bounded arguments.
    var makeProcess: ([String]) -> Process = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = arguments
        return process
    }
    /// The finite deadline. `nil` for an until-stopped request and when off.
    private(set) var deadline: Double?
    /// True while an until-stopped request is configured. It has no deadline.
    private(set) var untilStopped = false
    private(set) var process: Process?
    private var expiryTimer: DispatchSourceTimer?
    private var leaseTimer: DispatchSourceTimer?
    private var leaseStartedAt: Double = 0
    /// True once one lease has actually started running. A start failure before
    /// that point is an initial failure and clears the request; only a request
    /// that had a working lease keeps a bounded retry after its lease is lost.
    private var leaseEverStarted = false
    /// The next instant a lease event is due: the renewal of a running lease, or
    /// the single bounded retry after a lost one. `0` means nothing is scheduled
    /// yet (off, released for an ineligible session), while a future instant
    /// always names a renewal or retry that is really pending. One absolute
    /// anchor, so a cleared or pending retry can never be confused with a
    /// renewal.
    private var leaseRenewsAt = Double(0)
    /// Last eligibility the shared session gate published. A scheduled renewal
    /// reuses it instead of assuming the session is still eligible, so a
    /// transition that raced the timer can never restart a display lease while
    /// the session is locked, asleep, inactive, or unknown.
    private var lastEligible = true

    var configured: Bool { deadline != nil || untilStopped }
    var held: Bool { process?.isRunning == true }
    /// An eligible until-stopped request whose owned lease already ended and
    /// whose one bounded retry is still in the future. The card must report this
    /// as a released display hold with a pending retry, never as a session pause
    /// or a live hold, and never as a promise that unlocking alone restores it.
    var awaitingLeaseRetry: Bool {
        untilStopped && process == nil && lastEligible && now() < leaseRenewsAt
    }

    init(diagnostics: DiagnosticLog) { self.diagnostics = diagnostics }

    @discardableResult
    func start(seconds: Int, eligible: Bool) -> Bool {
        guard !configured, eligible,
              (Self.minimumSeconds...Self.maximumSeconds).contains(seconds) else {
            diagnostics.record("gui_start_rejected", fields: ["reason": "duration_or_session_ineligible"])
            return false
        }
        deadline = now() + Double(seconds)
        untilStopped = false
        diagnostics.record("gui_timer_started", fields: ["expires": deadline!, "mode": "display_and_idle_sleep"])
        scheduleExpiry(seconds: seconds)
        reconcile(eligible: true)
        return held
    }

    /// Starts an until-stopped display request. It has no deadline and is
    /// distinguished from both an off state and a finite request everywhere it
    /// is rendered or reconciled.
    @discardableResult
    func startUntilStopped(eligible: Bool) -> Bool {
        guard !configured, eligible else {
            diagnostics.record("gui_start_rejected", fields: ["reason": "until_stopped_or_session_ineligible"])
            return false
        }
        deadline = nil
        untilStopped = true
        leaseStartedAt = 0
        // No lease event is scheduled yet, so the first reconcile starts the
        // first lease immediately instead of waiting for a renewal instant.
        leaseRenewsAt = 0
        leaseEverStarted = false
        diagnostics.record("gui_timer_started", fields: ["mode": "display_until_stopped"])
        reconcile(eligible: true)
        // A failed initial spawn has already cleared the request and published
        // that failure, so the caller must not report a started hold.
        return configured ? held : false
    }

    func reconcile(eligible: Bool) {
        lastEligible = eligible
        guard configured else { return }
        if let deadline = deadline, now() >= deadline {
            stop(reason: "deadline_reached")
            return
        }
        if !eligible {
            // A pause keeps the request (and, for a finite request, its original
            // deadline) but releases the owned child. The renewal/retry anchor
            // is cleared so a resume starts a fresh lease immediately and the
            // paused state is never misreported as a pending retry.
            release(reason: "session_ineligible")
            leaseRenewsAt = 0
            leaseTimer?.cancel()
            leaseTimer = nil
        } else if untilStopped {
            ensureLease()
        } else {
            ensureFiniteChild()
        }
        // A finite unexpected exit ends the request inside ensureFiniteChild and
        // stop() has already published that transition; do not add a stale
        // "paused" observation afterwards.
        guard configured else { return }
        diagnostics.observation("gui_observation", fields: ["held": String(held),
                                "status": held ? "holding" : "paused",
                                "expires": deadline.map { String($0) } ?? (untilStopped ? "until_stopped" : "none")])
        onChange?()
    }

    /// One bounded child covers the whole remaining finite interval. An
    /// unexpected exit ends the finite request; it is never silently re-armed.
    private func ensureFiniteChild() {
        guard let deadline = deadline else { return }
        if let process = process {
            if !process.isRunning { processExited(process) }
            return
        }
        let remaining = max(Self.minimumSeconds, min(Self.maximumSeconds, Int(ceil(deadline - now()))))
        let next = makeProcess(["-d", "-i", "-t", String(remaining),
                                "-w", String(ProcessInfo.processInfo.processIdentifier)])
        next.standardOutput = FileHandle.nullDevice
        next.standardError = FileHandle.nullDevice
        next.terminationHandler = { [weak self, weak next] _ in
            DispatchQueue.main.async {
                guard let next = next else { return }
                self?.processExited(next)
            }
        }
        do {
            try next.run()
            process = next
            diagnostics.record("gui_assertion_started", fields: ["pid": next.processIdentifier,
                               "expires": deadline, "reason": "bounded_display_and_idle_sleep"])
        } catch {
            diagnostics.record("gui_assertion_start_failed", fields: ["error_code": (error as NSError).code])
            stop(reason: "start_failed")
        }
    }

    /// Keeps exactly one bounded, owner-tied display lease covering an
    /// until-stopped request, renewing it before the 300 second bound expires.
    /// A lost lease keeps the request but defers one bounded retry to the
    /// renewal boundary, so there is no tight loop and no duplicate child.
    private func ensureLease() {
        if let process = process, process.isRunning {
            if now() < leaseRenewsAt {
                scheduleLeaseRenewal(at: leaseRenewsAt)
                return
            }
            release(reason: "lease_renewal")
            startLease()
            return
        }
        if let process = process {
            // The lease is gone. handleLeaseExit publishes the released state,
            // so the menu and icon never keep claiming a hold that ended.
            handleLeaseExit(process)
            return
        }
        guard now() < leaseRenewsAt else {
            // A renewal or retry instant has arrived; start (or replace) the one
            // bounded lease now and re-anchor the next renewal from it.
            startLease()
            return
        }
        scheduleLeaseRenewal(at: leaseRenewsAt)
    }

    private func startLease() {
        let next = makeProcess(["-d", "-i", "-t", String(Self.leaseSeconds),
                                "-w", String(ProcessInfo.processInfo.processIdentifier)])
        next.standardOutput = FileHandle.nullDevice
        next.standardError = FileHandle.nullDevice
        next.terminationHandler = { [weak self, weak next] _ in
            DispatchQueue.main.async {
                guard let next = next else { return }
                self?.handleLeaseExit(next)
            }
        }
        do {
            try next.run()
            process = next
            leaseStartedAt = now()
            leaseEverStarted = true
            diagnostics.record("gui_assertion_started", fields: ["pid": next.processIdentifier,
                               "reason": "bounded_display_lease"])
            // Re-anchor before scheduling: the renewal instant is what the timer
            // and `ensureLease` both read, so it must already be in the future.
            leaseRenewsAt = leaseStartedAt + Self.renewalSeconds
            scheduleLeaseRenewal(at: leaseRenewsAt)
        } catch {
            diagnostics.record("gui_assertion_start_failed", fields: ["error_code": (error as NSError).code])
            process = nil
            guard leaseEverStarted else {
                // The very first lease never ran. Never leave a configured
                // request with no effective child waiting to arm a future hold:
                // clear it exactly as the finite shape does and publish it.
                stop(reason: "start_failed")
                return
            }
            // A renewal-spawn failure keeps the bounded request alive but is
            // reported truthfully: one retry at the next renewal boundary.
            leaseRenewsAt = now() + Self.renewalSeconds
            scheduleLeaseRenewal(at: leaseRenewsAt)
            diagnostics.observation("gui_observation", fields: ["held": "false",
                                   "status": "lease_start_failed",
                                   "expires": "until_stopped"])
            onChange?()
        }
    }

    /// Handles an owned until-stopped lease ending on its own. A stale
    /// notification from a lease this class already released or replaced is
    /// ignored, and the retry is bounded to the next renewal boundary. The
    /// released state is published here too: otherwise the icon and menu would
    /// keep claiming an active display hold until some unrelated refresh.
    private func handleLeaseExit(_ ended: Process) {
        guard let current = process, current === ended else { return }
        diagnostics.record("gui_assertion_exited", fields: ["pid": ended.processIdentifier,
                           "exit_code": ended.terminationStatus])
        clearDeadLease(current)
        leaseRenewsAt = now() + Self.renewalSeconds
        scheduleLeaseRenewal(at: leaseRenewsAt)
        reconcile(eligible: lastEligible)
    }

    private func processExited(_ ended: Process) {
        guard let current = process, current === ended else { return }
        diagnostics.record("gui_assertion_exited", fields: ["pid": ended.processIdentifier,
                           "exit_code": ended.terminationStatus])
        // An unexpected finite exit ends the request. Never silently re-arm it.
        stop(reason: now() >= (deadline ?? 0) ? "deadline_reached" : "process_exited")
    }

    private func scheduleExpiry(seconds: Int) {
        expiryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Double(seconds))
        timer.setEventHandler { [weak self] in self?.stop(reason: "deadline_reached") }
        timer.resume()
        expiryTimer = timer
    }

    /// Re-arms from the absolute renewal/retry instant, never from a relative
    /// delay a later read could extend. One-shot and event driven: nothing polls.
    /// The delay is measured with `now()`, the same clock every lease decision
    /// uses, so an injected deterministic test clock never disagrees with the
    /// timer and can never re-fire it against unrelated wall time. A zero delay
    /// stays one hop away instead of re-entering the event handler directly.
    private func scheduleLeaseRenewal(at instant: Double) {
        leaseTimer?.cancel()
        let delay = max(0, instant - now())
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // This one-shot timer has fired; a later reconcile re-arms it.
            self.leaseTimer = nil
            self.reconcile(eligible: self.lastEligible)
        }
        timer.resume()
        leaseTimer = delay > 0 ? timer : nil
    }

    /// Releases only the owned child. The termination handler is detached
    /// first, so a deliberate stop can never be mistaken for an unexpected exit
    /// and revive a cancelled or replaced request.
    private func release(reason: String) {
        guard let current = process else { return }
        process = nil
        current.terminationHandler = nil
        diagnostics.record("gui_assertion_released", fields: ["pid": current.processIdentifier,
                           "reason": reason,
                           "expires": deadline.map { String($0) } ?? (untilStopped ? "until_stopped" : "none")])
        if current.isRunning { current.terminate() }
    }

    /// Drops an owned child that already ended by itself. Unlike a deliberate
    /// release it never sends a signal; it only detaches the identity so no
    /// later callback from it can touch a newer request.
    private func clearDeadLease(_ ended: Process) {
        process = nil
        ended.terminationHandler = nil
    }

    func stop(reason: String) {
        let previousDeadline = deadline
        let wasUntilStopped = untilStopped
        release(reason: reason)
        deadline = nil
        untilStopped = false
        leaseStartedAt = 0
        leaseRenewsAt = 0
        leaseEverStarted = false
        expiryTimer?.cancel()
        expiryTimer = nil
        leaseTimer?.cancel()
        leaseTimer = nil
        if previousDeadline != nil || wasUntilStopped {
            diagnostics.record("gui_timer_ended", fields: ["reason": reason,
                               "expires": previousDeadline.map { String($0) } ?? "until_stopped"])
        }
        onChange?()
    }
}

final class WorkModeApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Installed helper location. The install step, not this app, owns the file.
    /// `var` so an isolated test can point at a private root; production never
    /// reassigns it.
    var folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Codex Work Mode")
    lazy var diagnostics = DiagnosticLog(directory: folder.appendingPathComponent("diagnostics"))
    lazy var guiTimer = GUIWorkTimer(diagnostics: diagnostics)
    let queue = DispatchQueue(label: "local.plan.codex-work-mode.commands")
    /// Separate serial queue for the read-only power probe, so a slow
    /// system_profiler run can never delay a start/stop helper action.
    let powerQueue = DispatchQueue(label: "local.plan.codex-work-mode.power")

    var item: NSStatusItem!
    var statusCard: WorkMenuStatusView?
    var statusHeadingItem: NSMenuItem?
    /// Read-only manual/background row shown beside the display card when an
    /// explicit display request owns the card but the manual timer is also
    /// configured. Retitled in place by the presentation clock.
    var backgroundStatusItem: NSMenuItem?
    var menuClock: Timer?
    /// Last known manual helper state (only replaced by a successful status
    /// read). `active`/`pausedManual`/`expiry` are views of it.
    var manualState: ManualState = .off
    var statusReadable = false  // whether the last status read succeeded
    var busy = false            // an action is in flight; blocks reentrant state changes
    var alertVisible = false

    var active: Bool { manualState.isActive }
    var pausedManual: Bool { manualState.isPaused }
    var expiry: String { manualState.expiry }

    // Shared session/power gate (v1.5). The QA harness substitutes the two
    // adapter initializers below with fixture implementations of the same
    // protocols; the production defaults read the real login session and the
    // real IOKit power source.
    var sessionProvider: SessionProviding = SessionSampler()
    var powerMonitor: PowerSourceProviding = PowerSourceMonitor()
    var sessionGate = SessionGate()
    var sessionSnapshot: SessionState = .unknown
    var sessionState: SessionState = .unknown
    var powerAvailability: PowerAvailability = .unknown
    var manualExpiryTimer: DispatchSourceTimer?
    var manualExpiryDeadline: Double?
    /// Set after a failed suspend/resume attempt so the same event cannot spin
    /// on the helper; cleared by the next session/power event or menu open.
    var reconcileBlocked = false
    /// Set when a session/power event asked for reconciliation while a helper
    /// command was already in flight, so the newest gate state is applied as
    /// soon as that command finishes instead of being lost.
    var reconcilePending = false

    // Read-only power status. `powerStatus` is nil while a read is in flight or
    // has not started yet, which the rows render as "Loading…".
    var powerStatus: PowerStatus?
    var powerReadInFlight = false
    var powerSourceItem: NSMenuItem?
    var energyModeItem: NSMenuItem?

    var directorySource: DispatchSourceFileSystemObject?
    var processSource: DispatchSourceProcess?
    var observedPID: pid_t?
    var watchFD: Int32 = -1

    // MARK: - Automatic awake for local Codex desktop work (v1.4)

    /// The hook receiver's own directory inside this app's support folder. The
    /// app only ever reads `state.json` here; the hook owns all writes.
    var activityFolder: URL { folder.appendingPathComponent("codex-activity") }
    var activityStateFile: URL { activityFolder.appendingPathComponent("state.json") }

    /// Auto awake toggle. Default on for the requested feature; this is the only
    /// setting v1.4 persists.
    var autoEnabled: Bool = (UserDefaults.standard.object(forKey: autoAwakeDefaultsKey) as? Bool) ?? true
    var autoEngine = AutoAwakeEngine()
    var activityStatus: ActivityStatus = .connectionNotSeen

    var autoProcess: Process?
    var autoStartedAt: Double = 0
    /// Effective, process-backed automatic assertion state. This is distinct
    /// from `autoEngine.asserting`, which is only the intent. The cup, the
    /// overall status line, and the Details explanation use this effective
    /// value, so a failed spawn or an early exit is never reported as held.
    var autoHeld = false
    var renewTimer: DispatchSourceTimer?
    var graceTimer: DispatchSourceTimer?
    var activityWatch = ActivityDirectoryWatch()
    var autoOwnerSource: DispatchSourceProcess?
    var autoOwnerPID: pid_t?

    // MARK: - Installed helper

    /// Test seam: when set, stands in for the installed helper so an isolated
    /// behavioral test can delay a suspend/resume deterministically. Production
    /// always leaves this nil and runs the real helper below.
    var helperInvocationOverride: ((String, Int, Bool) -> (Int32, String))?

    /// Runs the installed helper. Returns (exit status, combined output).
    /// `paused` asks `on` to create the timer without starting any caffeinate
    /// process, which is how a new request made while the session is ineligible
    /// avoids even a momentary awake assertion. The app never writes the helper
    /// state file itself; every state change goes through this one entry point.
    func invoke(_ mode: String, seconds: Int = 28800, paused: Bool = false) -> (Int32, String) {
        if let override = helperInvocationOverride {
            return override(mode, seconds, paused)
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        var arguments = [folder.appendingPathComponent("toggle.zsh").path, mode, String(seconds)]
        if paused { arguments.append("paused") }
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (1, error.localizedDescription)
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        diagnostics.record("app_started", fields: ["version": "1.8", "pid": ProcessInfo.processInfo.processIdentifier])

        // The status item exists before any observer can fire, so a
        // notification delivered during launch can never reach the menu code
        // with no item installed.
        item = NSStatusBar.system.statusItem(withLength: 24)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        guiTimer.onChange = { [weak self] in
            self?.updateStatusItem()
            self?.rebuildMenu()
        }

        // Observers and the IOKit power source are installed BEFORE the first
        // snapshot, so a lock/sleep/power transition landing during launch is
        // never lost between the read and the registration.
        registerSessionObservers()
        powerMonitor.onChange = { [weak self] in self?.handlePowerChange() }
        powerMonitor.start()
        powerAvailability = powerMonitor.availability
        sessionSnapshot = sessionProvider.sample()
        sessionState = sessionGate.resolve(snapshot: sessionSnapshot)

        // Reconcile the manual session (suspend if the session is not eligible)
        // before the automatic assertion is evaluated.
        refresh()
        requestPowerStatusRead()

        watchFD = open(folder.path, O_EVTONLY)
        if watchFD >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: watchFD,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.refresh() }
            let fd = watchFD
            source.setCancelHandler { close(fd) }
            source.resume()
            directorySource = source
        }

        // Recover still-valid current activity on reopening and watch the
        // receiver's own snapshot directory. The watch is installed BEFORE the
        // first read, so a snapshot published around that read is seen either
        // by the read or by the live watch. No Codex file is polled.
        activityWatch.start(
            resolvePath: { [weak self] in
                guard let self = self else { return "" }
                return FileManager.default.fileExists(atPath: self.activityFolder.path)
                    ? self.activityFolder.path
                    : self.folder.path
            },
            read: { [weak self] in self?.refreshActivity() }
        )
        refreshActivity()

        revealMenu()
    }

    // MARK: - Session and power gate (v1.5)

    /// Registers the session, sleep, wake, lock, and unlock observers. Every
    /// notification is only a trigger: the handler latches the transition and
    /// re-reads what it can trust before changing any assertion.
    func registerSessionObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceChanges: [(Notification.Name, SessionChange)] = [
            (NSWorkspace.willSleepNotification, .willSleep),
            (NSWorkspace.didWakeNotification, .didWake),
            (NSWorkspace.sessionDidResignActiveNotification, .resignedActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .becameActive),
        ]
        for (name, event) in [(NSWorkspace.screensDidSleepNotification, "display_off"),
                              (NSWorkspace.screensDidWakeNotification, "display_on")] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Diagnostic only: display changes never enter the awake gate.
                self?.diagnostics.record(event)
            }
        }
        for (name, change) in workspaceChanges {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleSessionChange(change)
            }
        }
        let distributed = DistributedNotificationCenter.default()
        // A received system notification is not proof of rendered animation
        // or a lock cause. These best-effort observations never enter the gate.
        for (name, event) in [("com.apple.screensaver.didstart", "screensaver_started_notification"),
                              ("com.apple.screensaver.didstop", "screensaver_stopped_notification")] {
            distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.diagnostics.record(event)
            }
        }
        let screenLocked = Notification.Name("com.apple.screenIsLocked")
        let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")
        distributed.addObserver(forName: screenLocked, object: nil, queue: .main) { [weak self] _ in
            self?.handleSessionChange(.screenLocked)
        }
        distributed.addObserver(forName: screenUnlocked, object: nil, queue: .main) { [weak self] _ in
            self?.handleSessionChange(.screenUnlocked)
        }
    }

    /// Re-reads the session snapshot when the transition makes that meaningful
    /// and recomputes the effective state through the latches. Lock and sleep
    /// deliberately do NOT re-sample: the latch is authoritative, so a stale
    /// snapshot cannot claim the session is still active.
    func refreshSessionState(recheckSnapshot: Bool) {
        if recheckSnapshot {
            sessionSnapshot = sessionProvider.sample()
        }
        sessionState = sessionGate.resolve(snapshot: sessionSnapshot)
    }

    func handleSessionChange(_ change: SessionChange) {
        sessionGate.apply(change)
        reconcileBlocked = false
        switch change {
        case .willSleep, .resignedActive, .screenLocked:
            refreshSessionState(recheckSnapshot: false)
        case .didWake, .becameActive, .screenUnlocked:
            refreshSessionState(recheckSnapshot: true)
            // A resume decision re-reads the current power source too, so a
            // wake on battery can never resume automatic awake.
            powerMonitor.sample()
            powerAvailability = powerMonitor.availability
        }
        diagnostics.record("session_event", fields: ["reason": String(describing: change),
                           "session": String(describing: sessionState), "power": String(describing: powerAvailability)])
        guiTimer.reconcile(eligible: AwakeGate.sessionAllowsAssertion(sessionState))
        reconcileManualSession()
        refreshActivity()
    }

    func handlePowerChange() {
        powerAvailability = powerMonitor.availability
        reconcileBlocked = false
        // A power change is also a cheap, bounded trigger to recheck the
        // session; the latches still win over the sampled snapshot.
        refreshSessionState(recheckSnapshot: true)
        diagnostics.record("power_event", fields: ["power": String(describing: powerAvailability),
                           "session": String(describing: sessionState)])
        guiTimer.reconcile(eligible: AwakeGate.sessionAllowsAssertion(sessionState))
        reconcileManualSession()
        refreshActivity()
    }

    /// Re-reads the current session snapshot and resolves it through the
    /// latches. Used before any start/resume decision so a transition that
    /// arrived while a helper command was in flight is never acted on with a
    /// stale reading.
    func refreshSessionNow() {
        sessionSnapshot = sessionProvider.sample()
        sessionState = sessionGate.resolve(snapshot: sessionSnapshot)
    }

    /// Keeps the manual helper session consistent with the shared gate. The app
    /// decides; the helper performs the transition through its own entry point
    /// (the app never writes the state file).
    ///
    /// A request that arrives while a command is already in flight is recorded
    /// as pending instead of being dropped, so a lock during a resume and an
    /// unlock during a suspend both settle on the newest gate state once the
    /// command returns.
    func reconcileManualSession() {
        guard !reconcileBlocked else { return }
        if busy {
            reconcilePending = true
            return
        }
        if manualState.isActive && !AwakeGate.sessionAllowsAssertion(sessionState) {
            runHelperTransition("suspend")
        } else if manualState.isPaused {
            // Resume only after re-reading the CURRENT session; the helper then
            // uses only the remaining whole seconds, so the deadline never
            // extends.
            refreshSessionNow()
            if AwakeGate.sessionAllowsAssertion(sessionState) {
                runHelperTransition("resume")
            }
        }
    }

    /// Runs one suspend/resume transition and re-reads the helper status. A
    /// failure is surfaced once and blocks further automatic retries until the
    /// next session/power event or menu open. A reconciliation request that
    /// arrived mid-command is applied against the refreshed state afterwards.
    func runHelperTransition(_ mode: String) {
        guard !busy else { return }
        busy = true
        rebuildMenu()
        queue.async { [self] in
            let result = invoke(mode)
            diagnostics.record("manual_transition", fields: ["mode": mode, "exit_code": result.0])
            DispatchQueue.main.async { [self] in
                busy = false
                refresh(reconcile: false)
                let pending = reconcilePending
                reconcilePending = false
                if result.0 != 0 {
                    reconcileBlocked = true
                    presentFailure(result.1)
                } else if pending {
                    reconcileManualSession()
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // There is no window to bring forward: reveal the menu so the user can
        // find the small status item.
        revealMenu()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop on quit: never leave an owned bounded session running behind us.
        // Release the automatic assertion first; `off` cancels an active or
        // paused manual session exactly as before.
        diagnostics.record("app_quit")
        menuClock?.invalidate()
        menuClock = nil
        guiTimer.stop(reason: "app_quit")
        releaseAutoAwake(reason: "app_quit")
        manualExpiryTimer?.cancel()
        manualExpiryTimer = nil
        _ = invoke("off")
    }

    /// Makes the menu bar item discoverable on launch or reopen without a window.
    func revealMenu() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        // The button may not be installed in the status bar yet during launch, so
        // defer one main-queue hop before asking it to open its menu.
        DispatchQueue.main.async { [weak self] in
            self?.item.button?.performClick(nil)
        }
    }

    // MARK: - State

    /// The compact status card. An explicit display request owns the card when
    /// one is configured; the manual background timer then keeps its own
    /// read-only row below, so neither source can hide the other. The note also
    /// names an active automatic hold, so the card never implies the Mac would
    /// sleep while another owned source is holding it.
    func menuPresentation(now: Double = Date().timeIntervalSince1970) -> MenuPresentation {
        if guiTimer.configured {
            let retrying = guiTimer.awaitingLeaseRetry
            var note: String
            if guiTimer.held {
                note = "结束后，系统可能立即屏保或息屏"
            } else if retrying {
                // No child covers the request right now. Say exactly that: it is
                // not a lock/session pause, and unlocking alone would not explain
                // it — the app retries once at the next renewal boundary.
                note = "显示保持暂时未生效，稍后会自动重试一次；锁屏/睡眠会暂停"
            } else if guiTimer.untilStopped {
                note = "解除暂停后重新开始保持，直到我关闭"
            } else {
                note = "恢复后只继续剩余时间，不重新计时"
            }
            if autoHeld { note += " · 后台自动保持中" }
            return MenuPresentation(heading: guiTimer.held ? "屏幕显示保持中" : "屏幕显示已暂停",
                timing: guiTimer.untilStopped
                    ? MenuPresentation.untilStoppedTiming
                    : MenuPresentation.timing(deadline: guiTimer.deadline, now: now),
                effect: guiTimer.held
                    ? "保持显示 · 自动屏保暂缓"
                    : (guiTimer.untilStopped
                        ? (retrying ? "显示保持已释放 · 正在重试" : "显示保持已释放 · 直到我关闭")
                        : "显示保持已释放 · 原结束时间不变"),
                note: note)
        }
        guard statusReadable else {
            return MenuPresentation(heading: "计时状态暂时无法确认", timing: "",
                effect: autoHeld ? "后台自动保持中 · 不保持显示" : "请在更多状态中查看详情", note: "")
        }
        if active || pausedManual {
            return MenuPresentation(heading: active ? "后台计时中" : "后台计时已暂停",
                timing: MenuPresentation.timing(deadline: manualExpiryDeadline, now: now),
                effect: active ? "仅保持电脑唤醒 · 屏保与息屏照常" : "保持已暂停 · 不保持显示",
                note: "锁屏/睡眠时暂停，恢复不延长计时")
        }
        return MenuPresentation(heading: autoHeld ? "后台自动保持中" : "正常待机", timing: "",
            effect: autoHeld ? "仅保持电脑唤醒 · 屏保与息屏照常" : "屏保与息屏按系统设置", note: "")
    }

    func updateMenuClock() {
        let presentation = menuPresentation()
        statusCard?.update(presentation)
        if statusHeadingItem?.title != presentation.heading { statusHeadingItem?.title = presentation.heading }
        backgroundStatusItem?.title = backgroundMenuLine
    }

    func startMenuClock() {
        menuClock?.invalidate()
        menuClock = nil
        // A presentation-only clock runs while the menu is open and some visible
        // value actually changes: a finite display countdown or a manual
        // countdown. An until-stopped row is a stable state, so it alone does
        // not start one. No session, power, helper or task polling.
        guard (guiTimer.configured && !guiTimer.untilStopped) || active || pausedManual else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateMenuClock() }
        RunLoop.main.add(timer, forMode: .common)
        menuClock = timer
    }

    var stateLine: String {
        guard statusReadable else { return "Codex Work Mode: status unavailable" }
        switch manualState {
        case .off:
            return "Normal sleep"
        case .active(let expiry):
            return expiry.isEmpty ? "Awake" : "Awake until \(WorkModeApp.shortTime(expiry))"
        case .paused(let expiry, _):
            return expiry.isEmpty
                ? "Timer paused"
                : "Timer paused — until \(WorkModeApp.shortTime(expiry))"
        }
    }

    /// The helper prints a full absolute time; the compact menus only have room
    /// for the clock portion.
    static func shortTime(_ expiry: String) -> String {
        expiry.split(separator: " ").dropFirst().first.map(String.init) ?? expiry
    }

    /// Overall display-hold status in English, used by the compact summary
    /// helpers. An until-stopped request is reported as such and never invents
    /// an end time.
    var displayStatusLine: String {
        if guiTimer.untilStopped {
            return guiTimer.held ? "Screen display until stopped — display on"
                                 : "Screen display paused — until stopped"
        }
        guard let deadline = guiTimer.deadline else { return "Screen display off" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let end = formatter.string(from: Date(timeIntervalSince1970: deadline))
        return guiTimer.held ? "Screen display until \(end) — display on"
                             : "Screen display paused — ends at \(end)"
    }

    /// Read-only manual/background status row for the compact menu when an
    /// explicit display request owns the status card. It is truthful about a
    /// paused timer and keeps the helper's original end time visible.
    var backgroundMenuLine: String {
        guard active || pausedManual else {
            return autoHeld ? "后台自动保持中" : "后台计时：未开启"
        }
        let timing = MenuPresentation.timing(deadline: manualExpiryDeadline,
                                             now: Date().timeIntervalSince1970)
        return (pausedManual ? "后台计时已暂停 · " : "后台计时中 · ") + timing
    }

    /// The display stop row never claims to restore normal sleep while another
    /// owned source is still holding the Mac awake.
    var displayStopTitle: String {
        let backgroundHeld = active || pausedManual || autoHeld
        return backgroundHeld ? "结束屏幕显示保持（后台仍保持唤醒）"
                              : "结束屏幕显示保持，恢复屏保/息屏"
    }

    var stateSummary: String {
        if guiTimer.configured { return displayStatusLine }
        switch manualState {
        case .active:
            return expiry.isEmpty ? "awake" : "awake until \(expiry)"
        case .paused:
            return expiry.isEmpty ? "timer paused" : "timer paused until \(expiry)"
        case .off:
            break
        }
        guard statusReadable else {
            return autoHeld ? "auto awake; helper status unavailable" : "status unavailable"
        }
        return autoHeld ? "auto awake" : "off, normal sleep applies"
    }

    /// Overall menu status. A manual session keeps its own line, including the
    /// helper's original end time; a paused manual timer keeps that same line so
    /// the deadline stays visible and is clearly marked paused. With no manual
    /// session an active automatic assertion is named explicitly, so the row
    /// never claims normal sleep while the owned automatic caffeinate process is
    /// holding the Mac awake.
    static func menuStatus(
        manualActive: Bool,
        manualPaused: Bool,
        manualLine: String,
        automatic: Bool
    ) -> String {
        if manualActive || manualPaused { return manualLine }
        return automatic ? "Automatic awake" : manualLine
    }

    var overallStatusLine: String {
        if guiTimer.configured { return displayStatusLine }
        return WorkModeApp.menuStatus(
            manualActive: active,
            manualPaused: pausedManual,
            manualLine: stateLine,
            automatic: autoHeld
        )
    }

    /// Reads the installed helper's state and republishes the item, menu, and
    /// watchers. `reconcile` is false for the completion of a suspend/resume
    /// transition, so a just-applied transition cannot re-trigger itself.
    func refresh(reconcile: Bool = true) {
        guard !busy else { return }
        let now = Date().timeIntervalSince1970
        let result = invoke("status")
        if result.0 == 0, let parsed = ManualState.parse(result.1) {
            statusReadable = true
            manualState = parsed
            // Schedule against the absolute deadline the helper published, so
            // repeated status reads can never push the timer later. A legacy
            // record without an epoch falls back to now + remaining.
            manualExpiryDeadline = ManualState.deadline(from: result.1, now: now)
        } else {
            // Keep the last known state rather than claiming "off" we cannot verify.
            statusReadable = false
            manualExpiryDeadline = nil
        }
        diagnostics.observation("manual_observation", fields: [
            "reason": statusReadable ? "helper_status_valid" : "helper_status_unavailable",
            "status": active ? "active" : (pausedManual ? "paused" : "off"),
            "expires": manualExpiryDeadline.map { String($0) } ?? "none"
        ])
        updateStatusItem()
        watchSessionProcess()
        scheduleManualExpiry(at: manualExpiryDeadline)
        rebuildMenu()
        if reconcile { reconcileManualSession() }
    }

    /// A paused timer has no live caffeinate process to watch, so its logical
    /// deadline is covered by one DispatchSource deadline timer aimed at the
    /// absolute deadline. Re-arming from an absolute instant (never from a
    /// relative "remaining" that a later read could re-extend) keeps expiry
    /// exact even across menu opens and directory events.
    func scheduleManualExpiry(at deadline: Double?) {
        manualExpiryTimer?.cancel()
        manualExpiryTimer = nil
        guard let deadline = deadline else { return }
        let delay = max(0, deadline - Date().timeIntervalSince1970)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        manualExpiryTimer = timer
    }

    func updateStatusItem() {
        guard let statusItem = item, let button = statusItem.button else { return }
        let filled = guiTimer.held || CupState.filled(manual: active, automatic: autoHeld)
        let symbolName = filled ? "cup.and.saucer.fill" : "cup.and.saucer"
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true

        button.title = ""
        button.image = image
        button.imagePosition = .imageOnly
        // The cup glyph is wider than it is tall; never let it clip in the fixed item.
        button.imageScaling = .scaleProportionallyDown
        let presentation = menuPresentation()
        let summary = presentation.compactSummary
        button.toolTip = "Codex Work Mode · \(summary)"
        button.setAccessibilityLabel("Codex Work Mode")
        button.setAccessibilityValue(summary)
        button.setAccessibilityHelp("Codex Work Mode · \(summary)")
    }

    /// Watches the owned caffeinate process so an automatic or external stop
    /// updates the item without polling.
    func watchSessionProcess() {
        var pid: pid_t?
        if active {
            let session = folder.appendingPathComponent("session")
            let contents = (try? String(contentsOf: session, encoding: .utf8)) ?? ""
            pid = contents.components(separatedBy: "\n").first
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { Int32($0) }
            if let value = pid, value <= 0 { pid = nil }
        }
        if pid != observedPID {
            processSource?.cancel()
            processSource = nil
            observedPID = pid
            if let pid = pid {
                let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
                source.setEventHandler { [weak self] in self?.refresh() }
                source.resume()
                processSource = source
            }
        }
    }

    // MARK: - Read-only power status

    var powerSourceLine: String {
        let label: String
        switch powerStatus?.source {
        case .powerAdapter?: label = "电源适配器"
        case .battery?: label = "电池"
        case .unavailable?: label = "暂无法确认"
        case nil: label = "正在读取"
        }
        return "供电：\(label)"
    }

    var energyModeLine: String {
        let label: String
        switch powerStatus?.energyMode {
        case .highPower?: label = "高能耗"
        case .lowPower?: label = "低电量"
        case .automatic?: label = "自动"
        case .unavailable?: label = "暂无法确认"
        case nil: label = "正在读取"
        }
        return "电源模式：\(label)"
    }

    var localTaskMenuLine: String {
        switch activityStatus {
        case .connectionNotSeen: return "已连接任务：尚未收到状态"
        case .unavailable: return "已连接任务：状态暂无法确认"
        case .idle: return "已连接任务：暂无活动"
        case .waiting: return "已连接任务：等待你确认"
        case .working: return "已连接任务：正在进行"
        }
    }

    var automaticMenuLine: String {
        if !autoEnabled { return "自动保持：已关闭" }
        switch sessionState {
        case .locked:
            guard activityStatus == .working else { return "自动保持：锁屏时无有效任务，已暂停" }
            break
        case .sleeping: return "自动保持：睡眠时暂停"
        case .inactive: return "自动保持：已切换到其他用户"
        case .unknown: return "自动保持：桌面状态暂不明确"
        case .active: break
        }
        if powerAvailability == .battery { return "自动保持：电池供电时暂停" }
        if powerAvailability == .unknown { return "自动保持：供电状态暂不明确" }
        if autoHeld {
            if sessionState == .locked { return "自动保持：锁屏后台工作中 · 不保持显示" }
            return autoEngine.graceUntil != nil ? "自动保持：任务结束后短暂保留" : "自动保持：正在保持电脑唤醒"
        }
        if autoEngine.asserting { return "自动保持：暂未成功启动" }
        switch activityStatus {
        case .connectionNotSeen: return "自动保持：尚未收到任务状态"
        case .unavailable: return "自动保持：任务状态暂无法确认"
        case .waiting: return "自动保持：等待你确认"
        case .idle: return "自动保持：等待已连接的任务"
        case .working: return "自动保持：正在准备"
        }
    }

    /// Starts at most one power read. Called once at launch and on each menu
    /// open; a read already in flight is reused instead of duplicated, and a
    /// completion never starts another read, so this can never poll.
    func requestPowerStatusRead() {
        guard !powerReadInFlight else { return }
        powerReadInFlight = true
        powerStatus = nil
        updatePowerRows()
        powerQueue.async { [weak self] in
            let profiler = WorkModeApp.readPowerStatus()
            let pmset = WorkModeApp.readPmsetMode()
            let parsed = PowerStatusParser.status(
                exitStatus: profiler.0,
                data: profiler.1,
                pmsetExitStatus: pmset.0,
                pmsetData: pmset.1
            )
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.powerReadInFlight = false
                self.powerStatus = parsed
                // Only the two informational rows change here: no menu rebuild,
                // no helper refresh, so an open menu keeps its actions and a
                // completed read cannot trigger another read.
                self.updatePowerRows()
            }
        }
    }

    /// Retitles the two disabled informational rows in place. They have no
    /// action, so an open menu is not disturbed.
    func updatePowerRows() {
        powerSourceItem?.title = powerSourceLine
        energyModeItem?.title = energyModeLine
    }

    /// Runs the read-only source probe off the main thread. Returns the exit
    /// status and stdout; a failure to launch is reported as non-zero status
    /// with no data.
    static func readPowerStatus() -> (Int32, Data) {
        runReadOnly("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"])
    }

    /// Runs the read-only `pmset -g custom` mode probe off the main thread, on
    /// the same serial power queue as the source probe. The only `pmset`
    /// arguments ever issued are `-g custom`: this reads the current settings
    /// and never changes them.
    static func readPmsetMode() -> (Int32, Data) {
        runReadOnly("/usr/bin/pmset", ["-g", "custom"])
    }

    /// Runs one fixed read-only command and returns `(exit status, stdout)`. The
    /// executable and arguments are compile-time constants at both call sites;
    /// nothing here is built from system or user input. A failure to launch is
    /// reported as non-zero status with no data.
    private static func runReadOnly(_ executable: String, _ arguments: [String]) -> (Int32, Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        // Discard diagnostics: they are never shown, and a null device cannot
        // fill up and stall the child.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        } catch {
            return (1, Data())
        }
    }

    // MARK: - Automatic awake for local Codex desktop work (v1.4)

    /// Concise status of the desktop activity snapshot for the menu.
    var activityLine: String {
        switch activityStatus {
        case .connectionNotSeen: return "Local hooks: connection not yet seen"
        case .unavailable: return "Local hooks: state unavailable"
        case .idle: return "Local hooks: idle"
        case .waiting: return "Local hooks: waiting for approval"
        case .working: return "Local hooks: working"
        }
    }

    /// Concise reason the automatic assertion is or is not held, from the shared
    /// gate. Purely informational; the Auto awake toggle remains the only
    /// control.
    var autoDetailLine: String {
        if activityStatus == .unavailable, autoEnabled,
           sessionState == .active, powerAvailability == .external,
           !autoHeld, !autoEngine.asserting {
            return "Auto: not holding — local hooks unavailable"
        }
        return AwakeGate.autoDetail(
            enabled: autoEnabled,
            power: powerAvailability,
            session: sessionState,
            working: activityStatus == .working,
            asserting: autoEngine.asserting,
            held: autoHeld,
            gracePending: autoEngine.graceUntil != nil
        )
    }

    /// Points the activity watch at the receiver's snapshot directory, falling
    /// back to the support folder while that directory does not exist yet, so
    /// its first appearance is noticed. No Codex file is ever read; only the
    /// receiver's own snapshot directory. Called with the menu open so a target
    /// that changed while the app was busy is picked up; it is a no-op while the
    /// path is unchanged.
    func rewatchActivity() {
        activityWatch.arm()
    }

    /// Reads one snapshot, validates its owner, and drives the automatic
    /// assertion through the shared gate. Called at launch, on session and power
    /// transitions, on activity-directory changes, on owner process exit, and on
    /// the scheduled renewal/grace timers only. An ineligible gate releases the
    /// assertion and clears the grace immediately. A lock may keep only valid
    /// working tasks, never grace; a battery change always releases.
    func refreshActivity() {
        let now = Date().timeIntervalSince1970
        let snapshot = readActivitySnapshot(now: now)
        activityStatus = snapshot.status
        watchAutoOwner(snapshot.ownerPID)

        let eligible = AwakeGate.autoEligible(
            enabled: autoEnabled,
            power: powerAvailability,
            session: sessionState,
            working: snapshot.isWorking
        )
        autoEngine.enabled = autoEnabled

        if autoEngine.step(working: snapshot.isWorking, eligible: eligible, now: now) {
            ensureAutoAssertion(now: now)
            if let deadline = autoEngine.graceUntil {
                scheduleGrace(at: deadline)
            } else {
                graceTimer?.cancel()
                graceTimer = nil
            }
        } else {
            stopAutoProcess(reason: snapshot.status == .unavailable && eligible
                            ? "Auto: not holding — local hooks unavailable"
                            : AwakeGate.autoDetail(enabled: autoEnabled, power: powerAvailability,
                                                         session: sessionState, working: snapshot.isWorking,
                                                         asserting: autoEngine.asserting, held: false,
                                                         gracePending: autoEngine.graceUntil != nil))
            renewTimer?.cancel()
            renewTimer = nil
            graceTimer?.cancel()
            graceTimer = nil
        }
        diagnostics.observation("awake_decision", fields: [
            "reason": autoDetailLine, "status": String(describing: activityStatus),
            "session": String(describing: sessionState), "power": String(describing: powerAvailability),
            "enabled": String(autoEnabled), "held": String(autoHeld),
            "requested": String(autoEngine.asserting), "grace_until": autoEngine.graceUntil.map { String($0) } ?? "none"
        ])
        updateStatusItem()
        rebuildMenu()
    }

    /// Reads and validates the receiver's snapshot. A missing file is
    /// `connectionNotSeen`; unreadable contents or an invalid desktop owner are
    /// `unavailable`. Neither is evidence of idle work or counts as working.
    func readActivitySnapshot(now: Double) -> ActivitySnapshot {
        guard FileManager.default.fileExists(atPath: activityStateFile.path) else {
            diagnostics.observation("activity_observation", fields: ["reason": "snapshot_missing", "status": "connectionNotSeen"])
            return .connectionNotSeen
        }
        guard
            let data = FileManager.default.contents(atPath: activityStateFile.path),
            let parsed = ActivitySnapshotParser.parse(data: data, now: now)
        else {
            diagnostics.observation("activity_observation", fields: ["reason": "snapshot_unreadable_or_malformed", "status": "unavailable"])
            return .unavailable
        }
        guard ownerIsValid(pid: parsed.ownerPID, signature: parsed.ownerSignature) else {
            diagnostics.observation("activity_observation", fields: ["reason": "desktop_owner_not_valid", "status": "unavailable",
                                    "owner_pid": parsed.ownerPID.map(String.init) ?? "none"])
            return .unavailable
        }
        diagnostics.observation("activity_observation", fields: ["reason": "snapshot_and_desktop_owner_valid",
                                "status": String(describing: parsed.status), "owner_pid": parsed.ownerPID.map(String.init) ?? "none"])
        return parsed
    }

    /// The stored owner is valid only while the exact same process is running:
    /// the pid must still exist and its start signature must match, so a reused
    /// pid is rejected.
    func ownerIsValid(pid: Int32?, signature: String?) -> Bool {
        guard let pid = pid, pid > 0 else { return false }
        return WorkModeApp.ownerMatches(
            storedPID: pid,
            storedSignature: signature,
            currentSignature: WorkModeApp.processStartSignature(pid: pid)
        )
    }

    /// Pure owner-match rule: a record is valid only when the recorded pid is
    /// positive, the recorded start signature is present, and it still equals
    /// the owner's current start signature. A missing current signature (the
    /// process died or could not be read) or a different signature (the pid was
    /// reused) both invalidate the record.
    static func ownerMatches(
        storedPID: Int32?,
        storedSignature: String?,
        currentSignature: String?
    ) -> Bool {
        guard let pid = storedPID, pid > 0,
              let stored = storedSignature, !stored.isEmpty,
              let current = currentSignature, !current.isEmpty
        else { return false }
        return stored == current
    }

    /// Normalize a `ps -o lstart=` start signature exactly like the hook
    /// receiver's process-table parser: every run of whitespace collapses to a
    /// single space and the value is trimmed, or nil when blank. `ps` prints a
    /// doubled space before a single-digit day of month, so without this the
    /// stored (Python-normalized) signature would never match.
    static func normalizeStartSignature(_ text: String) -> String? {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Read-only `ps` start-signature probe for one pid. No Codex file or model
    /// tool is consulted.
    static func processStartSignature(pid: Int32) -> String? {
        let result = runReadOnly("/bin/ps", ["-p", String(pid), "-o", "lstart="])
        guard result.0 == 0, let text = String(data: result.1, encoding: .utf8) else {
            return nil
        }
        return normalizeStartSignature(text)
    }

    /// Watches the owning app-server process so its exit releases automatic
    /// awake after the grace period without polling.
    func watchAutoOwner(_ pid: Int32?) {
        let normalized: Int32? = (pid ?? 0) > 0 ? pid : nil
        if autoOwnerPID == normalized { return }
        autoOwnerSource?.cancel()
        autoOwnerSource = nil
        autoOwnerPID = normalized
        guard let value = normalized, value > 0 else { return }
        let source = DispatchSource.makeProcessSource(
            identifier: value,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.refreshActivity() }
        source.resume()
        autoOwnerSource = source
    }

    /// Keeps exactly one owned, bounded `caffeinate` process covering the
    /// automatic assertion, renewing before the 300 second bound expires.
    ///
    /// `autoHeld` is the effective state: it is true only while the owned
    /// process is actually running, and is cleared the moment a spawn fails or
    /// the process exits early. A failure never becomes an uncontrolled retry
    /// loop: the next attempt is deferred to the renewal boundary, so at most
    /// one attempt is made per renewal period and nothing polls.
    func ensureAutoAssertion(now: Double) {
        if let process = autoProcess, process.isRunning {
            autoHeld = true
            if now - autoStartedAt < AutoAwakeEngine.renewalSeconds {
                scheduleRenew(at: autoStartedAt + AutoAwakeEngine.renewalSeconds)
                return
            }
            // The current bounded process is due for renewal: replace it.
            stopAutoProcess(reason: "lease_renewal")
            startAutoProcess(now: now)
            return
        }
        if let process = autoProcess {
            // The owned process stopped without us stopping it.
            handleAutoProcessExit(process)
            return
        }
        guard AutoAwakeEngine.mayStart(startedAt: autoStartedAt, now: now) else {
            // Bounded backoff after a failed spawn or an early exit: exactly one
            // retry, at the renewal boundary. No polling and no tight loop.
            scheduleRenew(at: autoStartedAt + AutoAwakeEngine.renewalSeconds)
            return
        }
        startAutoProcess(now: now)
    }

    /// The owned assertion executable. `var` only so an isolated test can point
    /// at a path that cannot be launched and prove the spawn-failure path.
    var autoAssertionExecutable = "/usr/bin/caffeinate"

    /// Starts the app's own assertion. Only `-i` (system idle sleep) is
    /// requested: the display may turn off normally and a dark screen is never
    /// treated as a lock. `-w` ties the assertion to this app process for crash
    /// safety and `-t 300` bounds it even if this app hangs.
    func startAutoProcess(now: Double) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: autoAssertionExecutable)
        process.arguments = [
            "-i",
            "-t", String(Int(AutoAwakeEngine.assertionSeconds)),
            "-w", String(ProcessInfo.processInfo.processIdentifier),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async { self?.handleAutoProcessExit(process) }
        }
        do {
            try process.run()
            autoProcess = process
            autoStartedAt = now
            autoHeld = true
            diagnostics.record("automatic_assertion_started", fields: ["pid": process.processIdentifier, "reason": "idle_sleep_only_bounded_lease"])
            scheduleRenew(at: now + AutoAwakeEngine.renewalSeconds)
        } catch {
            diagnostics.record("automatic_assertion_start_failed", fields: ["error_code": (error as NSError).code])
            // The assertion was never obtained: report it as not holding and
            // anchor the bounded backoff instead of retrying here.
            autoProcess = nil
            autoHeld = false
            autoStartedAt = now
            // One bounded retry at the renewal boundary: never a tight loop and
            // never a poll.
            scheduleRenew(at: now + AutoAwakeEngine.renewalSeconds)
        }
    }

    /// Handles the owned assertion process ending on its own (crash, early exit,
    /// or its own 300 second bound). Stale notifications from a process this app
    /// already replaced or stopped are ignored, and the retry is bounded to the
    /// next renewal boundary.
    func handleAutoProcessExit(_ process: Process?) {
        guard let process = process, let current = autoProcess, current === process else { return }
        diagnostics.record("automatic_assertion_exited", fields: ["pid": process.processIdentifier, "exit_code": process.terminationStatus])
        autoProcess = nil
        autoHeld = false
        autoStartedAt = Date().timeIntervalSince1970
        updateStatusItem()
        scheduleRenew(at: autoStartedAt + AutoAwakeEngine.renewalSeconds)
    }

    func scheduleRenew(at deadline: Double) {
        renewTimer?.cancel()
        let delay = max(0, deadline - Date().timeIntervalSince1970)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.refreshActivity() }
        timer.resume()
        renewTimer = timer
    }

    func scheduleGrace(at deadline: Double) {
        graceTimer?.cancel()
        let delay = max(0, deadline - Date().timeIntervalSince1970)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.refreshActivity() }
        timer.resume()
        graceTimer = timer
    }

    /// Releases only the automatic assertion: its own caffeinate process,
    /// timers, and engine state. The manual helper session is never touched.
    func releaseAutoAwake(reason: String = "automatic_reset") {
        autoEngine.enabled = autoEnabled
        autoEngine.reset()
        stopAutoProcess(reason: reason)
        renewTimer?.cancel()
        renewTimer = nil
        graceTimer?.cancel()
        graceTimer = nil
    }

    /// Cancels only the exact caffeinate process this app started. The
    /// termination handler is detached first so this deliberate stop can never
    /// be mistaken for an unexpected exit and re-arm a backoff.
    func stopAutoProcess(reason: String = "gate_or_work_released") {
        if let process = autoProcess {
            diagnostics.record("automatic_assertion_released", fields: ["pid": process.processIdentifier,
                               "reason": reason, "session": String(describing: sessionState),
                               "power": String(describing: powerAvailability), "status": String(describing: activityStatus)])
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        autoProcess = nil
        autoHeld = false
        autoStartedAt = 0
    }

    @objc func toggleAutoAwake() {
        autoEnabled.toggle()
        UserDefaults.standard.set(autoEnabled, forKey: autoAwakeDefaultsKey)
        diagnostics.record("auto_toggle", fields: ["enabled": autoEnabled])
        if !autoEnabled {
            releaseAutoAwake(reason: "toggle_disabled")
        }
        refreshActivity()
    }

    // MARK: - Menu

    /// Only the top-level menu has a delegate. Purpose descriptions belong
    /// beside their choices; diagnostic information stays in a secondary menu.
    func rebuildMenu() {
        guard let statusItem = item, let menu = statusItem.menu else { return }
        populateMenu(menu)
    }

    /// Shared by the actual menu and offscreen layout checks. This constructs
    /// native items only; it does not show a menu or create a status bar item.
    func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        backgroundStatusItem = nil
        let presentation = menuPresentation()
        let status = NSMenuItem(title: presentation.heading, action: nil, keyEquivalent: "")
        status.isEnabled = false
        let card = WorkMenuStatusView(presentation)
        status.view = card
        statusCard = card
        statusHeadingItem = status
        menu.addItem(status)

        let displayConfigured = guiTimer.configured
        let manualConfigured = active || pausedManual

        // Every configured source keeps its own stop action. One source never
        // replaces or disables another.
        if displayConfigured {
            let stop = NSMenuItem(title: displayStopTitle, action: #selector(stopGUIWork), keyEquivalent: "")
            stop.target = self
            stop.isEnabled = !busy
            menu.addItem(stop)
            if manualConfigured {
                // The display request owns the card above, so the manual timer
                // keeps its own truthful, read-only status row beside it.
                let background = NSMenuItem(title: backgroundMenuLine, action: nil, keyEquivalent: "")
                background.isEnabled = false
                menu.addItem(background)
                backgroundStatusItem = background
            }
        }
        if manualConfigured {
            let stop = NSMenuItem(title: "结束后台计时", action: #selector(stopMode), keyEquivalent: "")
            stop.target = self
            stop.isEnabled = statusReadable && !busy
            menu.addItem(stop)
        }
        menu.addItem(.separator())

        let auto = NSMenuItem(title: "自动保持后台工作（接通电源）", action: #selector(toggleAutoAwake), keyEquivalent: "")
        auto.target = self
        auto.state = autoEnabled ? .on : .off
        auto.isEnabled = true
        auto.toolTip = "接通电源时，自动保持已连接的后台任务；不保持屏幕显示。"
        menu.addItem(auto)

        if !manualConfigured {
            let manual = NSMenuItem(title: "手动后台计时", action: nil, keyEquivalent: "")
            manual.isEnabled = statusReadable && !busy
            let timers = NSMenu()
            timers.autoenablesItems = false
            timers.addItem(menuNote("仅保持电脑唤醒，屏保与息屏照常"))
            for hours in [1, 4, 8] {
                let start = NSMenuItem(title: "\(hours) 小时", action: #selector(startFromMenu(_:)), keyEquivalent: "")
                start.target = self
                start.tag = hours * 3600
                start.isEnabled = manual.isEnabled
                timers.addItem(start)
            }
            let custom = NSMenuItem(title: "自定小时数…", action: #selector(startCustomFromMenu(_:)), keyEquivalent: "")
            custom.target = self
            custom.isEnabled = manual.isEnabled
            timers.addItem(custom)
            timers.addItem(.separator())
            timers.addItem(menuNote("锁屏/睡眠时暂停，恢复不延长计时"))
            manual.submenu = timers
            menu.addItem(manual)
        }
        menu.addItem(menuNote("后台选项不保持显示，屏保与息屏照常"))
        menu.addItem(.separator())

        if !displayConfigured {
            let desktop = NSMenuItem(title: "保持屏幕显示", action: nil, keyEquivalent: "")
            // Eligibility is the current unlocked active session only: battery
            // and Low Power Mode stay available and no energy setting is written.
            desktop.isEnabled = !busy && AwakeGate.sessionAllowsAssertion(sessionState)
            let timers = NSMenu()
            timers.autoenablesItems = false
            timers.addItem(menuNote("保持屏幕显示，自动屏保会暂缓"))
            for (title, seconds) in [("30 分钟", 1800), ("1 小时", 3600), ("4 小时", 14400), ("8 小时", 28800)] {
                let start = NSMenuItem(title: title, action: #selector(startGUIWork(_:)), keyEquivalent: "")
                start.target = self
                start.tag = seconds
                start.isEnabled = desktop.isEnabled
                timers.addItem(start)
            }
            let custom = NSMenuItem(title: "自定小时数…", action: #selector(startDisplayCustomFromMenu(_:)), keyEquivalent: "")
            custom.target = self
            custom.isEnabled = desktop.isEnabled
            timers.addItem(custom)
            timers.addItem(.separator())
            let until = NSMenuItem(title: "直到我关闭", action: #selector(startDisplayUntilStopped(_:)), keyEquivalent: "")
            until.target = self
            until.isEnabled = desktop.isEnabled
            timers.addItem(until)
            timers.addItem(.separator())
            timers.addItem(menuNote("结束后，系统可能立即屏保或息屏"))
            timers.addItem(menuNote("手动屏保与锁屏仍可生效"))
            timers.addItem(menuNote("电池供电与低电量模式下同样可用"))
            timers.addItem(menuNote("锁屏/睡眠时暂停，原结束时间不变"))
            if !AwakeGate.sessionAllowsAssertion(sessionState) {
                timers.addItem(menuNote("请先解锁当前桌面；不会自动解锁"))
            }
            desktop.submenu = timers
            menu.addItem(desktop)
            menu.addItem(.separator())
        }

        let screenSaver = NSMenuItem(title: "立即启动屏保", action: #selector(startScreenSaver), keyEquivalent: "")
        screenSaver.target = self
        screenSaver.isEnabled = !busy
        screenSaver.toolTip = "启动系统屏保；会结束屏幕显示保持，后台任务不受影响。"
        menu.addItem(screenSaver)
        menu.addItem(menuNote("后台任务会继续，锁屏与息屏仍按 macOS 设置"))
        menu.addItem(.separator())

        let details = NSMenuItem(title: "更多状态与日志", action: nil, keyEquivalent: "")
        details.isEnabled = true
        let detailsMenu = NSMenu()
        detailsMenu.autoenablesItems = false
        detailsMenu.addItem(menuNote(localTaskMenuLine))
        detailsMenu.addItem(menuNote("Work/圆点任务：暂不能自动识别"))
        detailsMenu.addItem(menuNote(automaticMenuLine))
        let powerSource = NSMenuItem(title: powerSourceLine, action: nil, keyEquivalent: "")
        powerSource.isEnabled = false
        detailsMenu.addItem(powerSource)
        powerSourceItem = powerSource
        let energyMode = NSMenuItem(title: energyModeLine, action: nil, keyEquivalent: "")
        energyMode.isEnabled = false
        detailsMenu.addItem(energyMode)
        energyModeItem = energyMode
        detailsMenu.addItem(.separator())
        let showLogs = NSMenuItem(title: "查看诊断日志", action: #selector(showDiagnosticLogs), keyEquivalent: "")
        showLogs.target = self
        detailsMenu.addItem(showLogs)
        let exportLogs = NSMenuItem(title: "导出诊断日志…", action: #selector(exportDiagnosticLogs), keyEquivalent: "")
        exportLogs.target = self
        detailsMenu.addItem(exportLogs)
        details.submenu = detailsMenu
        menu.addItem(details)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: active || pausedManual || guiTimer.configured ? "结束计时并退出" : "退出",
                              action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = !busy
        menu.addItem(quit)
    }

    func menuNote(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 25))
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 16, y: 4, width: 308, height: 18)
        label.lineBreakMode = .byTruncatingTail
        view.addSubview(label)
        item.view = view
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        // A user opening the menu is an explicit retry point for a suspend or
        // resume that previously failed.
        reconcileBlocked = false
        refresh()
        // Re-target (a no-op unless the watch path changed) before the read, so
        // this can never itself open a gap in an event burst.
        rewatchActivity()
        refreshActivity()
        requestPowerStatusRead()
        updateMenuClock()
        startMenuClock()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuClock?.invalidate()
        menuClock = nil
    }

    // MARK: - Actions

    /// The finite display choices the submenu offers: 30 minutes, 1/4/8 hours.
    static let displayFiniteChoices = [1800, 3600, 14400, 28800]

    @objc func startGUIWork(_ sender: NSMenuItem) {
        guard !busy, !guiTimer.configured, Self.displayFiniteChoices.contains(sender.tag) else { return }
        startDisplayHold(seconds: sender.tag)
    }

    /// Starts the explicit display hold for a finite whole-second duration. The
    /// only gate is the current unlocked active session: power source and energy
    /// mode never participate, and no OS energy setting is written.
    func startDisplayHold(seconds: Int) {
        refreshSessionNow()
        guard AwakeGate.sessionAllowsAssertion(sessionState) else {
            presentFailure("请先解锁当前桌面，再开始屏幕显示保持。")
            return
        }
        if !guiTimer.start(seconds: seconds, eligible: true) {
            presentFailure("暂时无法开始屏幕显示保持，请查看诊断日志。")
        }
    }

    /// Starts the until-stopped display request. It has no deadline and stays
    /// distinct from an off state and from a finite request.
    @objc func startDisplayUntilStopped(_ sender: NSMenuItem) {
        guard !busy, !guiTimer.configured else { return }
        refreshSessionNow()
        guard AwakeGate.sessionAllowsAssertion(sessionState) else {
            presentFailure("请先解锁当前桌面，再开始屏幕显示保持。")
            return
        }
        if !guiTimer.startUntilStopped(eligible: true) {
            presentFailure("暂时无法开始屏幕显示保持，请查看诊断日志。")
        }
    }

    @objc func stopGUIWork() {
        guard !busy else { return }
        guiTimer.stop(reason: "user_cancelled")
    }

    // MARK: - Screen saver

    /// Installed system screen saver. This is a read-only reference: the app
    /// never changes the screen saver selection, its timeout, the password
    /// requirement or any energy setting, and it never dismisses or relaunches
    /// the screen saver.
    static let screenSaverEnginePath = "/System/Library/CoreServices/ScreenSaverEngine.app"

    /// Test seam: production opens the installed system ScreenSaverEngine
    /// through NSWorkspace and reports launch failure; an isolated test
    /// substitutes a harmless closure and never launches it.
    var launchScreenSaver: () -> Bool = { WorkModeApp.openScreenSaver() }

    /// Opens the installed system screen saver. Returns false when the engine is
    /// missing or NSWorkspace could not start it; the caller must not claim the
    /// screen saver is running in that case.
    static func openScreenSaver() -> Bool {
        let url = URL(fileURLWithPath: screenSaverEnginePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Stops only this app's explicit display hold, then asks the system to
    /// start the screen saver. Background and automatic awake work are never
    /// cancelled. Returned so the failure path is testable without a modal.
    @discardableResult
    func requestScreenSaver() -> Bool {
        guiTimer.stop(reason: "user_started_screen_saver")
        let started = launchScreenSaver()
        diagnostics.record(started ? "screensaver_launch_requested" : "screensaver_launch_failed",
                           fields: ["reason": "user_action"])
        return started
    }

    @objc func startScreenSaver() {
        guard !busy else { return }
        guard requestScreenSaver() else {
            // Never claim the screen saver is running when the launcher failed.
            presentFailure("暂时无法启动系统屏保；屏保是否运行以 macOS 为准。")
            return
        }
    }

    @objc func showDiagnosticLogs() {
        do {
            try FileManager.default.createDirectory(at: diagnostics.directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(diagnostics.directory)
        } catch {
            presentFailure("暂时无法打开诊断日志。")
        }
    }

    @objc func exportDiagnosticLogs() {
        let panel = NSSavePanel()
        panel.title = "导出 Codex Work Mode 诊断日志"
        panel.nameFieldStringValue = "Coffee-Work-Diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        activateForDialog()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try diagnostics.export(to: destination, hookDirectory: activityFolder.appendingPathComponent("diagnostics"))
        } catch {
            presentFailure("暂时无法导出诊断日志。")
        }
    }

    @objc func startFromMenu(_ sender: NSMenuItem) {
        // A new request made while the session is ineligible is created paused,
        // so it never even momentarily creates an awake assertion. The session
        // is re-read first so a lock that arrived since the last menu refresh is
        // respected. An explicit display request is never consulted: the two
        // sources are independent.
        refreshSessionNow()
        let sessionAllows = AwakeGate.sessionAllowsAssertion(sessionState)
        performAction("on", seconds: sender.tag, paused: !sessionAllows)
    }

    // MARK: - Custom hours

    /// Custom hours… only ever starts a new session; an active session keeps its
    /// Stop action, so extension is intentionally not offered.
    @objc func startCustomFromMenu(_ sender: NSMenuItem) {
        guard !busy else { return }
        guard let hours = promptForCustomHours(.background) else { return } // Cancel changes nothing.
        refreshSessionNow()
        let sessionAllows = AwakeGate.sessionAllowsAssertion(sessionState)
        performAction("on", seconds: hours * 3600, paused: !sessionAllows)
    }

    /// The display submenu's custom hours… entry. It shares the bounded 1...24
    /// whole-hour parser but starts a display request, never the background
    /// helper, and is independent of both the background timer and the
    /// automatic assertion.
    @objc func startDisplayCustomFromMenu(_ sender: NSMenuItem) {
        guard !busy, !guiTimer.configured else { return }
        guard let hours = promptForCustomHours(.display) else { return } // Cancel changes nothing.
        startDisplayHold(seconds: hours * 3600)
    }

    /// Native bounded input dialog. Returns the chosen whole hours, or nil when
    /// the user cancels. An out-of-contract entry is explained and re-prompted;
    /// Cancel at any point leaves work-mode state untouched.
    func promptForCustomHours(_ purpose: CustomHoursPurpose) -> Int? {
        var entry = String(CustomHours.default)
        while true {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = purpose.heading
            alert.informativeText = """
                输入 \(CustomHours.minimum)～\(CustomHours.maximum) 之间的整数小时。默认 \(CustomHours.default) 小时。
                \(purpose.detail)
                """
            alert.addButton(withTitle: "开始计时")
            alert.addButton(withTitle: "取消")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            field.stringValue = entry
            field.placeholderString = String(CustomHours.default)
            field.alignment = .right
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            activateForDialog()
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }

            if let hours = CustomHours.parse(field.stringValue) {
                return hours
            }
            entry = field.stringValue
            presentInvalidHours(entry)
        }
    }

    /// Explains an out-of-contract entry without starting a session.
    func presentInvalidHours(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "请输入 \(CustomHours.minimum)～\(CustomHours.maximum) 之间的整数小时"
        let detail = trimmed.isEmpty
            ? "还没有输入小时数。"
            : "“\(trimmed)”不是范围内的整数小时。"
        alert.informativeText = "\(detail) 例如输入 \(CustomHours.default)。"
        alert.addButton(withTitle: "好")
        activateForDialog()
        alert.runModal()
    }

    func activateForDialog() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func stopMode() {
        performAction("off")
    }

    @objc func quitApp() {
        guard !busy else { return }
        guiTimer.stop(reason: "app_quit")
        if active {
            // Stop and Quit: stop first so the label matches what happened.
            performAction("off", quit: true)
        } else {
            NSApp.terminate(nil) // applicationWillTerminate still stops on quit.
        }
    }

    /// Single funnel for state-changing helper runs. Everything is serialized,
    /// the item and menu are locked while busy, and no second action can start
    /// until the first one has been applied on the main queue. `paused` reaches
    /// the helper's `on` operation so an ineligible start never spawns
    /// caffeinate at all.
    func performAction(_ mode: String, seconds: Int = 28800, paused: Bool = false, quit: Bool = false) {
        guard !busy else { return }
        busy = true
        rebuildMenu()
        queue.async { [self] in
            let result = invoke(mode, seconds: seconds, paused: paused)
            diagnostics.record("manual_action", fields: ["mode": mode, "paused": paused, "exit_code": result.0])
            DispatchQueue.main.async { [self] in
                busy = false
                refresh(reconcile: false)
                let pending = reconcilePending
                reconcilePending = false
                if result.0 != 0 {
                    // A failed command is surfaced once and blocks further
                    // automatic reconciliation until the next session/power
                    // event or menu open, so a bad state cannot spin.
                    reconcileBlocked = true
                    presentFailure(result.1)
                } else if quit {
                    NSApp.terminate(nil)
                } else if pending {
                    // A session/power transition arrived while the user's action
                    // was in flight; settle it against the refreshed state.
                    reconcileManualSession()
                }
            }
        }
    }

    func presentFailure(_ message: String) {
        guard !alertVisible else { return }
        alertVisible = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "本次操作未完成"
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = detail.isEmpty ? "暂时无法确认结果，请查看诊断日志。" : detail
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        alert.runModal()
        alertVisible = false
    }
}

let app = NSApplication.shared
let delegate = WorkModeApp()
app.delegate = delegate
app.run()
