// QA-only behavioral fixtures for the production PowerStatusParser.
//
// This file is concatenated after the production source (with the trailing
// NSApplication bootstrap removed), so it exercises the real parser in
// MenuBar.swift. Every fixture is a complete `system_profiler SPPowerDataType
// -json` payload and is fed through the same `status(exitStatus:data:)` entry
// point the app uses, so command-failure handling is covered too.

var powerFailures = 0

func powerCheck(
    _ name: String,
    _ data: Data,
    exitStatus: Int32 = 0,
    pmsetData: Data = Data(),
    pmsetExitStatus: Int32 = 0,
    source: PowerStatus.Source,
    energy: PowerStatus.EnergyMode
) {
    let got = PowerStatusParser.status(
        exitStatus: exitStatus,
        data: data,
        pmsetExitStatus: pmsetExitStatus,
        pmsetData: pmsetData
    )
    let ok = got.source == source && got.energyMode == energy
    if !ok { powerFailures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name) -> \(got.source.rawValue) / \(got.energyMode.rawValue)"
        + " (expected \(source.rawValue) / \(energy.rawValue))")
}

/// Builds a payload with two raw `sppower_information` sections.
func powerPayload(ac: String, battery: String) -> Data {
    Data(("{\"SPPowerDataType\":[{\"_name\":\"sppower_information\","
        + "\"AC Power\":\(ac),\"Battery Power\":\(battery)}]}").utf8)
}

/// Builds one power section. A nil argument omits the key, which models a
/// missing flag or a missing `Current Power Source`.
func powerSection(current: String?, high: String?, low: String?) -> String {
    var fields: [String] = []
    if let current { fields.append("\"Current Power Source\":\"\(current)\"") }
    if let high { fields.append("\"HighPowerMode\":\"\(high)\"") }
    if let low { fields.append("\"LowPowerMode\":\"\(low)\"") }
    return "{" + fields.joined(separator: ",") + "}"
}

// MARK: - pmset fixtures
//
// `pmset -g custom` output, typed out exactly as the real command prints it:
// one `Battery Power:` block then one `AC Power:` block, each with a string of
// `powermode` lines. The raw `powermode` argument lets a fixture duplicate or
// malform the key, and a nil block omits that whole section header.

func pmsetPayload(ac: String, battery: String) -> Data {
    Data(("Battery Power:\n" + battery + "\nAC Power:\n" + ac + "\n").utf8)
}

/// One `pmset` config line; `raw` may be malformed on purpose.
func pmsetMode(_ raw: String) -> String {
    "  powermode  \(raw)"
}

/// Both sections present; AC carries `acValue` and battery `batteryValue`.
func pmsetBoth(acValue: String = "0", batteryValue: String = "0") -> Data {
    pmsetPayload(
        ac: "  sleep  1\n" + pmsetMode(acValue),
        battery: "  sleep  1\n" + pmsetMode(batteryValue)
    )
}

/// Both sections present but without any `powermode` key: the pre-powermode
/// `pmset` shape an older macOS produces, which is the legacy fallback path.
func pmsetWithoutMode() -> Data {
    pmsetPayload(ac: "  sleep  1\n  displaysleep  10",
                 battery: "  sleep  1\n  displaysleep  2")
}

/// AC active, battery inactive, with the given AC flags. The default `pmset`
/// payload has both sections but no `powermode`, so the profiler flags decide.
func acActive(high: String? = "No", low: String? = "No") -> Data {
    powerPayload(
        ac: powerSection(current: "TRUE", high: high, low: low),
        battery: powerSection(current: "FALSE", high: "No", low: "No")
    )
}

// MARK: - AC vs battery

powerCheck("AC active / automatic", acActive(),
           pmsetData: pmsetWithoutMode(),
           source: .powerAdapter, energy: .automatic)

powerCheck("battery active / low power",
           powerPayload(ac: powerSection(current: "FALSE", high: "No", low: "No"),
                        battery: powerSection(current: "TRUE", high: "No", low: "Yes")),
           pmsetData: pmsetWithoutMode(),
           source: .battery, energy: .lowPower)

// MARK: - All three energy modes (profiler flags, no powermode key)

powerCheck("AC high power", acActive(high: "Yes", low: "No"),
           pmsetData: pmsetWithoutMode(),
           source: .powerAdapter, energy: .highPower)
powerCheck("AC low power", acActive(high: "No", low: "Yes"),
           pmsetData: pmsetWithoutMode(),
           source: .powerAdapter, energy: .lowPower)
powerCheck("AC automatic", acActive(high: "No", low: "No"),
           pmsetData: pmsetWithoutMode(),
           source: .powerAdapter, energy: .automatic)

// MARK: - Authoritative `powermode` overrides incorrect profiler flags
//
// On macOS 27 the profiler reports HighPowerMode=No / LowPowerMode=Yes for
// every profile, so a Low Power flag can be present while the machine is
// actually in High Power. `powermode 2` must win.

powerCheck("pmset 2 wins over profiler low flag",
           acActive(high: "No", low: "Yes"),
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           source: .powerAdapter, energy: .highPower)

powerCheck("pmset 1 wins over profiler high flag",
           acActive(high: "Yes", low: "No"),
           pmsetData: pmsetBoth(acValue: "1", batteryValue: "2"),
           source: .powerAdapter, energy: .lowPower)

powerCheck("pmset 0 wins over profiler high flag",
           acActive(high: "Yes", low: "No"),
           pmsetData: pmsetBoth(acValue: "0", batteryValue: "1"),
           source: .powerAdapter, energy: .automatic)

powerCheck("pmset 2 with profiler flags unavailable",
           acActive(high: nil, low: nil),
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "0"),
           source: .powerAdapter, energy: .highPower)

powerCheck("battery active uses battery section: pmset 1",
           powerPayload(ac: powerSection(current: "FALSE", high: "No", low: "No"),
                        battery: powerSection(current: "TRUE", high: "No", low: "No")),
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           source: .battery, energy: .lowPower)

// MARK: - Only the selected section is consulted

powerCheck("selected AC section has no powermode: legacy flags",
           acActive(),
           pmsetData: pmsetPayload(ac: "  sleep  1", battery: "  powermode  1"),
           source: .powerAdapter, energy: .automatic)

powerCheck("selected AC section header absent: mode unavailable",
           acActive(high: "Yes", low: "No"),
           pmsetData: Data("Battery Power:\n  powermode  1\n".utf8),
           source: .powerAdapter, energy: .unavailable)

powerCheck("out-of-range powermode in the unselected section is ignored",
           acActive(high: "Yes", low: "No"),
           pmsetData: pmsetPayload(ac: "  sleep  1", battery: "  powermode  999"),
           source: .powerAdapter, energy: .highPower)

// MARK: - Unknown, duplicate, or malformed modern mode never falls back

powerCheck("unknown powermode value",
           acActive(high: "Yes", low: "No"),
           pmsetData: pmsetBoth(acValue: "3", batteryValue: "0"),
           source: .powerAdapter, energy: .unavailable)

powerCheck("non-numeric powermode value",
           acActive(high: "Yes", low: "No"),
           pmsetData: pmsetBoth(acValue: "two", batteryValue: "0"),
           source: .powerAdapter, energy: .unavailable)

powerCheck("malformed powermode line",
           acActive(high: "Yes", low: "No"),
           pmsetData: pmsetBoth(acValue: "", batteryValue: "0"),
           source: .powerAdapter, energy: .unavailable)

powerCheck("trailing garbage after the powermode value",
           acActive(high: "Yes", low: "No"),
           pmsetData: pmsetBoth(acValue: "2x", batteryValue: "0"),
           source: .powerAdapter, energy: .unavailable)

powerCheck("duplicate powermode in selected section",
           acActive(high: "Yes", low: "No"),
           pmsetData: pmsetPayload(ac: "  powermode  2\n  powermode  2",
                                   battery: "  powermode  1"),
           source: .powerAdapter, energy: .unavailable)

powerCheck("duplicate conflicting powermode values",
           acActive(high: "Yes", low: "No"),
           pmsetData: pmsetPayload(ac: "  powermode  2\n  powermode  1",
                                   battery: "  powermode  1"),
           source: .powerAdapter, energy: .unavailable)

// MARK: - Failed or empty pmset keeps the profiler source, mode unavailable

powerCheck("pmset failed preserves valid source",
           acActive(),
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           pmsetExitStatus: 1,
           source: .powerAdapter, energy: .unavailable)

powerCheck("pmset empty output preserves valid source",
           acActive(high: "No", low: "Yes"),
           pmsetData: Data(),
           source: .powerAdapter, energy: .unavailable)

// MARK: - Unknown, missing, or conflicting source (pmset never consulted)

powerCheck("unknown source value",
           powerPayload(ac: powerSection(current: "MAYBE", high: "No", low: "No"),
                        battery: powerSection(current: "FALSE", high: "No", low: "No")),
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           source: .unavailable, energy: .unavailable)

powerCheck("lowercase source value is not TRUE",
           powerPayload(ac: powerSection(current: "true", high: "No", low: "No"),
                        battery: powerSection(current: "FALSE", high: "No", low: "No")),
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           source: .unavailable, energy: .unavailable)

powerCheck("both sources TRUE is contradictory",
           powerPayload(ac: powerSection(current: "TRUE", high: "No", low: "No"),
                        battery: powerSection(current: "TRUE", high: "No", low: "No")),
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           source: .unavailable, energy: .unavailable)

powerCheck("neither source TRUE",
           powerPayload(ac: powerSection(current: "FALSE", high: "No", low: "No"),
                        battery: powerSection(current: "FALSE", high: "No", low: "No")),
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           source: .unavailable, energy: .unavailable)

powerCheck("missing Current Power Source",
           powerPayload(ac: powerSection(current: nil, high: "No", low: "No"),
                        battery: powerSection(current: "FALSE", high: "No", low: "No")),
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           source: .unavailable, energy: .unavailable)

// MARK: - Legacy profiler flags when pmset has no selected section

powerCheck("legacy: missing both flags",
           acActive(high: nil, low: nil),
           pmsetData: pmsetWithoutMode(),
           source: .powerAdapter, energy: .unavailable)

powerCheck("legacy: missing one flag",
           acActive(high: "No", low: nil),
           pmsetData: pmsetWithoutMode(),
           source: .powerAdapter, energy: .unavailable)

powerCheck("legacy: both flags Yes is contradictory",
           acActive(high: "Yes", low: "Yes"),
           pmsetData: pmsetWithoutMode(),
           source: .powerAdapter, energy: .unavailable)

powerCheck("legacy: non Yes/No flag value",
           acActive(high: "YES", low: "No"),
           pmsetData: pmsetWithoutMode(),
           source: .powerAdapter, energy: .unavailable)

powerCheck("legacy: simply unavailable flag value",
           acActive(high: "MAYBE", low: "No"),
           pmsetData: pmsetWithoutMode(),
           source: .powerAdapter, energy: .unavailable)

powerCheck("legacy: numeric flag value",
           powerPayload(ac: "{\"Current Power Source\":\"TRUE\",\"HighPowerMode\":1,\"LowPowerMode\":0}",
                        battery: powerSection(current: "FALSE", high: "No", low: "No")),
           pmsetData: pmsetWithoutMode(),
           source: .powerAdapter, energy: .unavailable)

// MARK: - Malformed or unreadable profiler output

powerCheck("malformed JSON",
           Data("{not json".utf8),
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           source: .unavailable, energy: .unavailable)

powerCheck("empty output",
           Data(),
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           source: .unavailable, energy: .unavailable)

powerCheck("missing sppower_information entry",
           Data("{\"SPPowerDataType\":[{\"_name\":\"spbattery_information\"}]}".utf8),
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           source: .unavailable, energy: .unavailable)

powerCheck("empty sppower_information",
           powerPayload(ac: "{}", battery: "{}"),
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           source: .unavailable, energy: .unavailable)

// MARK: - Command failure handling

powerCheck("profiler failed but payload valid", acActive(),
           exitStatus: 1,
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           source: .unavailable, energy: .unavailable)

powerCheck("profiler failed with empty output", Data(), exitStatus: 127,
           pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
           source: .unavailable, energy: .unavailable)

// MARK: - Desktop Mac with no battery sub-dictionary

powerCheck("AC only, no battery entry",
           Data(("{\"SPPowerDataType\":[{\"_name\":\"sppower_information\","
               + "\"AC Power\":{\"Current Power Source\":\"TRUE\",\"HighPowerMode\":\"No\",\"LowPowerMode\":\"No\"}}]}")
               .utf8),
           pmsetData: pmsetWithoutMode(),
           source: .powerAdapter, energy: .automatic)

// MARK: - Plugged in but not charging must still report the adapter

powerCheck(
    "plugged in, not charging stays AC",
    Data("""
    {"SPPowerDataType":[
      {"_name":"spbattery_information",
       "sppower_battery_charge_info":{"sppower_battery_is_charging":"FALSE","sppower_battery_fully_charged":"FALSE"}},
      {"_name":"sppower_information",
       "AC Power":{"Current Power Source":"TRUE","HighPowerMode":"No","LowPowerMode":"Yes"},
       "Battery Power":{"Current Power Source":"FALSE","HighPowerMode":"No","LowPowerMode":"Yes"}}
    ]}
    """.utf8),
    pmsetData: pmsetBoth(acValue: "2", batteryValue: "1"),
    source: .powerAdapter,
    energy: .highPower
)


if powerFailures > 0 {
    print("FAILED: \(powerFailures) PowerStatus check(s)")
    exit(1)
}
print("PASS: all PowerStatus behavioral checks")
exit(0)
