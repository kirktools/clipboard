import AppKit
import ClipboardCore
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: ClipboardStore
    private let onConfirmClearHistory: () -> Void
    private let onCheckForUpdates: () -> Void
    private var window: NSWindow?

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    init(
        store: ClipboardStore,
        onConfirmClearHistory: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void
    ) {
        self.store = store
        self.onConfirmClearHistory = onConfirmClearHistory
        self.onCheckForUpdates = onCheckForUpdates
    }

    func show() {
        store.refreshAccessState()
        let window = ensureWindow()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func ensureWindow() -> NSWindow {
        if let existing = window {
            return existing
        }

        let hosting = NSHostingView(
            rootView: SettingsView(
                store: store,
                onConfirmClearHistory: onConfirmClearHistory,
                onCheckForUpdates: onCheckForUpdates
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 610),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        window.title = isDev ? "Clipboard Dev 设置" : "Clipboard 设置"
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        self.window = window
        return window
    }
}

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    let onConfirmClearHistory: () -> Void
    let onCheckForUpdates: () -> Void

    @StateObject private var diagnosticsModel = DiagnosticSettingsModel()
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
                Toggle(
                    "隐私模式（遮罩全部预览，适合录屏或直播）",
                    isOn: Binding(
                        get: { store.isPrivacyModeEnabled },
                        set: { store.setPrivacyModeEnabled($0) }
                    )
                )

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

            DiagnosticSettingsSection(model: diagnosticsModel)

            Section("通用与快捷键") {
                Toggle(
                    "隐藏顶部菜单栏图标",
                    isOn: Binding(
                        get: { store.isMenuBarIconHidden },
                        set: { store.setMenuBarIconHidden($0) }
                    )
                )
                Text("隐藏后可通过 Hotkey 快捷键呼出面板，点击面板右下角齿轮或按 ⌘, 随时回到设置重新显示。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

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

                HStack {
                    Button("检查更新…", action: onCheckForUpdates)
                        .controlSize(.small)
                    Spacer()
                    Button("退出 Clipboard") {
                        NSApp.terminate(nil)
                    }
                    .controlSize(.small)
                }

                Text("配合 Hotkey：在 Hotkey 的「应用快捷切换」中绑定 Clipboard.app 即可用全局快捷键呼出面板。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 610)
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
