import AppKit
import ClipboardCore
import Combine
import SwiftUI

@MainActor
final class PanelViewModel: ObservableObject {
    @Published var activeTab: ClipboardTab = .history
    @Published var searchQuery: String = ""
    @Published var selectedItemID: UUID?
    @Published var renamingItem: ClipboardItem?
    @Published var renameDraft: String = ""
    @Published var focusSearchTrigger: Int = 0
    @Published var feedbackMessage: String?
    @Published var isPinned: Bool = false

    let store: ClipboardStore
    private var feedbackWorkItem: DispatchWorkItem?

    init(store: ClipboardStore) {
        self.store = store
    }

    func togglePinned() {
        isPinned.toggle()
        showFeedback(isPinned ? "已钉住窗口，复制后不自动关闭" : "已取消钉住")
    }

    var filteredItems: [ClipboardItem] {
        store.items(for: activeTab, matching: searchQuery)
    }

    var selectedItem: ClipboardItem? {
        let items = filteredItems
        if let id = selectedItemID, let match = items.first(where: { $0.id == id }) {
            return match
        }
        return items.first
    }

    func resetForShow(tab: ClipboardTab) {
        activeTab = tab
        searchQuery = ""
        renamingItem = nil
        renameDraft = ""
        feedbackMessage = nil
        syncSelection()
        focusSearchTrigger &+= 1
    }

    func switchTab(_ tab: ClipboardTab) {
        guard activeTab != tab else { return }
        activeTab = tab
        renamingItem = nil
        syncSelection()
    }

    func syncSelection() {
        let items = filteredItems
        if let current = selectedItemID, items.contains(where: { $0.id == current }) {
            return
        }
        selectedItemID = items.first?.id
    }

    func moveSelection(delta: Int) {
        let items = filteredItems
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }
        guard let currentID = selectedItemID,
              let index = items.firstIndex(where: { $0.id == currentID }) else {
            selectedItemID = delta >= 0 ? items.first?.id : items.last?.id
            return
        }
        let nextIndex = min(max(index + delta, 0), items.count - 1)
        selectedItemID = items[nextIndex].id
    }

    func beginRename(_ item: ClipboardItem) {
        guard activeTab == .favorites else { return }
        renamingItem = item
        renameDraft = item.title ?? ""
    }

    func commitRename() {
        guard let item = renamingItem else { return }
        store.renameFavorite(id: item.id, title: renameDraft)
        renamingItem = nil
        renameDraft = ""
        focusSearchTrigger &+= 1
    }

    func cancelRename() {
        renamingItem = nil
        renameDraft = ""
        focusSearchTrigger &+= 1
    }

    func toggleFavoriteForSelected() {
        guard let item = selectedItem else { return }
        toggleFavorite(item)
    }

    func toggleFavorite(_ item: ClipboardItem) {
        if activeTab == .favorites {
            store.removeFavorite(id: item.id)
            showFeedback("已取消收藏")
        } else {
            let added = store.toggleFavorite(for: item)
            showFeedback(added ? "已加入收藏" : "已取消收藏")
        }
        syncSelection()
    }

    func deleteSelected() {
        guard let item = selectedItem else { return }
        delete(item)
    }

    func delete(_ item: ClipboardItem) {
        if activeTab == .history {
            store.deleteHistoryItem(id: item.id)
        } else {
            store.removeFavorite(id: item.id)
        }
        syncSelection()
    }

    func showFeedback(_ message: String) {
        feedbackWorkItem?.cancel()
        feedbackMessage = message
        let workItem = DispatchWorkItem { [weak self] in
            self?.feedbackMessage = nil
        }
        feedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: workItem)
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class ClipboardPanelController {
    private let store: ClipboardStore
    private let viewModel: PanelViewModel
    private let onOpenSettings: () -> Void
    private let onConfirmClearHistory: () -> Void

    private var panel: KeyablePanel?
    private var keyMonitor: Any?
    private var lastShownAt: Date?
    private var hasPositionedOnce = false
    private var pinCancellable: AnyCancellable?

    private static let frameAutosaveName = NSWindow.FrameAutosaveName("ClipboardHistoryPanelFrame")

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    var isPinned: Bool {
        viewModel.isPinned
    }

    var shownDuration: TimeInterval {
        guard let lastShownAt else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(lastShownAt)
    }

    init(
        store: ClipboardStore,
        onOpenSettings: @escaping () -> Void,
        onConfirmClearHistory: @escaping () -> Void
    ) {
        self.store = store
        self.viewModel = PanelViewModel(store: store)
        self.onOpenSettings = onOpenSettings
        self.onConfirmClearHistory = onConfirmClearHistory
        self.pinCancellable = viewModel.$isPinned
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pinned in
                self?.applySpaceBehavior(pinned: pinned)
            }
    }

    private func applySpaceBehavior(pinned: Bool) {
        // .canJoinAllSpaces 与 .moveToActiveSpace 互斥：
        // 钉住时加入所有桌面空间（可随切换桌面常驻），未钉住时呼出移动到当前活跃空间。
        panel?.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    func show(tab: ClipboardTab) {
        let panel = ensurePanel()
        viewModel.resetForShow(tab: tab)
        if !hasPositionedOnce {
            positionPanelIfNeeded(panel)
            hasPositionedOnce = true
        } else {
            ensureFrameVisibleOnAnyScreen(panel)
        }
        lastShownAt = Date()

        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installKeyMonitor()
    }

    func hide(deactivateApp: Bool) {
        removeKeyMonitor()
        viewModel.cancelRename()
        panel?.orderOut(nil)
        if deactivateApp {
            NSApp.hide(nil)
        }
    }

    func copyAndClose(_ item: ClipboardItem) {
        if store.copyToPasteboard(item) {
            if viewModel.isPinned {
                viewModel.showFeedback("已复制到剪贴板")
            } else {
                hide(deactivateApp: true)
            }
        } else {
            viewModel.showFeedback("复制失败")
        }
    }

    private func ensurePanel() -> KeyablePanel {
        if let existing = panel {
            return existing
        }

        let size = NSSize(width: 640, height: 488)
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.canHide = true
        panel.level = .floating
        panel.minSize = NSSize(width: 480, height: 340)
        panel.maxSize = NSSize(width: 1100, height: 900)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = viewModel.isPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.setFrameAutosaveName(Self.frameAutosaveName)

        let rootView = ClipboardPanelView(
            store: store,
            viewModel: viewModel,
            onCopyItem: { [weak self] item in self?.copyAndClose(item) },
            onClose: { [weak self] in self?.hide(deactivateApp: true) },
            onOpenSettings: onOpenSettings,
            onConfirmClearHistory: onConfirmClearHistory
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        self.panel = panel
        return panel
    }

    private func positionPanelIfNeeded(_ panel: NSPanel) {
        if panel.setFrameUsingName(Self.frameAutosaveName) {
            ensureFrameVisibleOnAnyScreen(panel)
            return
        }
        positionPanelCentered(panel)
    }

    private func positionPanelCentered(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        let x = round(visibleFrame.midX - size.width / 2)
        let y = round(visibleFrame.minY + (visibleFrame.height - size.height) * 0.62)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func ensureFrameVisibleOnAnyScreen(_ panel: NSPanel) {
        let frame = panel.frame
        let isVisible = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        if !isVisible {
            positionPanelCentered(panel)
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handleKeyDown(event)
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // 中文/日文输入法正在组合候选项时，将回车、方向键与 Esc 完整交回输入法处理。
        if let inputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
           inputClient.hasMarkedText() {
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // 重命名输入中，只拦截 Esc 取消；其他编辑快捷键（⌘A/⌘C/⌘V/⌘X/⌘Z/回车等）交给输入框处理。
        if viewModel.renamingItem != nil {
            if event.keyCode == 53 { // Esc
                viewModel.cancelRename()
                return nil
            }
            return event
        }

        // Cmd 快捷键（不拦截标准文本编辑快捷键 ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z）
        if flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "1":
                viewModel.switchTab(.history)
                return nil
            case "2":
                viewModel.switchTab(.favorites)
                return nil
            case "d":
                viewModel.toggleFavoriteForSelected()
                return nil
            case "p":
                viewModel.togglePinned()
                return nil
            case ",":
                onOpenSettings()
                return nil
            default:
                break
            }
            // 搜索框有文字时，⌘⌫ 保留给输入框清空当前行；搜索框为空时用于删除选中条目。
            if event.keyCode == 51, viewModel.searchQuery.isEmpty { // Cmd + Delete
                viewModel.deleteSelected()
                return nil
            }
        }

        // 无修饰键导航（macOS 方向键会同时携带 .numericPad 与 .function 标志位）
        let navigationModifiers = flags.subtracting([.numericPad, .function])
        if navigationModifiers.isEmpty {
            switch event.keyCode {
            case 125: // Down Arrow
                viewModel.moveSelection(delta: 1)
                return nil
            case 126: // Up Arrow
                viewModel.moveSelection(delta: -1)
                return nil
            case 36, 76: // Return / Keypad Enter
                if let item = viewModel.selectedItem {
                    copyAndClose(item)
                    return nil
                }
            case 53: // Esc
                hide(deactivateApp: true)
                return nil
            default:
                break
            }
        }

        return event
    }
}
