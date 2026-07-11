import ApplicationServices
import Cocoa
import os.log

enum NotificationPosition: String, CaseIterable {
    case topLeft, topMiddle, topRight
    case middleLeft, deadCenter, middleRight
    case bottomLeft, bottomMiddle, bottomRight

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topMiddle: return "Top Middle"
        case .topRight: return "Top Right"
        case .middleLeft: return "Middle Left"
        case .deadCenter: return "Middle"
        case .middleRight: return "Middle Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomMiddle: return "Bottom Middle"
        case .bottomRight: return "Bottom Right"
        }
    }
}

class NotificationMover: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let notificationCenterBundleID: String = "com.apple.notificationcenterui"

    /// 四个方向的边距（pt），可在菜单 Edge Margins 分别调整。
    /// 系统 Dock/菜单栏已由 visibleFrame 自动避开；这些值额外留白，主要用于避让第三方 Dock
    /// （第三方 Dock 不向系统登记安全区，visibleFrame 扣不掉，需手动按其所在边加大边距）。
    private func loadMargin(_ key: String, default def: Double) -> CGFloat {
        CGFloat((UserDefaults.standard.object(forKey: key) as? Double) ?? def)
    }
    private lazy var marginLeft: CGFloat = loadMargin("marginLeft", default: 12)
    private lazy var marginRight: CGFloat = loadMargin("marginRight", default: 12)
    private lazy var marginTop: CGFloat = loadMargin("marginTop", default: 12)
    private lazy var marginBottom: CGFloat = loadMargin("marginBottom", default: 12)
    /// 展开态在通知列表上方为「折叠」按钮预留的高度（pt）。
    private lazy var listChromeTop: CGFloat = loadMargin("listChromeTop", default: 40)

    private let marginOptions: [CGFloat] = [0, 8, 12, 20, 32, 48, 64, 80, 100]
    private var axObserver: AXObserver?
    private var statusItem: NSStatusItem?
    private var isMenuBarIconHidden: Bool = UserDefaults.standard.bool(forKey: "isMenuBarIconHidden")
    private let logger: Logger = .init(subsystem: "com.grimridge.PingPlace", category: "NotificationMover")
    private let debugMode: Bool = UserDefaults.standard.bool(forKey: "debugMode")
    private let launchAgentPlistPath: String = NSHomeDirectory() + "/Library/LaunchAgents/com.grimridge.PingPlace.plist"

    private var widgetMonitorTimer: Timer?
    private var lastWidgetWindowCount: Int = 0
    private var pollingEndTime: Date?

    /// 目标显示器的 CGDirectDisplayID。nil = Auto（跟随系统，通知在哪块屏就摆在哪块屏内）。
    /// 用 displayID 而非屏幕数组索引持久化，因为插拔后 NSScreen.screens 顺序会变。
    private var targetDisplayID: CGDirectDisplayID? = {
        let stored = UserDefaults.standard.integer(forKey: "targetDisplayID")
        return stored == 0 ? nil : CGDirectDisplayID(stored)
    }()

    private var currentPosition: NotificationPosition = {
        guard let rawValue: String = UserDefaults.standard.string(forKey: "notificationPosition"),
              let position = NotificationPosition(rawValue: rawValue)
        else {
            return .topMiddle
        }
        return position
    }()

    private func debugLog(_ message: String) {
        guard debugMode else { return }
        logger.info("\(message, privacy: .public)")
    }

    // MARK: - 屏幕解析

    /// 取某块 NSScreen 的 CGDirectDisplayID。
    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    /// 按全局坐标点找出它落在哪块屏（AX 坐标系：原点在主屏左上、y 向下）。
    /// 用每块屏在「AX 坐标系」下的 frame 来判断；找不到则回退主屏。
    private func screenContaining(globalPoint: CGPoint) -> NSScreen? {
        for screen in NSScreen.screens where axFrame(of: screen).contains(globalPoint) {
            return screen
        }
        return NSScreen.main
    }

    /// 解析本次移动应使用的目标屏：
    /// - Auto（targetDisplayID == nil）→ 通知实际所在的屏；
    /// - 指定屏 → 按 displayID 找回；屏被拔掉找不到时回退到通知所在屏。
    private func resolveTargetScreen(notificationScreen: NSScreen?) -> NSScreen? {
        guard let wanted = targetDisplayID else {
            return notificationScreen ?? NSScreen.main
        }
        if let match = NSScreen.screens.first(where: { displayID(of: $0) == wanted }) {
            return match
        }
        debugLog("Target display \(wanted) not found (unplugged?) - falling back to notification screen")
        return notificationScreen ?? NSScreen.main
    }

    /// 把 NSScreen.frame（Cocoa 坐标系：原点左下、y 向上）转换成 AX 坐标系
    /// （原点在主屏左上、y 向下）。AX 读写通知位置用的就是这套坐标。
    private func axFrame(of screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return screen.frame }
        let primaryHeight = primary.frame.height
        let f = screen.frame
        // Cocoa y_bottom -> AX y_top: axY = primaryHeight - (cocoaY + height)
        let axY = primaryHeight - (f.origin.y + f.height)
        return CGRect(x: f.origin.x, y: axY, width: f.width, height: f.height)
    }

    func applicationDidFinishLaunching(_: Notification) {
        checkAccessibilityPermissions()
        setupObserver()
        setupScreenChangeListener()
        if !isMenuBarIconHidden {
            setupStatusItem()
        }
        moveAllNotifications()
    }

    func applicationWillTerminate(_: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        debugLog("Screen change listener removed")
    }

    /// 监听屏幕参数变化（插拔外接显示器、合盖、改分辨率/缩放、Dock 移动都会触发）。
    /// 缓存的坐标数据基于当时的屏幕环境，环境一变就必须失效重算，否则通知会跑偏或不动。
    private func setupScreenChangeListener() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        debugLog("Screen change listener setup complete")
    }

    /// 屏幕变化后的补移时间点（秒）。布局在切换后 0~3s 内可能持续抖动
    /// （分辨率协商、Dock 重排），单次重移可能赶在抖动结束前算错，故多次补移。
    private let rescanDelaysAfterScreenChange: [Double] = [0.5, 1.0, 2.0, 3.0]

    @objc private func screenConfigurationDidChange() {
        debugLog("Screen configuration changed - re-moving notifications")
        // 重建菜单：热插拔屏后 Display 子菜单需重新枚举屏幕（否则插屏后菜单仍是旧的一项）。
        if !isMenuBarIconHidden {
            statusItem?.menu = createMenu()
        }
        // 多次补移：覆盖布局稳定前后的存量通知，降低合盖/插拔瞬间通知跑偏的概率。
        // 坐标每次都从复位 (0,0) 重新计算，无需清缓存。
        for delay in rescanDelaysAfterScreenChange {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                self.moveAllNotifications()
                self.debugLog("Re-move after screen change (delay \(delay)s)")
            }
        }
    }

    func applicationWillBecomeActive(_: Notification) {
        guard isMenuBarIconHidden else { return }
        isMenuBarIconHidden = false
        UserDefaults.standard.set(false, forKey: "isMenuBarIconHidden")
        setupStatusItem()
    }

    private func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "PingPlace needs accessibility permission to detect and move notifications.\n\nPlease grant permission in System Settings and restart the app."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Quit")

            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            NSApplication.shared.terminate(nil)
            return
        }
    }

    func setupStatusItem() {
        guard !isMenuBarIconHidden else {
            statusItem = nil
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button: NSStatusBarButton = statusItem?.button, let menuBarIcon = NSImage(named: "MenuBarIcon") {
            menuBarIcon.isTemplate = true
            button.image = menuBarIcon
        }
        statusItem?.menu = createMenu()
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()

        for position: NotificationPosition in NotificationPosition.allCases {
            let item = NSMenuItem(title: position.displayName, action: #selector(changePosition(_:)), keyEquivalent: "")
            item.representedObject = position
            item.state = position == currentPosition ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Display 子菜单：Auto（跟随系统）+ 每块具体屏（实验性跨屏）。
        let displayMenu = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        displayMenu.submenu = createDisplaySubmenu()
        menu.addItem(displayMenu)

        // Edge Margins 子菜单：四边边距 + 展开态顶部预留，分别可调（避让第三方 Dock）。
        let marginMenu = NSMenuItem(title: "Edge Margins", action: nil, keyEquivalent: "")
        marginMenu.submenu = createEdgeMarginsSubmenu()
        menu.addItem(marginMenu)

        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.state = FileManager.default.fileExists(atPath: launchAgentPlistPath) ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(toggleMenuBarIcon(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let donateMenu = NSMenuItem(title: "Donate", action: nil, keyEquivalent: "")
        let donateSubmenu = NSMenu()
        donateSubmenu.addItem(NSMenuItem(title: "Ko-fi", action: #selector(openKofi), keyEquivalent: ""))
        donateSubmenu.addItem(NSMenuItem(title: "Buy Me a Coffee", action: #selector(openBuyMeACoffee), keyEquivalent: ""))
        donateMenu.submenu = donateSubmenu

        menu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(donateMenu)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    /// 构建 Display 子菜单：第一项 Auto，其后每块当前连接的屏幕一项。
    private func createDisplaySubmenu() -> NSMenu {
        let submenu = NSMenu()

        let autoItem = NSMenuItem(title: "Auto (Follow System)", action: #selector(changeDisplay(_:)), keyEquivalent: "")
        autoItem.representedObject = nil as Any?
        autoItem.state = targetDisplayID == nil ? .on : .off
        submenu.addItem(autoItem)

        submenu.addItem(NSMenuItem.separator())

        for (index, screen) in NSScreen.screens.enumerated() {
            guard let did = displayID(of: screen) else { continue }
            let size = screen.frame.size
            let isMain = screen == NSScreen.main
            let title = "Display \(index + 1)\(isMain ? " (Main)" : "") — \(Int(size.width))×\(Int(size.height))"
            let item = NSMenuItem(title: title, action: #selector(changeDisplay(_:)), keyEquivalent: "")
            item.representedObject = NSNumber(value: did)
            item.state = targetDisplayID == did ? .on : .off
            submenu.addItem(item)
        }

        return submenu
    }

    @objc private func changeDisplay(_ sender: NSMenuItem) {
        let newID: CGDirectDisplayID? = (sender.representedObject as? NSNumber)?.uint32Value
        targetDisplayID = newID
        UserDefaults.standard.set(Int(newID ?? 0), forKey: "targetDisplayID")

        sender.menu?.items.forEach { item in
            let itemID = (item.representedObject as? NSNumber)?.uint32Value
            item.state = itemID == newID ? .on : .off
        }

        debugLog("Target display changed to: \(newID.map(String.init) ?? "Auto")")
        moveAllNotifications()
    }

    /// 每个可调边距项：(显示名, UserDefaults key, 当前值读取)。tag 用于在回调中区分是哪一项。
    private enum MarginKind: Int, CaseIterable {
        case left = 0, right, top, bottom, chromeTop
        var title: String {
            switch self {
            case .left: return "Left"
            case .right: return "Right"
            case .top: return "Top"
            case .bottom: return "Bottom"
            case .chromeTop: return "Expanded Top Reserve"
            }
        }
        var key: String {
            switch self {
            case .left: return "marginLeft"
            case .right: return "marginRight"
            case .top: return "marginTop"
            case .bottom: return "marginBottom"
            case .chromeTop: return "listChromeTop"
            }
        }
    }

    private func marginValue(_ kind: MarginKind) -> CGFloat {
        switch kind {
        case .left: return marginLeft
        case .right: return marginRight
        case .top: return marginTop
        case .bottom: return marginBottom
        case .chromeTop: return listChromeTop
        }
    }

    /// 构建 Edge Margins 子菜单：每个方向一个二级子菜单，列预设档位。
    private func createEdgeMarginsSubmenu() -> NSMenu {
        let submenu = NSMenu()
        for kind in MarginKind.allCases {
            let item = NSMenuItem(title: "\(kind.title)  (\(Int(marginValue(kind)))pt)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for value in marginOptions {
                let opt = NSMenuItem(title: "\(Int(value)) pt", action: #selector(changeMargin(_:)), keyEquivalent: "")
                opt.representedObject = NSNumber(value: Double(value))
                opt.tag = kind.rawValue
                opt.state = value == marginValue(kind) ? .on : .off
                sub.addItem(opt)
            }
            item.submenu = sub
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func changeMargin(_ sender: NSMenuItem) {
        guard let kind = MarginKind(rawValue: sender.tag),
              let value = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        let cg = CGFloat(value)
        switch kind {
        case .left: marginLeft = cg
        case .right: marginRight = cg
        case .top: marginTop = cg
        case .bottom: marginBottom = cg
        case .chromeTop: listChromeTop = cg
        }
        UserDefaults.standard.set(value, forKey: kind.key)

        sender.menu?.items.forEach { item in
            item.state = ((item.representedObject as? NSNumber)?.doubleValue == value) ? .on : .off
        }
        // 更新父项标题里显示的当前值。
        sender.menu?.supermenu?.items.forEach { parent in
            if parent.submenu === sender.menu {
                parent.title = "\(kind.title)  (\(Int(cg))pt)"
            }
        }

        debugLog("Margin \(kind.key) changed to: \(value)pt")
        moveAllNotifications()
    }

    @objc private func openKofi() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/wadegrimridge")!)
    }

    @objc private func openBuyMeACoffee() {
        NSWorkspace.shared.open(URL(string: "https://www.buymeacoffee.com/wadegrimridge")!)
    }

    @objc private func toggleMenuBarIcon(_: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Hide Menu Bar Icon"
        alert.informativeText = "The menu bar icon will be hidden. To show it again, launch PingPlace again."
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isMenuBarIconHidden = true
        UserDefaults.standard.set(true, forKey: "isMenuBarIconHidden")
        statusItem = nil
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let isEnabled = FileManager.default.fileExists(atPath: launchAgentPlistPath)

        if isEnabled {
            do {
                try FileManager.default.removeItem(atPath: launchAgentPlistPath)
                sender.state = .off
            } catch {
                showError("Failed to disable launch at login: \(error.localizedDescription)")
            }
        } else {
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.grimridge.PingPlace</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(Bundle.main.executablePath!)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
            </dict>
            </plist>
            """
            do {
                try plistContent.write(toFile: launchAgentPlistPath, atomically: true, encoding: .utf8)
                sender.state = .on
            } catch {
                showError("Failed to enable launch at login: \(error.localizedDescription)")
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func changePosition(_ sender: NSMenuItem) {
        guard let position: NotificationPosition = sender.representedObject as? NotificationPosition else { return }
        let oldPosition: NotificationPosition = currentPosition
        currentPosition = position
        UserDefaults.standard.set(position.rawValue, forKey: "notificationPosition")

        sender.menu?.items.forEach { item in
            item.state = (item.representedObject as? NotificationPosition) == position ? .on : .off
        }

        debugLog("Position changed: \(oldPosition.displayName) → \(position.displayName)")
        
        moveAllNotifications()
    }

    /// NSScreen.visibleFrame（Cocoa 坐标）转 AX 坐标。visibleFrame 已扣除系统 Dock 与菜单栏。
    private func axVisibleFrame(of screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return screen.visibleFrame }
        let primaryHeight = primary.frame.height
        let vf = screen.visibleFrame
        let axY = primaryHeight - (vf.origin.y + vf.height)
        return CGRect(x: vf.origin.x, y: axY, width: vf.width, height: vf.height)
    }

    func moveNotification(_ window: AXUIElement) {
        // 注：Top Right 不再直接 return。虽然它是系统原生位置，但当通知已被移到别处、
        // 用户再切回 Top Right 时，应主动把它送回右上角锚点（visibleFrame 右上 + marginRight/marginTop），
        // 而非放任停留在原处。calculateNewPosition 的右对齐+顶部分支已正确处理该锚点。
        if hasNotificationCenterUI() {
            debugLog("Skipping move - Notification Center UI detected")
            return
        }

        // 关键修复：每次移动前先把 window 复位到 (0,0)，恢复「window 覆盖整个主屏、
        // 原点在 (0,0)」这个隐藏前提，消除多次移动导致的基准漂移。复位后系统需要
        // 极短时间生效，故延迟重读 banner 再计算。
        setPosition(window, x: 0, y: 0)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.applyMove(to: window)
        }
    }

    /// 在 window 已复位到 (0,0) 的前提下，读取 banner 并计算/应用最终位置。
    private func applyMove(to window: AXUIElement) {
        // 单条通知 banner 的 subrole 是 Banner/Alert；多条堆叠/展开时变成 AlertStack
        // （外层多一个 AXScrollArea > AXNotificationListItems）。三者都要匹配，否则堆叠态找不到 banner。
        let targetSubroles: [String] = ["AXNotificationCenterBanner", "AXNotificationCenterAlert", "AXNotificationCenterAlertStack"]
        // 分步诊断：精确定位哪一步失败（窗口尺寸 / banner 查找 / banner 尺寸 / banner 位置）。
        let windowSizeOpt: CGSize? = getSize(of: window)
        let bannerOpt: AXUIElement? = findElementWithSubrole(root: window, targetSubroles: targetSubroles)
        let notifSizeOpt: CGSize? = bannerOpt.flatMap { getSize(of: $0) }
        let positionOpt: CGPoint? = bannerOpt.flatMap { getPosition(of: $0) }

        guard let windowSize: CGSize = windowSizeOpt,
              bannerOpt != nil,
              let notifSize: CGSize = notifSizeOpt,
              let position: CGPoint = positionOpt
        else {
            debugLog("Failed - windowSize:\(windowSizeOpt != nil) banner:\(bannerOpt != nil) notifSize:\(notifSizeOpt != nil) pos:\(positionOpt != nil) winSize=\(String(describing: windowSizeOpt))")
            _ = bannerContainerLog(window)
            return
        }

        // 复位到 (0,0) 后，banner 落在主屏；据其全局坐标判断所在屏，再解析目标屏。
        let sourceScreen: NSScreen = screenContaining(globalPoint: position) ?? NSScreen.main ?? NSScreen.screens.first!
        let targetScreen: NSScreen = resolveTargetScreen(notificationScreen: sourceScreen) ?? sourceScreen

        // 展开态是多条通知组成的长列表。钳制要以「整个列表的顶/底」为准，而非单条 banner，
        // 否则列表顶部那几条会越过菜单栏被切。这里收集所有通知元素求其包围盒（window 仍在 (0,0)）。
        var allBanners: [AXUIElement] = []
        findAllElementsWithSubrole(root: window, targetSubroles: targetSubroles, into: &allBanners)
        var listTop: CGFloat = position.y
        var listBottom: CGFloat = position.y + notifSize.height
        for b in allBanners {
            if let p = getPosition(of: b), let s = getSize(of: b) {
                listTop = min(listTop, p.y)
                listBottom = max(listBottom, p.y + s.height)
            }
        }

        let newPosition: (x: CGFloat, y: CGFloat) = calculateNewPosition(
            windowSize: windowSize,
            notifSize: notifSize,
            position: position,
            sourceScreen: sourceScreen,
            targetScreen: targetScreen,
            listTopOffset: listTop,
            listBottomOffset: listBottom,
            isExpanded: allBanners.count > 1
        )

        setPosition(window, x: newPosition.x, y: newPosition.y)

        pollingEndTime = Date().addingTimeInterval(6.5)
        debugLog("Moved notification to \(currentPosition.displayName) at (\(newPosition.x), \(newPosition.y)) on screen \(axFrame(of: targetScreen))")
    }

    private func moveAllNotifications() {
        guard let pid: pid_t = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == notificationCenterBundleID
        })?.processIdentifier else {
            debugLog("Cannot find Notification Center process")
            return
        }

        let app: AXUIElement = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows: [AXUIElement] = windowsRef as? [AXUIElement]
        else {
            debugLog("Failed to get notification windows")
            return
        }

        for window in windows {
            moveNotification(window)
        }
    }

    @objc func showAbout() {
        let aboutWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        aboutWindow.center()
        aboutWindow.title = "About PingPlace"
        aboutWindow.delegate = self

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))

        let version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "N/A"
        let copyright: String = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""

        let elements: [(NSView, CGFloat)] = [
            (createIconView(), 165),
            (createLabel("PingPlace", font: .boldSystemFont(ofSize: 16)), 110),
            (createLabel("Version \(version)"), 90),
            (createLabel("Made with <3 by Wade"), 70),
            (createTwitterButton(), 40),
            (createLabel(copyright, color: .secondaryLabelColor, size: 11), 20),
        ]

        for (view, y) in elements {
            view.frame = NSRect(x: 0, y: y, width: 300, height: 20)
            if view is NSImageView {
                view.frame = NSRect(x: 100, y: y, width: 100, height: 100)
            }
            contentView.addSubview(view)
        }

        aboutWindow.contentView = contentView
        aboutWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createIconView() -> NSImageView {
        let iconImageView = NSImageView()
        if let iconImage = NSImage(named: "icon") {
            iconImageView.image = iconImage
            iconImageView.imageScaling = .scaleProportionallyDown
        }
        return iconImageView
    }

    private func createLabel(_ text: String, font: NSFont = .systemFont(ofSize: 12), color: NSColor = .labelColor, size _: CGFloat = 12) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .center
        label.font = font
        label.textColor = color
        return label
    }

    private func createTwitterButton() -> NSButton {
        let button = NSButton()
        button.title = "@WadeGrimridge"
        button.bezelStyle = .inline
        button.isBordered = false
        button.target = self
        button.action = #selector(openTwitter)
        button.attributedTitle = NSAttributedString(string: "@WadeGrimridge", attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        return button
    }

    @objc private func openTwitter() {
        NSWorkspace.shared.open(URL(string: "https://x.com/WadeGrimridge")!)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func setupObserver() {
        guard let pid: pid_t = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == notificationCenterBundleID
        })?.processIdentifier else {
            debugLog("Failed to setup observer - Notification Center not found")
            return
        }

        let app: AXUIElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        AXObserverCreate(pid, observerCallback, &observer)
        axObserver = observer

        let selfPtr: UnsafeMutableRawPointer = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer!, app, kAXWindowCreatedNotification as CFString, selfPtr)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer!), .defaultMode)

        debugLog("Observer setup complete for Notification Center (PID: \(pid))")

        widgetMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            self.checkForWidgetChanges()
        }
    }

    private func getWindowIdentifier(_ element: AXUIElement) -> String? {
        var identifierRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifierRef) == .success else {
            return nil
        }
        return identifierRef as? String
    }

    private func checkForWidgetChanges() {
        guard let pollingEnd: Date = pollingEndTime, Date() < pollingEnd else {
            return
        }

        let hasNCUI: Bool = hasNotificationCenterUI()
        let currentNCState: Int = hasNCUI ? 1 : 0

        if lastWidgetWindowCount != currentNCState {
            debugLog("Notification Center state changed (\(lastWidgetWindowCount) → \(currentNCState)) - triggering move")
            if !hasNCUI {
                moveAllNotifications()
            }
        }

        lastWidgetWindowCount = currentNCState
    }

    private func hasNotificationCenterUI() -> Bool {
        guard let pid: pid_t = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == notificationCenterBundleID
        })?.processIdentifier else { return false }

        let app: AXUIElement = AXUIElementCreateApplication(pid)
        return findElementWithWidgetIdentifier(root: app) != nil
    }

    // Replaces the old findElementWithWidgetIdentifier implementation.
    // Keeps the same public signature but adds a private recursive helper that
    // tracks visited AXUIElement pointers to avoid infinite recursion/cycles.

    private func findElementWithWidgetIdentifier(root: AXUIElement) -> AXUIElement? {
        var visited = Set<UnsafeRawPointer>()
        return findElementWithWidgetIdentifier(root: root, visited: &visited, depth: 0)
    }

    private func findElementWithWidgetIdentifier(
        root: AXUIElement,
        visited: inout Set<UnsafeRawPointer>,
        depth: Int,
        maxDepth: Int = 1000
    ) -> AXUIElement? {
        // Depth guard to prevent runaway recursion in pathological cases
        if depth > maxDepth {
            debugLog("findElementWithWidgetIdentifier: reached maxDepth (\(maxDepth)) - aborting branch")
            return nil
        }

        // Use the AXUIElement pointer identity as a unique key to detect cycles
        let rootPtr = UnsafeRawPointer(Unmanaged.passUnretained(root).toOpaque())
        if visited.contains(rootPtr) {
            // already visited this element -> skip to avoid cycles
            debugLog("findElementWithWidgetIdentifier: detected cycle or repeated element - skipping")
            return nil
        }
        visited.insert(rootPtr)

        // Check identifier
        if let identifier: String = getWindowIdentifier(root),
           identifier.hasPrefix("widget-local") {
            return root
        }

        // Get children
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        // Recurse into children
        for child in children {
            if let found = findElementWithWidgetIdentifier(root: child, visited: &visited, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }

        return nil
    }

    private func getPosition(of element: AXUIElement) -> CGPoint? {
        var positionValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        guard let posVal: AnyObject = positionValue, AXValueGetType(posVal as! AXValue) == .cgPoint else {
            return nil
        }
        var position = CGPoint.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
        return position
    }

    /// 计算通知 window 的目标 AX 位置。
    ///
    /// 前提：调用前 window 已被复位到 (0,0)，覆盖源屏。因此 banner 在 window 内的局部
    /// 偏移 == 其当前全局坐标 `position`，把 window 设到 newX/newY 后，banner 的新全局
    /// 坐标 = newX + position.x（Y 同理）。要让 banner 落到锚点 anchor，则 newX = anchor - position.x。
    ///
    /// 锚点直接基于**目标屏**的 AX 可视区（visibleFrame，已是全局坐标，含该屏 origin，
    /// 已扣除系统 Dock/菜单栏）+ 对应方向 margin。这样无论目标屏在哪、分辨率多大，居中/对齐
    /// 都按目标屏自身尺寸算，跨屏不再错位（不需要单独再加两屏原点差——origin 已编码在 frame 里）。
    /// - sourceScreen：复位后 banner 实际所在屏（仅用于日志对比）。
    /// - targetScreen：希望最终落在的屏（Auto 时 == sourceScreen）。
    private func calculateNewPosition(
        windowSize: CGSize,
        notifSize: CGSize,
        position: CGPoint,
        sourceScreen: NSScreen,
        targetScreen: NSScreen,
        listTopOffset: CGFloat,
        listBottomOffset: CGFloat,
        isExpanded: Bool
    ) -> (x: CGFloat, y: CGFloat) {
        debugLog("Calculating new position with windowSize: \(windowSize), notifSize: \(notifSize), position: \(position)")

        // 目标屏的 AX 可视区（全局坐标）：所有锚点都相对它算。
        let vf: CGRect = axVisibleFrame(of: targetScreen)
        let visLeft: CGFloat = vf.origin.x
        let visRight: CGFloat = vf.origin.x + vf.width
        let visTop: CGFloat = vf.origin.y
        let visBottom: CGFloat = vf.origin.y + vf.height

        if sourceScreen != targetScreen {
            debugLog("Cross-screen move (experimental): source \(axFrame(of: sourceScreen)) -> target \(vf)")
        }

        // 水平锚点（banner 目标全局左边缘）：左对齐用 marginLeft，右对齐用 marginRight。
        let anchorX: CGFloat
        switch currentPosition {
        case .topLeft, .middleLeft, .bottomLeft:
            anchorX = visLeft + marginLeft
        case .topMiddle, .bottomMiddle, .deadCenter:
            anchorX = visLeft + (vf.width - notifSize.width) / 2
        case .topRight, .middleRight, .bottomRight:
            anchorX = visRight - notifSize.width - marginRight
        }
        let newX: CGFloat = anchorX - position.x

        // 垂直锚点（banner 目标全局上边缘）：顶部用 marginTop，底部用 marginBottom。
        let anchorY: CGFloat
        switch currentPosition {
        case .topLeft, .topMiddle, .topRight:
            anchorY = visTop + marginTop
        case .middleLeft, .middleRight, .deadCenter:
            anchorY = visTop + (vf.height - notifSize.height) / 2
        case .bottomLeft, .bottomMiddle, .bottomRight:
            anchorY = visBottom - notifSize.height - marginBottom
        }
        let newY: CGFloat = anchorY - position.y

        var resultX: CGFloat = newX
        var resultY: CGFloat = newY

        // 边界钳制：保证整个通知列表落在目标屏可视区内，绝不被菜单栏/屏幕边缘切掉。
        // 水平按单条 banner 钳制；垂直按「整个列表的顶/底」钳制（listTopOffset/listBottomOffset
        // 是列表最顶/最底在 window 内的 y 偏移）——展开态多条时，避免顶部那几条越过菜单栏。
        let targetVisible: CGRect = axVisibleFrame(of: targetScreen)
        let bannerGlobalX: CGFloat = resultX + position.x
        let minX: CGFloat = targetVisible.origin.x + marginLeft
        let maxX: CGFloat = targetVisible.origin.x + targetVisible.width - notifSize.width - marginRight
        if bannerGlobalX < minX { resultX += minX - bannerGlobalX }
        else if maxX >= minX, bannerGlobalX > maxX { resultX -= bannerGlobalX - maxX }

        let listGlobalTop: CGFloat = resultY + listTopOffset
        let listGlobalBottom: CGFloat = resultY + listBottomOffset
        // 展开态在通知列表上方还有一个「折叠」按钮（不是 banner subrole，未计入 listTopOffset）。
        // 仅展开态用可配置的 listChromeTop 预留其高度，确保不被菜单栏切；单条/堆叠态不预留。
        let chromeReserve: CGFloat = isExpanded ? listChromeTop : 0
        let minTop: CGFloat = targetVisible.origin.y + marginTop + chromeReserve
        let maxBottom: CGFloat = targetVisible.origin.y + targetVisible.height - marginBottom
        // 优先保证顶部（含折叠按钮）不被菜单栏切；若列表比可视区还高，顶部对齐（底部允许超屏，可滚动）。
        if listGlobalTop < minTop {
            resultY += minTop - listGlobalTop
        } else if listGlobalBottom > maxBottom {
            let listHeight = listBottomOffset - listTopOffset
            if listHeight <= (maxBottom - minTop) {
                resultY -= listGlobalBottom - maxBottom   // 整体上移让底部进界
            } else {
                resultY = minTop - listTopOffset          // 太高则顶部对齐
            }
        }

        debugLog("Calculated new position - x: \(resultX), y: \(resultY) [listTop=\(listTopOffset) listBottom=\(listBottomOffset)]")
        return (resultX, resultY)
    }

    private func getWindowTitle(_ element: AXUIElement) -> String? {
        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success else {
            return nil
        }
        return titleRef as? String
    }

    private func getSize(of element: AXUIElement) -> CGSize? {
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard let sizeVal: AnyObject = sizeValue, AXValueGetType(sizeVal as! AXValue) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return size
    }

    private func setPosition(_ element: AXUIElement, x: CGFloat, y: CGFloat) {
        var point = CGPoint(x: x, y: y)
        let value: AXValue = AXValueCreate(.cgPoint, &point)!
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    /// 诊断：递归打印 window 子树的 role/subrole/identifier/size，定位堆叠态下 banner 的真实结构。
    private func bannerContainerLog(_ window: AXUIElement) -> Bool {
        guard debugMode else { return false }
        dumpAXTree(window, depth: 0, maxDepth: 5)
        return true
    }

    private func dumpAXTree(_ element: AXUIElement, depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else { return }
        var roleRef: AnyObject?; var subRef: AnyObject?; var idRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subRef)
        AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &idRef)
        let size = getSize(of: element)
        let indent = String(repeating: "  ", count: depth)
        debugLog("  [tree]\(indent)role=\(roleRef as? String ?? "?") subrole=\(subRef as? String ?? "-") id=\(idRef as? String ?? "-") size=\(size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-")")

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children.prefix(10) {
            dumpAXTree(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    private func findElementWithSubrole(root: AXUIElement, targetSubroles: [String]) -> AXUIElement? {
        var subroleRef: AnyObject?
        if AXUIElementCopyAttributeValue(root, kAXSubroleAttribute as CFString, &subroleRef) == .success {
            if let subrole: String = subroleRef as? String, targetSubroles.contains(subrole) {
                return root
            }
        }

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children: [AXUIElement] = childrenRef as? [AXUIElement]
        else {
            return nil
        }

        for child: AXUIElement in children {
            if let found: AXUIElement = findElementWithSubrole(root: child, targetSubroles: targetSubroles) {
                return found
            }
        }
        return nil
    }

    /// 收集 window 内所有匹配 subrole 的通知元素（展开态会有多条）。用于钳制时确定列表的真实顶/底边界。
    private func findAllElementsWithSubrole(root: AXUIElement, targetSubroles: [String], into result: inout [AXUIElement]) {
        var subroleRef: AnyObject?
        if AXUIElementCopyAttributeValue(root, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole: String = subroleRef as? String, targetSubroles.contains(subrole) {
            result.append(root)
        }
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children: [AXUIElement] = childrenRef as? [AXUIElement] else { return }
        for child in children {
            findAllElementsWithSubrole(root: child, targetSubroles: targetSubroles, into: &result)
        }
    }
}

private func observerCallback(observer _: AXObserver, element: AXUIElement, notification: CFString, context: UnsafeMutableRawPointer?) {
    let mover: NotificationMover = Unmanaged<NotificationMover>.fromOpaque(context!).takeUnretainedValue()

    let notificationString: String = notification as String
    if notificationString == kAXWindowCreatedNotification as String {
        mover.moveNotification(element)
    }
}

let app: NSApplication = .shared
let delegate: NotificationMover = .init()
app.delegate = delegate
app.run()
