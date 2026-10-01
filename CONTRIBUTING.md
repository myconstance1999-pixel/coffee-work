# Contributing

Thanks for helping with Coffee Work. This is a small, deliberately bounded
macOS utility, so a few rules matter more than usual.

## Ground rules

* **Do not change runtime behavior casually.** `MenuBar.swift`, `toggle.zsh`, and
  `activity-hook.py` are the shipped runtime. Behavior changes need an explicit
  decision and fresh acceptance evidence; a source-only refactor still needs the
  tests to pass.
* **Keep tests isolated.** No test may point at the production app, the live
  support folder (`~/Library/Application Support/Codex Work Mode`), the live
  `~/.codex/hooks.json`, or the installed app. Use the private state roots and
  fixtures the suite already creates under `build/`.
* **Keep process safety honest.** The helper lifecycle tests use the real
  `/bin/ps` and the real `/usr/bin/caffeinate`. Do not add a process-table shim
  or otherwise make a safety check pass by faking its input. Cleanup must target
  exact test-owned identity only: helper-owned timers are released through the
  helper's own stored-signature path, stand-in processes are tracked and
  signalled only while their recorded `/bin/ps` signature still matches, and the
  faulted section-H helper runs in its own dedicated session/process group. No
  cleanup step may ever signal processes by a global command or duration
  pattern. If the environment cannot run `/bin/ps`, the lifecycle script reports
  `BLOCKED` and exits non-zero on purpose; run it from an unconfined shell
  instead of weakening it.
* **No personal paths or secrets in committed files.** Hooks are rendered by
  `hooks/render-hooks.py` for the installing user; never commit a rendered
  `hooks.json`, a home directory, or session/activity data.
* **English only** in source comments, docs, and commit messages.

## Layout

```
MenuBar.swift              menu-bar app (AppKit, arm64, macOS 13+)
toggle.zsh                 manual timer helper (owns the caffeinate session)
activity-hook.py           Codex hook receiver (stdlib Python 3)
build.sh                   portable staged build of dist/Codex Work Mode.app
bundle/                    public bundle metadata + icon (Info.plist, PkgInfo, AppIcon.icns)
hooks/                     user-portable hooks template + renderer
tests/                     deterministic test suite
qa/                        optional isolated acceptance harness
```

## Build

```sh
./build.sh
```

Outputs stay under `dist/` and `build/`, both git-ignored. The build never
installs, launches, trusts, or registers anything.

## Test

The focused entry point runs the Swift parser suites, the receiver tests, the
portable hooks-renderer tests, the helper lifecycle tests, the source-contract
checks, and the read-only session observer:

```sh
./tests/validate.sh
```

Individual pieces:

```sh
# Receiver: ancestry filter, reducer, privacy, permissions, locking.
/usr/bin/python3 tests/activity-hook-tests.py

# Hooks renderer: shell quoting, refusal, exclusive creation.
/usr/bin/python3 tests/render-hooks-tests.py

# Manual helper lifecycle against a private state root (needs the real /bin/ps).
/bin/zsh tests/helper-lifecycle-tests.sh

# Read-only session/power observer (compiles the production adapters).
/bin/mkdir -p build
/usr/bin/sed '/^let app = NSApplication.shared$/,$d' MenuBar.swift > build/ObserverPrefix.swift
/bin/cat qa/session-observer.swift >> build/ObserverPrefix.swift
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 -framework AppKit \
    -framework CoreGraphics -framework IOKit build/ObserverPrefix.swift \
    -o build/session-observer
./build/session-observer --seconds 5
```

`tests/validate.sh` writes its compiler output under `build/`. The lifecycle
script replaces exactly one line of the production helper (`state_dir=`) and
nothing else; if that seam ever grows, the script's normalization gate fails.

## Optional isolated QA harness

`qa/build-qa.sh` builds a separate `Codex Work Mode QA.app` from the current
production source with fixture power/session adapters and an isolated state
root. It never launches the app, runs the helper, or references the live
support folder. It is a controller-side tool and is not required for the normal
test run.

## Pull requests

* Describe the observable behavior change and the command you ran to verify it.
* Include raw pass/fail output for the affected tests, not just a summary.
* Do not include generated build/QA artifacts (`dist/`, `build/`, `qa/dist/`,
  `qa/state/`, `qa/MenuBar.isolated.swift`) in a change.
* Keep docs honest: no fabricated badges, screenshots, repository URLs,
  benchmark claims, or license grants.
