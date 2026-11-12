import AppKit
import Combine
import SwiftUI

// 菜单栏入口：一个 NSStatusItem 里依次排 盾牌 · 网速 · 日期 · 时间。
//
// 不用 MenuBarExtra：它的 label 只渲染第一张图 + 文字，多段图像（两行网速、彩色日期徽章）
// 会被丢掉。左键弹出原 MenuBarView 面板，右键是组件设置菜单（原 NetTimeBar 菜单）。
@MainActor
final class WgStatusBarController: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let client: DaemonClient
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings = MenuBarComponentSettings()
    private let networkMonitor = PhysicalNetworkMonitor()
    private let timeFormatter = MenuBarTimeFormatter()

    private let shieldView = MenuBarShieldView()
    private let speedView = MenuBarNetworkSpeedView()
    private let dateView = MenuBarDateBadgeView()
    private let timeView = MenuBarTimeView()

    private var panel: WgMenuBarPanel?
    private var outsideClickMonitor: Any?
    private var timer: Timer?
    private var clientObserver: AnyCancellable?
    private var lastDisplayedMinute: Int?
    private var allZonesMenu: NSMenu?

    init(client: DaemonClient) {
        self.client = client
        super.init()
        configureButton()
        applyDateStyle()
        _ = networkMonitor.sample()
        refreshAll()
        startTimer()
        // DaemonClient 每次发布变化后刷新盾牌形态；切到下一轮 runloop 读到的是新值。
        clientObserver = client.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateShield() }
        }
    }

    // MARK: - 布局

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.setAccessibilityLabel("Xtrim")
        for view in [shieldView, speedView, dateView, timeView] as [NSView] {
            button.addSubview(view)
        }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 按可见组件重新排宽；只有开关、时制变化时调用，平时刷新不改宽度。
    private func layoutComponents() {
        guard let button = statusItem.button else { return }
        let height = NSStatusBar.system.thickness
        var x: CGFloat = 2
        func place(_ view: NSView, width: CGFloat, visible: Bool) {
            view.isHidden = !visible
            guard visible else { return }
            view.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width
        }
        place(shieldView, width: MenuBarShieldView.width, visible: true)
        place(speedView, width: speedView.fixedWidth, visible: settings.showSpeed)
        place(dateView, width: MenuBarDateBadgeView.width, visible: settings.showDate)
        place(timeView, width: timeView.fixedWidth(use24HourClock: settings.use24HourClock), visible: settings.showTime)
        statusItem.length = x + 2
        button.needsDisplay = true
    }

    // MARK: - 刷新

    private func refreshAll() {
        layoutComponents()
        updateShield()
        refreshSpeed(speed: .zero)
        updateClock(force: true)
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = settings.refreshInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = min(interval * 0.1, 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let speed = networkMonitor.sample()
        if settings.showSpeed { refreshSpeed(speed: speed) }
        updateClock()
    }

    private func updateShield() {
        shieldView.update(symbolName: Self.shieldSymbol(for: client.vpnPresentation.phase))
    }

    // 已连接实心；在家（守护保持断开，属正常）空心；安装失败/离线带提示。
    private static func shieldSymbol(for phase: WgVPNPresentation.Phase) -> String {
        switch phase {
        case .connected: return "lock.shield.fill"
        case .connecting, .disconnecting, .retrying: return "shield.lefthalf.filled"
        case .home: return "shield"
        case .setupFailed: return "exclamationmark.shield"
        case .offline, .idle: return "shield.slash"
        }
    }

    private func refreshSpeed(speed: PhysicalNetworkSpeed) {
        let bits = settings.useBitsPerSecond
        let upload = settings.showUpload
            ? "↑ \(MenuBarSpeedFormatter.speed(speed.uploadBytesPerSecond, useBitsPerSecond: bits))"
            : nil
        let download = settings.showDownload
            ? "↓ \(MenuBarSpeedFormatter.speed(speed.downloadBytesPerSecond, useBitsPerSecond: bits))"
            : nil
        speedView.update(upload: upload ?? (download == nil ? "网速" : nil), download: download)
    }

    private func updateClock(force: Bool = false) {
        let now = Date()
        let minute = Int(now.timeIntervalSince1970 / 60)
        guard force || minute != lastDisplayedMinute else { return }
        lastDisplayedMinute = minute

        let timeZone = settings.selectedTimeZone
        timeView.update(text: timeFormatter.string(
            date: now,
            timeZone: timeZone,
            use24HourClock: settings.use24HourClock
        ))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        dateView.update(
            day: calendar.component(.day, from: now),
            weekday: calendar.component(.weekday, from: now)
        )
        statusItem.button?.toolTip = "Xtrim · 时区：\(displayedTimeZoneName)"
    }

    private func applyDateStyle() {
        dateView.updateStyle(glassEnabled: settings.dateGlassEnabled, tintOpacity: settings.dateTintOpacity)
    }

    private var displayedTimeZoneName: String {
        settings.timeZoneIdentifier == "system"
            ? "跟随系统（\(TimeZone.autoupdatingCurrent.identifier)）"
            : settings.timeZoneIdentifier
    }

    // MARK: - 点击

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            closePanel()
            statusItem.menu = makeComponentMenu()
            sender.performClick(nil)
            statusItem.menu = nil
        } else if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - 左键面板（原 MenuBarExtra 窗口）

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        // 每次新建内容，保证 MenuBarView 的 .task 像 MenuBarExtra 一样在打开时刷新。
        let root = MenuBarView()
            .environmentObject(client)
            .tint(WgInk.control)
        let hosting = NSHostingView(rootView: root)
        let size = hosting.fittingSize
        // 尺寸由这里一次定好，不让托管视图再反向改窗口大小。
        hosting.sizingOptions = []

        let panel = self.panel ?? WgMenuBarPanel()
        panel.delegate = self

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screenFrame = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = NSPoint(x: buttonFrame.minX, y: buttonFrame.minY - size.height - 6)
        origin.x = min(max(origin.x, screenFrame.minX + 6), screenFrame.maxX - size.width - 6)
        // 先定窗口尺寸再挂内容：反过来的话，首次打开时背景视图从 0×0 被拉大，
        // autoresizing 会把这段增量叠加到内容上（内容变成两倍大、只露出左下四分之一）。
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.setContent(hosting)

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func closePanel() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        statusItem.button?.highlight(false)
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.clearContent()
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

    // MARK: - 右键组件菜单（原 NetTimeBar 菜单）

    private func makeComponentMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(header("菜单栏组件"))
        menu.addItem(toggle("实时网速", settings.showSpeed) { $0.showSpeed.toggle() })
        menu.addItem(toggle("日期", settings.showDate) { $0.showDate.toggle() })
        menu.addItem(toggle("时间", settings.showTime) { $0.showTime.toggle() })

        menu.addItem(.separator())
        menu.addItem(header("实时网速 · 统计物理网络接口"))
        menu.addItem(toggle("显示上传速度", settings.showUpload) { $0.showUpload.toggle() })
        menu.addItem(toggle("显示下载速度", settings.showDownload) { $0.showDownload.toggle() })
        menu.addItem(submenu("速率单位", [
            ("字节/秒（m/g）", !settings.useBitsPerSecond, { $0.useBitsPerSecond = false }),
            ("比特/秒（m/g）", settings.useBitsPerSecond, { $0.useBitsPerSecond = true })
        ]))
        menu.addItem(submenu("刷新频率", MenuBarComponentSettings.refreshIntervals.map { interval in
            let title = interval == 1.0 ? "1 秒（默认）" : "\(interval.formatted()) 秒"
            return (title, settings.refreshInterval == interval, { $0.refreshInterval = interval })
        }))

        menu.addItem(.separator())
        menu.addItem(header("日期与时间"))
        menu.addItem(toggle("24 小时制", settings.use24HourClock) { $0.use24HourClock.toggle() })
        menu.addItem(toggle("日期毛玻璃", settings.dateGlassEnabled) { $0.dateGlassEnabled.toggle() })
        menu.addItem(submenu("日期颜色浓度", MenuBarComponentSettings.tintOpacities.map { opacity in
            let title = opacity == 0.4 ? "40%（默认）" : "\(Int(opacity * 100))%"
            return (title, settings.dateTintOpacity == opacity, { $0.dateTintOpacity = opacity })
        }))
        menu.addItem(makeTimeZoneItem())

        return menu
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func toggle(
        _ title: String,
        _ isOn: Bool,
        _ change: @escaping (MenuBarComponentSettings) -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(applySettingChange(_:)), keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        item.representedObject = SettingChange(change)
        return item
    }

    private func submenu(
        _ title: String,
        _ options: [(String, Bool, (MenuBarComponentSettings) -> Void)]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        for (optionTitle, isOn, change) in options {
            sub.addItem(toggle(optionTitle, isOn, change))
        }
        item.submenu = sub
        return item
    }

    private func makeTimeZoneItem() -> NSMenuItem {
        let current = settings.timeZoneIdentifier
        let common: [(String, String)] = [
            ("跟随系统", "system"),
            ("北京 / 上海", "Asia/Shanghai"),
            ("香港", "Asia/Hong_Kong"),
            ("台北", "Asia/Taipei"),
            ("东京", "Asia/Tokyo"),
            ("新加坡", "Asia/Singapore"),
            ("伦敦", "Europe/London"),
            ("巴黎", "Europe/Paris"),
            ("纽约", "America/New_York"),
            ("洛杉矶", "America/Los_Angeles"),
            ("悉尼", "Australia/Sydney"),
            ("UTC", "UTC")
        ]
        let item = submenu("时区：\(displayedTimeZoneName)", common.map { title, identifier in
            (title, current == identifier, { $0.timeZoneIdentifier = identifier })
        })
        item.submenu?.insertItem(.separator(), at: 1)
        item.submenu?.addItem(.separator())

        // 全部时区在展开时才生成，避免每次右键都建几百个菜单项。
        let allItem = NSMenuItem(title: "所有时区", action: nil, keyEquivalent: "")
        let allMenu = NSMenu(title: "所有时区")
        allMenu.delegate = self
        allItem.submenu = allMenu
        allZonesMenu = allMenu
        item.submenu?.addItem(allItem)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === allZonesMenu, menu.items.isEmpty else { return }
        let current = settings.timeZoneIdentifier
        let regionNames = [
            "Africa": "非洲", "America": "美洲", "Antarctica": "南极洲",
            "Arctic": "北极", "Asia": "亚洲", "Atlantic": "大西洋",
            "Australia": "澳大利亚", "Europe": "欧洲", "Indian": "印度洋",
            "Pacific": "太平洋", "Etc": "其他"
        ]
        let grouped = Dictionary(grouping: TimeZone.knownTimeZoneIdentifiers) { identifier in
            identifier.split(separator: "/").first.map(String.init) ?? "其他"
        }
        for region in grouped.keys.sorted() {
            let options = grouped[region, default: []].sorted().map { identifier in
                let parts = identifier.split(separator: "/").dropFirst()
                let title = (parts.isEmpty ? identifier : parts.joined(separator: " / "))
                    .replacingOccurrences(of: "_", with: " ")
                return (title, current == identifier, { (s: MenuBarComponentSettings) in s.timeZoneIdentifier = identifier })
            }
            menu.addItem(submenu(regionNames[region] ?? region, options))
        }
    }

    @objc private func applySettingChange(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? SettingChange else { return }
        let oldInterval = settings.refreshInterval
        change.apply(settings)
        if settings.refreshInterval != oldInterval { startTimer() }
        applyDateStyle()
        refreshAll()
    }
}

private final class SettingChange: NSObject {
    let apply: (MenuBarComponentSettings) -> Void
    init(_ apply: @escaping (MenuBarComponentSettings) -> Void) { self.apply = apply }
}

/// 仿 MenuBarExtra(.window) 的下拉面板：无边框、圆角毛玻璃、失焦即收。
final class WgMenuBarPanel: NSPanel {
    private let background = NSVisualEffectView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        contentView = background
    }

    override var canBecomeKey: Bool { true }

    /// 内容始终铺满背景：用约束而不是 autoresizing，背景从任何尺寸变化都不会把内容撑歪。
    func setContent(_ view: NSView) {
        clearContent()
        view.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            view.topAnchor.constraint(equalTo: background.topAnchor),
            view.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        background.layoutSubtreeIfNeeded()
    }

    func clearContent() {
        background.subviews.forEach { $0.removeFromSuperview() }
    }
}
