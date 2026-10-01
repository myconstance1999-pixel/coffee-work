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
// every caffeinate request to system idle-sleep prevention only (`-i`); the
// display is never held on, so the screen may turn off normally and a dark
// screen is never treated as a lock. One shared gate decides whether either
// source may assert:
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

/// The one shared eligibility rule used by automatic awake, manual awake, and
/// the menu's explanation row. Pure and clock-free so it can be exercised
/// directly.
enum AwakeGate {
    /// Only the active, unlocked console session may hold any awake assertion.
    static func sessionAllowsAssertion(_ state: SessionState) -> Bool {
        state == .active
    }

    /// Automatic awake requires the toggle, external power, and an eligible
    /// session. Battery, an unknown power source, a lock/sleep/inactive/unknown
    /// session, or a disabled toggle all make it ineligible immediately.
    static func autoEligible(
        enabled: Bool,
        power: PowerAvailability,
        session: SessionState
    ) -> Bool {
        enabled && power == .external && sessionAllowsAssertion(session)
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
        case .locked: return "Auto: paused — screen locked"
        case .inactive: return "Auto: paused — session inactive"
        case .unknown: return "Auto: paused — session unavailable"
        case .active: break
        }
        switch power {
        case .battery: return "Auto: paused — on battery"
        case .unknown: return "Auto: paused — power source unavailable"
        case .external: break
        }
        if held { return gracePending ? "Auto: holding (120s grace)" : "Auto: holding" }
        if asserting { return "Auto: not holding — assertion unavailable" }
        return working ? "Auto: starting" : "Auto: ready — no Codex work"
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
/// The latches exist so that a wake cannot by itself resume an assertion while
/// the screen is still locked and so a stale sampled snapshot cannot override a
/// just-delivered lock or sleep notification. A latch is only cleared by its
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
        if locked { return .locked }
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
/// `connectionNotSeen` means no snapshot has ever been published; `idle` means
/// a snapshot exists but no live turn is open; `waiting` means at least one
/// known turn is waiting for approval and none is working; `working` means at
/// least one known turn is actively working.
enum ActivityStatus: Equatable {
    case connectionNotSeen
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

    var isWorking: Bool { status == .working }
}

/// Strict, side-effect-free parser for the hook receiver's `state.json`.
///
/// Only the documented minimal fields are read. Each turn is capped at 24 hours
/// of age, so a missed Stop can never keep the Mac awake forever; a long tool
/// is never cut for lack of events, because activity is judged by turn age, not
/// by how recently an event arrived. Malformed JSON is rejected (`nil`) and the
/// app treats the snapshot as idle rather than guessing.
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
/// working and whether the shared gate (toggle on, external power, active
/// unlocked session) currently allows an assertion. While a turn works and the
/// gate is eligible the automatic assertion is held immediately. When no turn
/// works (all stopped, or only waiting for approval) the engine keeps the
/// assertion for a 120 second grace period and then releases it; new work
/// cancels the grace at once. The grace survives only while the gate stays
/// eligible: battery/unknown power, a lock, or sleep releases the assertion and
/// clears the grace immediately, and new work cannot restart it while
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

final class WorkModeApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Installed helper location. The install step, not this app, owns the file.
    /// `var` so an isolated test can point at a private root; production never
    /// reassigns it.
    var folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Codex Work Mode")
    let queue = DispatchQueue(label: "local.plan.codex-work-mode.commands")
    /// Separate serial queue for the read-only power probe, so a slow
    /// system_profiler run can never delay a start/stop helper action.
    let powerQueue = DispatchQueue(label: "local.plan.codex-work-mode.power")

    var item: NSStatusItem!
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
        for (name, change) in workspaceChanges {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleSessionChange(change)
            }
        }
        let distributed = DistributedNotificationCenter.default()
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
        reconcileManualSession()
        refreshActivity()
    }

    func handlePowerChange() {
        powerAvailability = powerMonitor.availability
        reconcileBlocked = false
        // A power change is also a cheap, bounded trigger to recheck the
        // session; the latches still win over the sampled snapshot.
        refreshSessionState(recheckSnapshot: true)
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
        releaseAutoAwake()
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

    var stateSummary: String {
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
        WorkModeApp.menuStatus(
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
        let filled = CupState.filled(manual: active, automatic: autoHeld)
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
        button.toolTip = "Codex Work Mode — \(stateSummary)"
        button.setAccessibilityLabel("Codex Work Mode")
        button.setAccessibilityValue(stateSummary)
        button.setAccessibilityHelp("Codex Work Mode menu — \(stateSummary)")
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
        "Power source: \(powerStatus?.source.rawValue ?? "Loading…")"
    }

    var energyModeLine: String {
        "Energy mode: \(powerStatus?.energyMode.rawValue ?? "Loading…")"
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
        case .connectionNotSeen: return "Codex: connection not yet seen"
        case .idle: return "Codex: idle"
        case .waiting: return "Codex: waiting for approval"
        case .working: return "Codex: working"
        }
    }

    /// Concise reason the automatic assertion is or is not held, from the shared
    /// gate. Purely informational; the Auto awake toggle remains the only
    /// control.
    var autoDetailLine: String {
        AwakeGate.autoDetail(
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
    /// assertion and clears the grace immediately, so neither a lock nor a
    /// battery change can be masked by a pending grace.
    func refreshActivity() {
        let now = Date().timeIntervalSince1970
        let snapshot = readActivitySnapshot(now: now)
        activityStatus = snapshot.status
        watchAutoOwner(snapshot.ownerPID)

        let eligible = AwakeGate.autoEligible(
            enabled: autoEnabled,
            power: powerAvailability,
            session: sessionState
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
            stopAutoProcess()
            renewTimer?.cancel()
            renewTimer = nil
            graceTimer?.cancel()
            graceTimer = nil
        }
        updateStatusItem()
        rebuildMenu()
    }

    /// Reads and validates the receiver's snapshot. A missing file is
    /// `connectionNotSeen`; an unreadable file is `idle`; records whose desktop
    /// owner pid or start signature no longer match are discarded as idle.
    func readActivitySnapshot(now: Double) -> ActivitySnapshot {
        guard FileManager.default.fileExists(atPath: activityStateFile.path) else {
            return .connectionNotSeen
        }
        guard
            let data = FileManager.default.contents(atPath: activityStateFile.path),
            let parsed = ActivitySnapshotParser.parse(data: data, now: now)
        else {
            return .idle
        }
        guard ownerIsValid(pid: parsed.ownerPID, signature: parsed.ownerSignature) else {
            return ActivitySnapshot(
                status: .idle,
                ownerPID: nil,
                ownerSignature: nil,
                freshestRefresh: parsed.freshestRefresh
            )
        }
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
            stopAutoProcess()
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
            scheduleRenew(at: now + AutoAwakeEngine.renewalSeconds)
        } catch {
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
    func releaseAutoAwake() {
        autoEngine.enabled = autoEnabled
        autoEngine.reset()
        stopAutoProcess()
        renewTimer?.cancel()
        renewTimer = nil
        graceTimer?.cancel()
        graceTimer = nil
    }

    /// Cancels only the exact caffeinate process this app started. The
    /// termination handler is detached first so this deliberate stop can never
    /// be mistaken for an unexpected exit and re-arm a backoff.
    func stopAutoProcess() {
        if let process = autoProcess {
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
        if !autoEnabled {
            releaseAutoAwake()
        }
        refreshActivity()
    }

    // MARK: - Menu

    /// Assembles the whole menu. Version 1.5 keeps the v1.4.1 five content rows
    /// and the same targets, tags, and enabled rules:
    ///   1. overall status (read-only, always top): normal sleep, active manual
    ///      with its end time, paused manual with its original end time,
    ///      automatic awake, or status unavailable,
    ///   2. Auto awake for Codex (checked toggle, directly available),
    ///   3. manual timer control — one "Keep awake for" submenu (1/4/8 hours
    ///      and Custom hours…) while inactive, or one direct "Stop timer" row
    ///      while a session runs, including while it is paused,
    ///   4. Details (read-only Codex activity, automatic eligibility, power
    ///      source, energy mode),
    ///   5. Quit / Stop and Quit.
    /// That is five content rows and no new mode selector. The two submenus
    /// deliberately carry no menu delegate: opening one must never fire
    /// `menuWillOpen`, refresh state, rebuild this menu, or start another power
    /// probe. The read-only power rows keep their item references
    /// (`powerSourceItem`/`energyModeItem`), so an asynchronous power completion
    /// retitles them inside the nested menu without touching the rest of the
    /// menu.
    func rebuildMenu() {
        guard let statusItem = item, let menu = statusItem.menu else { return }
        menu.removeAllItems()

        // 1. Overall state, read-only and always first.
        let status = NSMenuItem(title: overallStatusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        // 2. Automatic awake toggle, directly available and never nested, so
        //    its checked state is one click away.
        let auto = NSMenuItem(
            title: "Auto awake for Codex",
            action: #selector(toggleAutoAwake),
            keyEquivalent: ""
        )
        auto.target = self
        auto.state = autoEnabled ? .on : .off
        auto.isEnabled = true
        menu.addItem(auto)

        // 3. Manual timer control. Same targets, tags, and enabled rules as
        //    before. A paused session keeps the direct Stop timer row so it
        //    stays cancelable, but it is not an active awake assertion.
        if active || pausedManual {
            let stop = NSMenuItem(title: "Stop timer", action: #selector(stopMode), keyEquivalent: "")
            stop.target = self
            stop.isEnabled = statusReadable && !busy
            menu.addItem(stop)
        } else {
            let keepAwake = NSMenuItem(title: "Keep awake for", action: nil, keyEquivalent: "")
            keepAwake.isEnabled = statusReadable && !busy
            let timers = NSMenu()
            timers.autoenablesItems = false
            for hours in [1, 4, 8] {
                let start = NSMenuItem(
                    title: "\(hours) hour\(hours == 1 ? "" : "s")",
                    action: #selector(startFromMenu(_:)),
                    keyEquivalent: ""
                )
                start.target = self
                start.tag = hours * 3600
                start.isEnabled = statusReadable && !busy
                timers.addItem(start)
            }
            let custom = NSMenuItem(
                title: "Custom hours…",
                action: #selector(startCustomFromMenu(_:)),
                keyEquivalent: ""
            )
            custom.target = self
            custom.isEnabled = statusReadable && !busy
            timers.addItem(custom)
            keepAwake.submenu = timers
            menu.addItem(keepAwake)
        }

        // 4. Details holds the read-only rows. Their item references are kept
        //    so an in-flight power read can retitle them in place.
        let details = NSMenuItem(title: "Details", action: nil, keyEquivalent: "")
        details.isEnabled = true
        let detailsMenu = NSMenu()
        detailsMenu.autoenablesItems = false

        let activity = NSMenuItem(title: activityLine, action: nil, keyEquivalent: "")
        activity.isEnabled = false
        detailsMenu.addItem(activity)

        // Explains why automatic awake is or is not held (off, battery, no
        // work, paused by lock/sleep/session, or unavailable). Read-only: it is
        // not a second mode selector.
        let autoDetail = NSMenuItem(title: autoDetailLine, action: nil, keyEquivalent: "")
        autoDetail.isEnabled = false
        detailsMenu.addItem(autoDetail)

        let powerSource = NSMenuItem(title: powerSourceLine, action: nil, keyEquivalent: "")
        powerSource.isEnabled = false
        detailsMenu.addItem(powerSource)
        powerSourceItem = powerSource

        let energyMode = NSMenuItem(title: energyModeLine, action: nil, keyEquivalent: "")
        energyMode.isEnabled = false
        detailsMenu.addItem(energyMode)
        energyModeItem = energyMode

        details.submenu = detailsMenu
        menu.addItem(details)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: active ? "Stop and Quit" : "Quit",
                              action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = !busy
        menu.addItem(quit)
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
    }

    // MARK: - Actions

    @objc func startFromMenu(_ sender: NSMenuItem) {
        // A new request made while the session is ineligible is created paused,
        // so it never even momentarily creates an awake assertion. The session
        // is re-read first so a lock that arrived since the last menu refresh is
        // respected.
        refreshSessionNow()
        let sessionAllows = AwakeGate.sessionAllowsAssertion(sessionState)
        performAction("on", seconds: sender.tag, paused: !sessionAllows)
    }

    // MARK: - Custom hours

    /// Custom hours… only ever starts a new session; an active session keeps its
    /// Stop action, so extension is intentionally not offered.
    @objc func startCustomFromMenu(_ sender: NSMenuItem) {
        guard !busy else { return }
        guard let hours = promptForCustomHours() else { return } // Cancel changes nothing.
        refreshSessionNow()
        let sessionAllows = AwakeGate.sessionAllowsAssertion(sessionState)
        performAction("on", seconds: hours * 3600, paused: !sessionAllows)
    }

    /// Native bounded input dialog. Returns the chosen whole hours, or nil when
    /// the user cancels. An out-of-contract entry is explained and re-prompted;
    /// Cancel at any point leaves work-mode state untouched.
    func promptForCustomHours() -> Int? {
        var entry = String(CustomHours.default)
        while true {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Start Codex Work Mode for custom hours"
            alert.informativeText = """
                Enter whole hours from \(CustomHours.minimum) to \(CustomHours.maximum). \
                Default \(CustomHours.default).
                """
            alert.addButton(withTitle: "Start")
            alert.addButton(withTitle: "Cancel")
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
        alert.messageText = "Enter whole hours from \(CustomHours.minimum) to \(CustomHours.maximum)"
        let detail = trimmed.isEmpty
            ? "Nothing was entered."
            : "“\(trimmed)” is not a whole number of hours in range."
        alert.informativeText = "\(detail) Use a whole number such as \(CustomHours.default)."
        alert.addButton(withTitle: "OK")
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
        alert.messageText = "Codex Work Mode could not be changed"
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = detail.isEmpty ? "The helper did not report a result." : detail
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
