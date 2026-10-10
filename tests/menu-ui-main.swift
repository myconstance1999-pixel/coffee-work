// Isolated native construction/clock checks and an offscreen layout preview.
// The preview is not installed UI acceptance. Nothing here creates a window,
// status bar, visible menu, OS input, caffeinate, screen saver or
// authentication request.
let native = NSApplication.shared
native.setActivationPolicy(.prohibited)
let root = FileManager.default.temporaryDirectory.appendingPathComponent("coffee-menu-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let preview = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
var failures = 0
func check(_ name: String, _ value: Bool) {
    print("\(value ? "PASS" : "FAIL") \(name)")
    if !value { failures += 1 }
}
func makeApp() -> WorkModeApp {
    let result = WorkModeApp()
    result.folder = root.appendingPathComponent(UUID().uuidString)
    result.statusReadable = true
    result.sessionState = .active
    result.powerAvailability = .external
    result.activityStatus = .idle
    result.autoEnabled = true
    result.powerStatus = PowerStatus(source: .powerAdapter, energyMode: .automatic)
    result.guiTimer.makeProcess = { _ in
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        return child
    }
    return result
}
func menuFor(_ app: WorkModeApp) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    app.populateMenu(menu)
    return menu
}
func find(_ menu: NSMenu, _ title: String) -> NSMenuItem? { menu.items.first { $0.title == title } }
func pump(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

// Paint the production menu's status/note views and native item contents into
// an offscreen canvas. Standard action rows are a layout approximation.
func render(_ menu: NSMenu, _ name: String) throws {
    let heights = menu.items.map { $0.isSeparatorItem ? CGFloat(10) : ($0.view?.frame.height ?? 26) }
    let total = heights.reduce(0, +) + 16
    let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: total))
    canvas.appearance = NSAppearance(named: .darkAqua)
    canvas.wantsLayer = true
    canvas.layer?.backgroundColor = NSColor(calibratedWhite: 0.17, alpha: 1).cgColor
    canvas.layer?.cornerRadius = 12
    var y = total - 8
    for (item, height) in zip(menu.items, heights) {
        y -= height
        if item.isSeparatorItem {
            let line = NSBox(frame: NSRect(x: 18, y: y + 4, width: 324, height: 1))
            line.boxType = .separator
            canvas.addSubview(line)
        } else if let source = item.view {
            // NSMenu owns the original custom view's frame. Clone its native
            // contents for offscreen drawing so menu layout cannot reset it.
            let view: NSView
            if let card = source as? WorkMenuStatusView {
                view = WorkMenuStatusView(MenuPresentation(heading: card.heading.stringValue,
                    timing: card.timing.stringValue, effect: card.effect.stringValue, note: card.note.stringValue))
            } else {
                view = NSView(frame: NSRect(origin: .zero, size: source.frame.size))
                for field in source.subviews.compactMap({ $0 as? NSTextField }) {
                    let copy = NSTextField(labelWithString: field.stringValue)
                    copy.font = field.font
                    copy.textColor = field.textColor
                    copy.frame = field.frame
                    view.addSubview(copy)
                }
            }
            view.frame.origin = NSPoint(x: 10, y: y)
            canvas.addSubview(view)
        } else {
            let label = NSTextField(labelWithString: item.title)
            label.font = .systemFont(ofSize: 13)
            label.textColor = item.isEnabled ? .labelColor : .secondaryLabelColor
            label.frame = NSRect(x: 34, y: y + 4, width: 290, height: 19)
            canvas.addSubview(label)
            let marker = NSTextField(labelWithString: item.state == .on ? "✓" : "")
            marker.font = .systemFont(ofSize: 13, weight: .semibold)
            marker.frame = NSRect(x: 12, y: y + 4, width: 20, height: 19)
            canvas.addSubview(marker)
            if item.submenu != nil {
                let arrow = NSTextField(labelWithString: "›")
                arrow.font = .systemFont(ofSize: 18)
                arrow.frame = NSRect(x: 335, y: y + 1, width: 16, height: 24)
                canvas.addSubview(arrow)
            }
        }
    }
    canvas.layoutSubtreeIfNeeded()
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720,
        pixelsHigh: Int(total * 2), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = canvas.bounds.size
    canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Offscreen PNG failed") }
    try data.write(to: preview.appendingPathComponent(name + ".png"))
}

let idle = makeApp()
var menu = menuFor(idle)
check("normal idle names system screen-saver behavior", idle.menuPresentation().heading == "正常待机"
      && idle.menuPresentation().effect == "屏保与息屏按系统设置")
idle.startMenuClock()
check("idle creates no clock poll", idle.menuClock == nil)
check("automatic toggle keeps its target and checked state", find(menu, "自动保持后台工作（接通电源）")?.state == .on
      && find(menu, "自动保持后台工作（接通电源）")?.action == #selector(WorkModeApp.toggleAutoAwake))
let manual = find(menu, "手动后台计时")!.submenu!
let oldPresets = manual.items.filter { $0.action == #selector(WorkModeApp.startFromMenu(_:)) }
check("original manual choices keep duration and action", oldPresets.map(\.tag) == [3600, 14400, 28800]
      && oldPresets.allSatisfy(\.isEnabled)
      && manual.items.contains { $0.action == #selector(WorkModeApp.startCustomFromMenu(_:)) })
let choices = find(menu, "保持屏幕显示")!.submenu!
let displayPresets = choices.items.filter { $0.action == #selector(WorkModeApp.startGUIWork(_:)) }
check("display choices are 30 minutes and 1/4/8 hours, distinct from manual actions",
      displayPresets.map(\.tag) == [1800, 3600, 14400, 28800]
      && displayPresets.map(\.title) == ["30 分钟", "1 小时", "4 小时", "8 小时"]
      && displayPresets.allSatisfy(\.isEnabled))
check("display choices add custom whole hours and a distinct until-stopped request",
      choices.items.contains { $0.action == #selector(WorkModeApp.startDisplayCustomFromMenu(_:)) }
      && choices.items.contains { $0.action == #selector(WorkModeApp.startDisplayUntilStopped(_:))
                                  && $0.title == "直到我关闭" })
check("display choice explains screen-saver release, fixed pause deadline and battery availability",
      choices.items.contains { $0.title.contains("自动屏保会暂缓") }
      && choices.items.contains { $0.title.contains("可能立即屏保或息屏") }
      && choices.items.contains { $0.title.contains("手动屏保与锁屏仍可生效") }
      && choices.items.contains { $0.title.contains("原结束时间不变") }
      && choices.items.contains { $0.title.contains("低电量模式") })
check("task uncertainty is in secondary menu without engineering wording",
      !menu.items.contains { $0.title.contains("任务：") }
      && find(menu, "更多状态与日志")!.submenu!.items.contains { $0.title == "Work/圆点任务：暂不能自动识别" })
check("screen-saver action is constructed and not invoked",
      menu.items.contains { $0.title == "立即启动屏保"
                            && $0.action == #selector(WorkModeApp.startScreenSaver)
                            && $0.target === idle }
      && menu.items.contains { $0.title == "后台任务会继续，锁屏与息屏仍按 macOS 设置" })
try render(menu, "normal-menu")
try render(choices, "desktop-choices")
for state in [SessionState.locked, .sleeping, .inactive, .unknown] {
    idle.sessionState = state
    check("display start is disabled for \(state)", find(menuFor(idle), "保持屏幕显示")?.isEnabled == false)
}
idle.sessionState = .active
idle.powerAvailability = .battery
idle.powerStatus = PowerStatus(source: .battery, energyMode: .lowPower)
check("display start stays available on battery and in Low Power Mode",
      find(menuFor(idle), "保持屏幕显示")?.isEnabled == true)
idle.powerAvailability = .unknown
check("display start does not depend on a readable power source",
      find(menuFor(idle), "保持屏幕显示")?.isEnabled == true)
idle.powerAvailability = .external
idle.powerStatus = PowerStatus(source: .powerAdapter, energyMode: .automatic)
idle.statusReadable = false
check("unreadable helper is not reported as normal idle", idle.menuPresentation().heading != "正常待机")
check("display start does not depend on helper status", find(menuFor(idle), "保持屏幕显示")?.isEnabled == true)
idle.statusReadable = true
idle.autoHeld = true
check("automatic background hold does not claim display hold", idle.menuPresentation().heading == "后台自动保持中"
      && idle.menuPresentation().effect.contains("屏保与息屏照常"))
idle.autoHeld = false

let background = makeApp()
background.manualState = .active(expiry: "fixture")
background.manualExpiryDeadline = Date().timeIntervalSince1970 + 3600
menu = menuFor(background)
check("background timer stop stays primary and display start stays available",
      menu.items[1].action == #selector(WorkModeApp.stopMode)
      && find(menu, "保持屏幕显示")?.isEnabled == true
      && background.menuPresentation().effect.contains("屏保与息屏照常"))
try render(menu, "background-menu")
background.manualState = .paused(expiry: "fixture", remaining: 100)
check("paused background never claims held awake", background.menuPresentation().heading == "后台计时已暂停"
      && background.menuPresentation().effect.contains("保持已暂停"))

let desktop = makeApp()
defer { desktop.menuClock?.invalidate(); desktop.guiTimer.stop(reason: "test_cleanup") }
check("fixture desktop starts with harmless owned sleep process", desktop.guiTimer.start(seconds: 1800, eligible: true))
let deadline = desktop.guiTimer.deadline!
menu = menuFor(desktop)
check("desktop stop is primary and manual start stays available",
      menu.items[1].action == #selector(WorkModeApp.stopGUIWork)
      && menu.items[1].title == "结束屏幕显示保持，恢复屏保/息屏"
      && find(menu, "手动后台计时")?.isEnabled == true
      && find(menu, "自动保持后台工作（接通电源）")?.state == .on)
check("active desktop names temporary screen-saver deferral", desktop.menuPresentation().heading == "屏幕显示保持中"
      && desktop.menuPresentation().effect == "保持显示 · 自动屏保暂缓"
      && desktop.menuPresentation().note.contains("可能立即屏保或息屏"))
let earlier = desktop.menuPresentation(now: deadline - 100)
let later = desktop.menuPresentation(now: deadline - 90)
check("countdown decreases without moving displayed deadline", earlier.timing.contains("01:40")
      && later.timing.contains("01:30")
      && earlier.timing.components(separatedBy: " · ").last == later.timing.components(separatedBy: " · ").last
      && desktop.guiTimer.deadline == deadline)
check("closed-menu summary does not show a stale countdown", earlier.compactSummary == later.compactSummary
      && !earlier.compactSummary.contains("剩余"))
let card = desktop.statusCard!
let original = card.timing.stringValue
let originalItem = menu.items[1]
desktop.startMenuClock()
pump(1.2)
check("open-menu clock updates labels without rebuilding actions", card.timing.stringValue != original
      && desktop.statusCard === card && menu.items[1] === originalItem)
desktop.menuDidClose(menu)
check("close invalidates presentation clock", desktop.menuClock == nil)
try render(menu, "desktop-menu")
desktop.guiTimer.reconcile(eligible: false)
menu = menuFor(desktop)
check("paused desktop reports released display and original deadline", desktop.menuPresentation().heading == "屏幕显示已暂停"
      && desktop.menuPresentation().effect.contains("显示保持已释放") && desktop.guiTimer.deadline == deadline
      && menu.items[1].action == #selector(WorkModeApp.stopGUIWork))
try render(menu, "paused-desktop-menu")

// Both explicit sources configured at once: two truthful statuses, two stops.
let both = makeApp()
defer { both.guiTimer.stop(reason: "test_cleanup") }
both.manualState = .active(expiry: "fixture")
both.manualExpiryDeadline = Date().timeIntervalSince1970 + 3600
both.autoHeld = true
check("fixture display hold starts beside the background timer", both.guiTimer.start(seconds: 1800, eligible: true))
menu = menuFor(both)
check("both configured sources keep their own stop action",
      menu.items[1].action == #selector(WorkModeApp.stopGUIWork)
      && menu.items[1].title.contains("后台仍保持唤醒")
      && menu.items[2].isEnabled == false && menu.items[2].title.contains("后台计时中")
      && menu.items[3].action == #selector(WorkModeApp.stopMode))
check("both configured sources keep truthful statuses",
      both.menuPresentation().heading == "屏幕显示保持中"
      && both.menuPresentation().note.contains("后台自动保持中")
      && both.backgroundStatusItem?.title.contains("后台计时中") == true)
check("the display stop row never claims normal sleep while background remains",
      !menu.items[1].title.contains("恢复屏保") && !menu.items[1].title.contains("休眠"))
try render(menu, "both-sources-menu")

// Until-stopped is distinct from off and from a finite request, with no fake
// countdown, and it is the only shape that starts no presentation clock.
let foreverMenu = makeApp()
defer { foreverMenu.guiTimer.stop(reason: "test_cleanup") }
let startedForever = foreverMenu.guiTimer.startUntilStopped(eligible: true)
menu = menuFor(foreverMenu)
let foreverPresentation = foreverMenu.menuPresentation(now: 123456)
check("fixture until-stopped request starts one bounded lease", startedForever
      && foreverMenu.guiTimer.configured && foreverMenu.guiTimer.untilStopped)
check("until-stopped shows a stable state and never a fake countdown",
      foreverPresentation.timing == "直到我关闭"
      && !foreverPresentation.timing.contains("剩余")
      && foreverPresentation.compactSummary.contains("直到我关闭")
      && !foreverPresentation.compactSummary.contains("剩余"))
check("until-stopped still offers its own stop action",
      menu.items[1].action == #selector(WorkModeApp.stopGUIWork))
foreverMenu.startMenuClock()
check("an until-stopped-only row starts no presentation clock", foreverMenu.menuClock == nil)
try render(menu, "until-stopped-menu")

// Defect regression: once the owned lease is gone, the card must say the hold is
// released with a pending retry, never claim a live hold or a lock/session pause,
// and never fabricate a countdown, while its own stop action stays available.
foreverMenu.guiTimer.reconcile(eligible: false)
let pausedForever = foreverMenu.menuPresentation(now: 123456)
check("a session pause keeps its own truthful explanation",
      pausedForever.effect == "显示保持已释放 · 直到我关闭"
      && pausedForever.note.contains("解除暂停"))
foreverMenu.guiTimer.makeProcess = { _ in
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["0.15"]
    return child
}
foreverMenu.guiTimer.reconcile(eligible: true)
pump(0.6)
let retryPending = foreverMenu.menuPresentation(now: 123456)
check("a lost until-stopped lease is reported as released with a pending retry",
      foreverMenu.guiTimer.configured && foreverMenu.guiTimer.untilStopped
      && !foreverMenu.guiTimer.held && foreverMenu.guiTimer.awaitingLeaseRetry
      && retryPending.heading == "屏幕显示已暂停"
      && retryPending.effect == "显示保持已释放 · 正在重试"
      && retryPending.timing == "直到我关闭" && !retryPending.timing.contains("剩余"))
check("a pending retry never claims a lock/session pause fixed it",
      retryPending.note.contains("自动重试") && !retryPending.note.contains("解除暂停"))
foreverMenu.guiTimer.makeProcess = { _ in
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["10"]
    return child
}
menu = menuFor(foreverMenu)
check("a released until-stopped request still offers its own stop action",
      menu.items[1].action == #selector(WorkModeApp.stopGUIWork)
      && menu.items[1].title == "结束屏幕显示保持，恢复屏保/息屏")
try render(menu, "until-stopped-retry-menu")

// The user screen-saver action stops only the explicit display hold, is never
// invoked here, and never claims success when the launcher fails.
let screenSaver = makeApp()
defer { screenSaver.guiTimer.stop(reason: "test_cleanup") }
_ = screenSaver.guiTimer.start(seconds: 1800, eligible: true)
screenSaver.manualState = .active(expiry: "fixture")
screenSaver.manualExpiryDeadline = Date().timeIntervalSince1970 + 3600
screenSaver.launchScreenSaver = { false }
check("a failed screen-saver launch reports failure and still stops the display hold",
      !screenSaver.requestScreenSaver() && !screenSaver.guiTimer.configured
      && screenSaver.manualState.isActive && screenSaver.manualExpiryDeadline != nil)
screenSaver.launchScreenSaver = { true }
_ = screenSaver.guiTimer.start(seconds: 1800, eligible: true)
check("a requested screen-saver launch stops the display hold only",
      screenSaver.requestScreenSaver() && !screenSaver.guiTimer.configured
      && screenSaver.manualState.isActive && screenSaver.autoEnabled)

desktop.guiTimer.stop(reason: "test_cleanup")
check("cancel returns to normal idle without disabling automatic mode", desktop.menuPresentation().heading == "正常待机"
      && desktop.autoEnabled && !desktop.guiTimer.configured)
check("expired formatting never becomes negative", !MenuPresentation.timing(deadline: 100, now: 120).contains("-"))
check("headless test has no windows or installed status item", native.windows.isEmpty
      && idle.item == nil && background.item == nil && desktop.item == nil)
print("\(failures) menu UI failure(s); offscreen previews: \(preview.path)")
exit(failures == 0 ? 0 : 1)
