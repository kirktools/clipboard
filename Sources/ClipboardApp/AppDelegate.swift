import AppKit
import ClipboardCore
import ClipboardDiagnostics
import Combine
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let isDevelopmentBuild = ClipboardChannel.current() == .dev
    let store = ClipboardStore()
    private lazy var monitor = PasteboardMonitor(pasteboard: .general, store: store)
    private lazy var panelController = ClipboardPanelController(
        store: store,
        onOpenSettings: { [weak self] in self?.openSettings() },
        onConfirmClearHistory: { [weak self] in self?.confirmClearHistory() }
    )
    private lazy var settingsController = SettingsWindowController(
        store: store,
        onConfirmClearHistory: { [weak self] in self?.confirmClearHistory() },
        onCheckForUpdates: { [weak self] in self?.openUpdateWindow() }
    )
    private lazy var updateController = AppUpdateWindowController(lastOutcome: lastUpdateOutcome)
    private var lastUpdateOutcome: UpdateOutcome?

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var suppressNextActivatePanel = false
    private var isClearingAlertOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        lastUpdateOutcome = UpdateOutcome.takeLatest()
        setupMainMenu()
        setupStatusItem()
        observeStoreChanges()
        monitor.start()

        let args = Set(CommandLine.arguments)
        if args.contains("--settings") {
            openSettings()
            return
        }
        if args.contains("--favorites") {
            showPanel(tab: .favorites)
            return
        }
        if shouldLaunchSilently(arguments: args) {
            ClipboardLog.app.info("launched_silently")
            ClipboardDiagnostics.shared.record(.info, module: "app", event: "launched_silently")
            return
        }

        // 显式启动（如从访达打开或由 Hotkey 在未运行时拉起）直接展示历史面板。
        showPanel(tab: .history)
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panelController.isVisible {
            // 同一次 openApplication 激活可能先触发 didBecomeActive 再触发 reopen；
            // 仅在面板已显示一段时间后再次收到 reopen 时才执行收起切换。
            if panelController.shownDuration > 0.35 {
                panelController.hide(deactivateApp: true)
            }
        } else {
            showPanel(tab: .history)
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if suppressNextActivatePanel {
            suppressNextActivatePanel = false
            return
        }
        if isClearingAlertOpen || settingsController.isVisible || updateController.isVisible {
            return
        }
        if !panelController.isVisible {
            showPanel(tab: .history)
        }
    }

    func applicationWillHide(_ notification: Notification) {
        panelController.hide(deactivateApp: false)
    }

    func applicationDidResignActive(_ notification: Notification) {
        if !isClearingAlertOpen && !panelController.isPinned {
            panelController.hide(deactivateApp: false)
        }
    }

    // MARK: - Launch Mode Detection

    private func shouldLaunchSilently(arguments: Set<String>) -> Bool {
        if arguments.contains("--background") || arguments.contains("--silent") {
            return true
        }
        // 通过系统登录项自启时保持静默常驻菜单栏，不无故弹窗。
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           let prop = event.paramDescriptor(forKeyword: keyAEPropData),
           prop.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return false
    }

    // MARK: - Panel & Settings Navigation

    func showPanel(tab: ClipboardTab) {
        store.refreshAccessState()
        panelController.show(tab: tab)
    }

    func openSettings() {
        suppressNextActivatePanel = true
        panelController.hide(deactivateApp: false)
        settingsController.show()
    }

    func openUpdateWindow() {
        suppressNextActivatePanel = true
        panelController.hide(deactivateApp: false)
        updateController.showAndCheck()
    }

    func confirmClearHistory() {
        guard !store.history.isEmpty else { return }
        isClearingAlertOpen = true
        suppressNextActivatePanel = true
        panelController.hide(deactivateApp: false)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "清空最近历史？"
        alert.informativeText = "将删除全部 \(store.history.count) 条最近记录。长期收藏的条目与图片会完整保留。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空最近")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        isClearingAlertOpen = false
        if response == .alertFirstButtonReturn {
            store.clearHistory()
        }
    }

    // MARK: - Main Menu (Standard Edit Shortcuts)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Clipboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        syncStatusItemVisibility()
    }

    private func syncStatusItemVisibility() {
        if store.isMenuBarIconHidden {
            if let existing = statusItem {
                NSStatusBar.system.removeStatusItem(existing)
                statusItem = nil
            }
            return
        }

        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        updateStatusBarAppearance()
    }

    private func observeStoreChanges() {
        store.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncStatusItemVisibility()
            }
            .store(in: &cancellables)
    }

    private func updateStatusBarAppearance() {
        guard let button = statusItem?.button else { return }
        let symbolName = store.isRecordingPaused ? "clipboard" : "doc.on.clipboard"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: isDevelopmentBuild ? "Clipboard Dev" : "Clipboard")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = isDevelopmentBuild ? .imageLeading : .imageOnly
        button.title = isDevelopmentBuild ? " DEV" : ""
        button.alphaValue = store.isRecordingPaused ? 0.55 : 1.0
        let appName = isDevelopmentBuild ? "Clipboard Dev" : "Clipboard"
        button.toolTip = store.isRecordingPaused ? "\(appName)（已暂停记录）" : appName
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        store.refreshAccessState()

        let openHistory = NSMenuItem(
            title: "打开最近历史（\(store.history.count)）",
            action: #selector(menuOpenHistory),
            keyEquivalent: ""
        )
        openHistory.target = self
        menu.addItem(openHistory)

        let openFavorites = NSMenuItem(
            title: "打开收藏（\(store.favorites.count)）",
            action: #selector(menuOpenFavorites),
            keyEquivalent: ""
        )
        openFavorites.target = self
        menu.addItem(openFavorites)

        menu.addItem(.separator())

        let pauseTitle = store.isRecordingPaused ? "恢复记录" : "暂停记录"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(menuTogglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let privacyItem = NSMenuItem(title: "隐私模式（遮罩预览）", action: #selector(menuTogglePrivacyMode), keyEquivalent: "")
        privacyItem.target = self
        privacyItem.state = store.isPrivacyModeEnabled ? .on : .off
        menu.addItem(privacyItem)

        if store.accessState == .alwaysDeny {
            let permissionItem = NSMenuItem(
                title: "剪贴板读取已被拒绝（前往系统设置…）",
                action: #selector(menuOpenPrivacySettings),
                keyEquivalent: ""
            )
            permissionItem.target = self
            menu.addItem(permissionItem)
        }

        let clearItem = NSMenuItem(title: "清空最近历史…", action: #selector(menuClearHistory), keyEquivalent: "")
        clearItem.target = self
        clearItem.isEnabled = !store.history.isEmpty
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(menuCheckForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let quitItem = NSMenuItem(title: "退出 Clipboard", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func menuOpenHistory() {
        // 等待状态栏菜单完全收起后再激活并聚焦面板，避免与菜单关闭抢夺焦点。
        DispatchQueue.main.async { [weak self] in
            self?.showPanel(tab: .history)
        }
    }

    @objc private func menuOpenFavorites() {
        DispatchQueue.main.async { [weak self] in
            self?.showPanel(tab: .favorites)
        }
    }

    @objc private func menuTogglePause() {
        store.toggleRecordingPaused()
    }

    @objc private func menuTogglePrivacyMode() {
        store.togglePrivacyMode()
    }

    @objc private func menuClearHistory() {
        confirmClearHistory()
    }

    @objc private func menuOpenSettings() {
        DispatchQueue.main.async { [weak self] in
            self?.openSettings()
        }
    }

    @objc private func menuCheckForUpdates() {
        DispatchQueue.main.async { [weak self] in
            self?.openUpdateWindow()
        }
    }

    @objc private func menuOpenPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}
