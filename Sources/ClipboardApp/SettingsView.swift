import AppKit
import ClipboardCore
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: ClipboardStore
    private let onConfirmClearHistory: () -> Void
    private var window: NSWindow?

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    init(store: ClipboardStore, onConfirmClearHistory: @escaping () -> Void) {
        self.store = store
        self.onConfirmClearHistory = onConfirmClearHistory
    }

    func show() {
        store.refreshAccessState()
        let window = ensureWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let existing = window {
            return existing
        }

        let hosting = NSHostingView(
            rootView: SettingsView(
                store: store,
                onConfirmClearHistory: onConfirmClearHistory
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard 设置"
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }
}

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    let onConfirmClearHistory: () -> Void

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    private let presets = [20, 50, 100, 200]

    var body: some View {
        Form {
            Section("最近历史") {
                HStack {
                    Text("保留最近条数")
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { store.maxHistoryCount },
                            set: { store.setMaxHistoryCount($0) }
                        ),
                        in: ClipboardSettings.minHistoryCount...ClipboardSettings.maxHistoryCountLimit,
                        step: 10
                    ) {
                        Text("\(store.maxHistoryCount) 条")
                            .monospacedDigit()
                    }
                }

                HStack(spacing: 6) {
                    Text("常用预设")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    Spacer()
                    ForEach(presets, id: \.self) { value in
                        Button("\(value)") {
                            store.setMaxHistoryCount(value)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .tint(store.maxHistoryCount == value ? .accentColor : nil)
                    }
                }

                Toggle(
                    "暂停记录剪贴板",
                    isOn: Binding(
                        get: { store.isRecordingPaused },
                        set: { store.setRecordingPaused($0) }
                    )
                )

                HStack {
                    Text("当前已存 \(store.history.count) 条最近记录，\(store.favorites.count) 条收藏")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清空最近历史…") {
                        onConfirmClearHistory()
                    }
                    .disabled(store.history.isEmpty)
                }
            }

            Section("剪贴板访问与隐私") {
                HStack(alignment: .top, spacing: 8) {
                    Text("系统授权状态")
                    Spacer()
                    Text(store.accessState.statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(store.accessState.needsUserAttention ? .orange : .secondary)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Text("敏感或临时标记的内容会自动跳过；剪贴板内容仅保存在本机。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("系统设置…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }

            Section("通用与快捷键") {
                Toggle("登录时静默启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        updateLoginItem(enabled: enabled)
                    }

                if let loginItemError {
                    Text(loginItemError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                HStack {
                    Text("本地数据目录")
                    Spacer()
                    Button("在访达中显示") {
                        try? store.storage.ensureDirectories()
                        NSWorkspace.shared.activateFileViewerSelecting([store.storage.baseDirectory])
                    }
                    .controlSize(.small)
                }

                Text("配合 Hotkey：在 Hotkey 的「应用快捷切换」中绑定 Clipboard.app 即可用全局快捷键呼出或收起历史面板。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 420)
        .onAppear {
            store.refreshAccessState()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func updateLoginItem(enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemError = "无法更新登录项（开发签名构建可能需要先放入「应用程序」目录）。"
        }
    }
}
