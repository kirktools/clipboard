import AppKit
import ClipboardCore
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var viewModel: PanelViewModel

    let onCopyItem: (ClipboardItem) -> Void
    let onClose: () -> Void
    let onOpenSettings: () -> Void
    let onConfirmClearHistory: () -> Void

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isRenameFocused: Bool
    @State private var hoveredItemID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            windowTitleBar
            Divider()
            headerBar
            Divider()
            statusBanner
            renameBar
            itemList
            Divider()
            footerBar
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 340, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onChange(of: viewModel.focusSearchTrigger) { _, _ in
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: viewModel.searchQuery) { _, _ in
            viewModel.syncSelection()
        }
        .onChange(of: store.history) { _, _ in
            viewModel.syncSelection()
        }
        .onChange(of: store.favorites) { _, _ in
            viewModel.syncSelection()
        }
        .onChange(of: viewModel.renamingItem) { _, newValue in
            if newValue != nil {
                DispatchQueue.main.async {
                    isRenameFocused = true
                }
            }
        }
    }

    // MARK: - Window Drag & Pin Bar

    private var windowTitleBar: some View {
        ZStack {
            WindowDragArea()

            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "Clipboard Dev" : "Clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if viewModel.isPinned {
                    Text("已钉住")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.16))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                if store.isPrivacyModeEnabled {
                    Text("隐私模式")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                Spacer()

                Button {
                    store.togglePrivacyMode()
                    viewModel.revealedItemID = nil
                } label: {
                    Image(systemName: store.isPrivacyModeEnabled ? "eye.slash.fill" : "eye")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(store.isPrivacyModeEnabled ? Color.orange : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(store.isPrivacyModeEnabled ? Color.orange.opacity(0.16) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(store.isPrivacyModeEnabled ? "关闭隐私模式 (⌘⇧P)" : "开启隐私模式，遮罩全部预览 (⌘⇧P)")

                Button {
                    viewModel.togglePinned()
                } label: {
                    Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(viewModel.isPinned ? Color.accentColor : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(viewModel.isPinned ? Color.accentColor.opacity(0.14) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(viewModel.isPinned ? "取消钉住窗口 (⌘P)" : "钉住窗口，方便连续复制 (⌘P)")

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("关闭窗口 (Esc)")
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 30)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14, weight: .medium))

                TextField(
                    viewModel.activeTab == .history ? "搜索最近剪贴板文本、链接…" : "搜索收藏名称、文本、链接…",
                    text: $viewModel.searchQuery
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isSearchFocused)

                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            tabSwitcher
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 4) {
            tabButton(tab: .history, count: store.history.count)
            tabButton(tab: .favorites, count: store.favorites.count)
        }
        .padding(3)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tabButton(tab: ClipboardTab, count: Int) -> some View {
        let isSelected = viewModel.activeTab == tab
        return Button {
            viewModel.switchTab(tab)
        } label: {
            HStack(spacing: 4) {
                Text(tab.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: isSelected ? Color.black.opacity(0.08) : .clear, radius: 1, y: 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Banners

    @ViewBuilder
    private var statusBanner: some View {
        if store.accessState == .alwaysDeny {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("系统已拒绝剪贴板读取，请在系统设置中允许 Clipboard 访问剪贴板。")
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
                Button("前往设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.12))
            Divider()
        } else if store.isRecordingPaused {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                Text("已暂停记录剪贴板，新复制的内容不会被保存。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复记录") {
                    store.setRecordingPaused(false)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.04))
            Divider()
        } else if store.isPrivacyModeEnabled {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash.fill")
                    .foregroundStyle(.orange)
                Text("隐私模式已开启：列表预览与图片缩略图已遮罩，按 ⌘E 可临时查看当前项。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("关闭") {
                    store.setPrivacyModeEnabled(false)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.08))
            Divider()
        }
    }

    @ViewBuilder
    private var renameBar: some View {
        if viewModel.renamingItem != nil {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                TextField("输入收藏名称（留空恢复默认）", text: $viewModel.renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused($isRenameFocused)
                    .onSubmit {
                        viewModel.commitRename()
                    }
                Button("保存") {
                    viewModel.commitRename()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("取消") {
                    viewModel.cancelRename()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))
            Divider()
        }
    }

    // MARK: - List

    private var itemList: some View {
        let items = viewModel.filteredItems
        return Group {
            if items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(items) { item in
                                ClipboardItemRow(
                                    item: item,
                                    tab: viewModel.activeTab,
                                    isSelected: viewModel.selectedItem?.id == item.id,
                                    isHovered: hoveredItemID == item.id,
                                    isFavorited: viewModel.activeTab == .favorites || store.isFavorited(item),
                                    privacyMode: store.isPrivacyModeEnabled,
                                    isRevealed: viewModel.isRevealed(item),
                                    thumbnail: store.image(for: item),
                                    onSelect: {
                                        viewModel.selectedItemID = item.id
                                    },
                                    onCopy: {
                                        onCopyItem(item)
                                    },
                                    onToggleReveal: {
                                        viewModel.toggleReveal(item)
                                    },
                                    onToggleFavorite: {
                                        viewModel.toggleFavorite(item)
                                    },
                                    onRename: {
                                        viewModel.beginRename(item)
                                    },
                                    onDelete: {
                                        viewModel.delete(item)
                                    }
                                )
                                .id(item.id)
                                .onHover { hovering in
                                    if hovering {
                                        hoveredItemID = item.id
                                    } else if hoveredItemID == item.id {
                                        hoveredItemID = nil
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: viewModel.selectedItemID) { _, newID in
                        if viewModel.revealedItemID != newID {
                            viewModel.revealedItemID = nil
                        }
                        if let newID {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(newID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: emptyIconName)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text(emptySubtitle)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyIconName: String {
        if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "magnifyingglass"
        }
        return viewModel.activeTab == .history ? "doc.on.clipboard" : "star"
    }

    private var emptyTitle: String {
        if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "没有匹配的条目"
        }
        return viewModel.activeTab == .history ? "暂无最近剪贴板记录" : "暂无收藏"
    }

    private var emptySubtitle: String {
        if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "试试更换关键词，或切换「最近」与「收藏」。"
        }
        return viewModel.activeTab == .history
            ? "复制文本、链接或图片后会自动出现在这里。"
            : "在「最近」列表中点击星标或按 ⌘D 即可收藏常用内容。"
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            if let message = viewModel.feedbackMessage {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("↑↓ 选择 · ↩ 复制 · ⌘D 收藏 · ⌘P 钉住 · Esc 关闭")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                store.toggleRecordingPaused()
            } label: {
                Label(
                    store.isRecordingPaused ? "恢复记录" : "暂停记录",
                    systemImage: store.isRecordingPaused ? "play.circle" : "pause.circle"
                )
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if viewModel.activeTab == .history && !store.history.isEmpty {
                Button {
                    onConfirmClearHistory()
                } label: {
                    Label("清空最近", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("设置 (⌘,)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct ClipboardItemRow: View {
    let item: ClipboardItem
    let tab: ClipboardTab
    let isSelected: Bool
    let isHovered: Bool
    let isFavorited: Bool
    let privacyMode: Bool
    let isRevealed: Bool
    let thumbnail: NSImage?

    let onSelect: () -> Void
    let onCopy: () -> Void
    let onToggleReveal: () -> Void
    let onToggleFavorite: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var lastTapTime: Date?

    private var isSensitive: Bool {
        SensitivePreview.looksSensitive(item)
    }

    private var isMasked: Bool {
        !isRevealed && (privacyMode || isSensitive)
    }

    var body: some View {
        HStack(spacing: 10) {
            leadingVisual

            VStack(alignment: .leading, spacing: 3) {
                Text(SensitivePreview.maskedPrimaryText(for: item, privacyMode: privacyMode, isRevealed: isRevealed))
                    .font(.system(size: 13, weight: item.normalizedCustomTitle != nil ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.kind.label)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.07))
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    if isSensitive {
                        Text("疑似敏感")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(isSelected ? Color.white.opacity(0.22) : Color.orange.opacity(0.16))
                            .foregroundStyle(isSelected ? .white : .orange)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    if let secondary = SensitivePreview.maskedSecondaryText(for: item, privacyMode: privacyMode, isRevealed: isRevealed) {
                        Text(secondary)
                            .font(.system(size: 11))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.82) : .secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text(Self.relativeTimeString(for: item.updatedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : .secondary)
                }
            }

            if isSelected || isHovered || isFavorited || isSensitive {
                HStack(spacing: 6) {
                    if (privacyMode || isSensitive) && (isSelected || isHovered || isRevealed) {
                        Button(action: onToggleReveal) {
                            Image(systemName: isRevealed ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isRevealed ? "重新遮罩 (⌘E)" : "临时查看原文 (⌘E)")
                    }

                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorited ? "star.fill" : "star")
                            .font(.system(size: 12))
                            .foregroundStyle(
                                isFavorited
                                    ? (isSelected ? Color.yellow : Color.orange)
                                    : (isSelected ? Color.white.opacity(0.85) : Color.secondary)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(isFavorited ? "取消收藏 (⌘D)" : "加入收藏 (⌘D)")

                    if tab == .favorites && (isSelected || isHovered) {
                        Button(action: onRename) {
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("重命名")
                    }

                    if isSelected || isHovered {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("删除 (⌘⌫)")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            let now = Date()
            onSelect()
            if let lastTapTime, now.timeIntervalSince(lastTapTime) <= NSEvent.doubleClickInterval {
                self.lastTapTime = nil
                onCopy()
            } else {
                self.lastTapTime = now
            }
        }
    }

    @ViewBuilder
    private var leadingVisual: some View {
        switch item.kind {
        case .image:
            if SensitivePreview.shouldMaskImage(privacyMode: privacyMode, isRevealed: isRevealed) {
                iconBadge(systemName: "eye.slash", tint: .orange)
            } else if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            } else {
                iconBadge(systemName: "photo", tint: .purple)
            }
        case .link:
            iconBadge(systemName: "link", tint: .blue)
        case .text:
            iconBadge(systemName: "doc.text", tint: .secondary)
        }
    }

    private func iconBadge(systemName: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.2) : tint.opacity(0.12))
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? .white : tint)
        }
        .frame(width: 34, height: 34)
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor
        }
        if isHovered {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relativeTimeString(for date: Date) -> String {
        let delta = Date().timeIntervalSince(date)
        if abs(delta) < 15 {
            return "刚刚"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableWindowView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableWindowView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
