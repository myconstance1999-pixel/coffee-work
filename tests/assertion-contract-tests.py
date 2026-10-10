"""Keep the existing static safety guard scoped to the two accepted owners.

v1.8 makes the explicit display request independent of the manual/automatic
sources and gives it two bounded shapes: one finite child per absolute deadline,
and bounded owner-tied leases for an until-stopped request. The guard is widened
narrowly for those two shapes while every previous automatic/manual guarantee is
kept: automatic stays idle-only with an owner lifetime bound, no `-u`/`-s` may
appear in either owner, display children stay `-d -i -t <= 86400 -w <app pid>`,
every lease delay is measured on the timer's injected clock, and the app still
writes nothing outside the bounded diagnostic logger/exporter.
"""
from pathlib import Path
import re


def validate(source):
    start = source.index("\nfinal class GUIWorkTimer {")
    end = source.index("\nfinal class WorkModeApp:", start)
    gui = source[start:end]
    background = source[:start] + source[end:]
    assert source.count('"/usr/bin/caffeinate"') == 2, "unexpected assertion executable reference"
    assert background.count('"/usr/bin/caffeinate"') == 1, "automatic executable must stay outside GUI timer"
    assert not re.search(r'"-(?:d|u|s)"', background), "display/user/system flag outside finite GUI timer"
    assert re.search(r'process\.arguments\s*=\s*\[\s*"-i",\s*"-t",\s*String\(Int\(AutoAwakeEngine\.assertionSeconds\)\),\s*"-w",\s*String\(ProcessInfo\.processInfo\.processIdentifier\)', background), "automatic lease lost its idle, timeout or parent bound"

    # Shared display bounds and the single session/duration gate.
    assert "static let minimumSeconds = 1" in gui, "display request lost its lower duration bound"
    assert "static let maximumSeconds = 86400" in gui, "display request lost its 86400 second upper bound"
    assert re.search(r'\(Self\.minimumSeconds\.\.\.Self\.maximumSeconds\)\.contains\(seconds\)', gui), "display request lost its session/duration gate"

    # Neither owner may assert user activity or prevent explicit system sleep.
    assert not re.search(r'"-(?:u|s)"', gui), "display timer cannot assert user activity or prevent explicit system sleep"

    # Finite display shape: one bounded, owner-tied child per absolute deadline.
    assert re.search(r'makeProcess\(\["-d",\s*"-i",\s*"-t",\s*String\(remaining\),\s*"-w",\s*String\(ProcessInfo\.processInfo\.processIdentifier\)\]\)', gui), "finite display request lost its display, idle or parent bound"

    # Until-stopped display shape: only bounded owner-tied leases, renewed
    # strictly before the lease bound expires.
    assert re.search(r'static let leaseSeconds = (\d+)', gui), "until-stopped lease bound missing"
    assert re.search(r'static let renewalSeconds: Double = (\d+)', gui), "until-stopped renewal point missing"
    lease = int(re.search(r'static let leaseSeconds = (\d+)', gui).group(1))
    renew = int(re.search(r'static let renewalSeconds: Double = (\d+)', gui).group(1))
    assert renew < lease, "until-stopped renewal must happen before the lease expires"
    assert lease <= 86400, "until-stopped lease must respect the shared display bound"
    assert re.search(r'makeProcess\(\["-d",\s*"-i",\s*"-t",\s*String\(Self\.leaseSeconds\),\s*"-w",\s*String\(ProcessInfo\.processInfo\.processIdentifier\)\]\)', gui), "until-stopped lease lost its display, idle, timeout or parent bound"

    # Every lease delay is measured against the timer's own injected clock. A
    # wall-clock `Date()` anywhere outside the single clock default would make an
    # injected deterministic test clock disagree with the timer and re-fire it
    # against unrelated wall time.
    assert re.search(r"let delay = max\(0, instant - now\(\)\)", gui), "lease renewal delay is not measured on the injected clock"
    assert gui.count("Date()") == 1, "display timer may read wall time only in the one injectable clock default"

    logger_start = source.index("\nfinal class DiagnosticLog {")
    logger_end = source.index("\n}", logger_start) + 2
    outside_logger = source[:logger_start] + source[logger_end:]
    assert not re.search(r'write\(to:|createFile\(atPath:|removeItem\(at:', outside_logger), "file mutation outside the bounded diagnostic logger/exporter"


source = Path("MenuBar.swift").read_text()
validate(source)
print("PASS: automatic assertion remains idle-only with timeout and owning-app lifetime")
print("PASS: display assertion is confined to the eligible, bounded finite/until-stopped timer")
print("PASS: app state remains read-only; file mutations are confined to diagnostics/export")

# Prove the revised guard rejects regressions in both owners instead of merely
# increasing the executable count or allowing display assertions everywhere.
# Display-owner controls are applied inside the GUIWorkTimer slice, because a
# whole-file replace would target AutoAwakeEngine's identically named
# `renewalSeconds` constant first and silently leave the display owner intact.
def display_mutation(base, old, new):
    start = base.index("\nfinal class GUIWorkTimer {")
    end = base.index("\nfinal class WorkModeApp:", start)
    gui = base[start:end]
    assert old in gui, "negative control did not reach the display owner"
    mutated = base[:start] + gui.replace(old, new, 1) + base[end:]
    assert mutated != base, "negative control did not change the source"
    return mutated


mutations = {
    "automatic display flag": source.replace('process.arguments = [\n            "-i",', 'process.arguments = [\n            "-d",', 1),
    "display missing parent bound": display_mutation(
        source, '"-w", String(ProcessInfo.processInfo.processIdentifier)', '"-w", "0"'),
    "display duration gate removed": display_mutation(
        source, '(Self.minimumSeconds...Self.maximumSeconds).contains(seconds) else', 'true else'),
    "display duration beyond 24 hours": display_mutation(
        source, 'static let maximumSeconds = 86400', 'static let maximumSeconds = 172800'),
    "until-stopped lease without display flag": display_mutation(
        source, 'makeProcess(["-d", "-i", "-t", String(Self.leaseSeconds),',
        'makeProcess(["-i", "-t", String(Self.leaseSeconds),'),
    "until-stopped lease beyond 24 hours": display_mutation(
        source, 'static let leaseSeconds = 300', 'static let leaseSeconds = 90000'),
    "until-stopped renewal after the lease": display_mutation(
        source, 'static let renewalSeconds: Double = 240', 'static let renewalSeconds: Double = 600'),
    "until-stopped renewal measured on wall time": display_mutation(
        source, "let delay = max(0, instant - now())", "let delay = max(0, instant - Date().timeIntervalSince1970)"),
    "user activity assertion in the display owner": display_mutation(
        source, 'makeProcess(["-d", "-i", "-t", String(Self.leaseSeconds),',
        'makeProcess(["-d", "-i", "-u", "-t", String(Self.leaseSeconds),'),
    "manual session write": source.replace('let session = folder.appendingPathComponent("session")', 'let session = folder.appendingPathComponent("session")\n            try? Data().write(to: session)', 1),
}
for name, mutation in mutations.items():
    assert mutation != source, "negative control did not reach its target"
    try:
        validate(mutation)
    except AssertionError:
        print("PASS: safety guard rejects " + name)
    else:
        raise AssertionError("safety guard accepted " + name)
