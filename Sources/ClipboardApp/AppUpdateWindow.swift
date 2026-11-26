import AppKit
import ClipboardCore
import ClipboardDiagnostics
import SwiftUI

@MainActor
final class AppUpdateWindowController: NSObject, NSWindowDelegate {
    private let model: AppUpdateModel
    private var window: NSWindow?

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    init(lastOutcome: UpdateOutcome?) {
        self.model = AppUpdateModel(lastOutcome: lastOutcome)
    }

    func showAndCheck() {
        let window = ensureWindow()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        model.check()
    }

    private func ensureWindow() -> NSWindow {
        if let existing = window { return existing }
        let hosting = NSHostingView(rootView: AppUpdateView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "检查更新"
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }
}

@MainActor
final class AppUpdateModel: ObservableObject {
    private let downloader = UpdateDownload()
    private var task: Task<Void, Never>?
    private let lastOutcome: UpdateOutcome?
    private let hasVerifiablePublisher: Bool

    @Published private(set) var offer: ReleasePackage?
    @Published private(set) var status = "点击「检查更新」查询 GitHub 最新正式版。"
    @Published private(set) var working = false

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    let isReleaseBuild = Bundle.main.bundleIdentifier == "dev.clipboard.app"

    var canInstallInApp: Bool {
        isReleaseBuild
            && hasVerifiablePublisher
            && UpdatePaths.canInstall(at: Bundle.main.bundleURL)
    }

    var releasePage: URL {
        offer?.page ?? URL(string: "https://github.com/kirktools/clipboard/releases")!
    }

    var installHint: String {
        if !isReleaseBuild {
            return "开发版请继续使用 make dev 更新。"
        }
        if UpdatePaths.isTranslocated(Bundle.main.bundleURL) {
            return "macOS 正从临时隔离路径运行 Clipboard。请先退出，将 Clipboard.app 拖入「应用程序」并从访达打开，或前往官方发布页手动下载。"
        }
        if !hasVerifiablePublisher {
            return "当前安装版本为 ad-hoc 签名或缺少可验证的发布者证书，应用内替换已停用。发现新版本时请点击「打开官方下载页」手动更新。"
        }
        if !UpdatePaths.canInstall(at: Bundle.main.bundleURL) {
            return "当前安装目录不可写，无法应用内替换。请将 Clipboard.app 放入可写的「应用程序」目录，或前往官方发布页手动更新。"
        }
        return "确认安装后将校验 SHA-256、架构与发布者证书，备份旧版后替换并重启。未公证版本首次打开可能需要在系统设置中确认。"
    }

    init(lastOutcome: UpdateOutcome?) {
        self.lastOutcome = lastOutcome
        if Bundle.main.bundleIdentifier == "dev.clipboard.app",
           let inspected = try? UpdateBundle.inspect(Bundle.main.bundleURL) {
            self.hasVerifiablePublisher = inspected.hasVerifiablePublisher
        } else {
            self.hasVerifiablePublisher = false
        }
        if let lastOutcome {
            self.status = lastOutcome.message
        }
    }

    func check() {
        guard !working else { return }
        offer = nil
        working = true
        status = "正在检查 GitHub 最新正式版…"
        task = Task {
            defer {
                working = false
                task = nil
            }
            let op = ClipboardDiagnostics.shared.begin("updates", "check")
            do {
                let current = try ReleaseVersion(currentVersion)
                let found = try await downloader.check(current: current)
                offer = found
                if let found {
                    status = "发现新版本 \(found.version)（当前 \(currentVersion)）。"
                } else {
                    status = "当前已是最新正式版（\(currentVersion)）。"
                }
                if let lastOutcome {
                    status += "\n" + lastOutcome.message
                }
                op.finish()
            } catch {
                let code = (error as? UpdateError)?.diagnosticCode ?? "update_check_failed"
                op.finish(level: .warning, errorCode: code)
                status = error.localizedDescription
                if let lastOutcome {
                    status += "\n" + lastOutcome.message
                }
            }
        }
    }

    func install() {
        guard !working, canInstallInApp, let offer else { return }
        working = true
        status = "正在下载并校验更新包…"
        task = Task {
            defer {
                working = false
                task = nil
            }
            let op = ClipboardDiagnostics.shared.begin("updates", "prepare")
            do {
                let prepared = try await downloader.prepare(offer, currentApp: Bundle.main.bundleURL)
                var handedOff = false
                defer { if !handedOff { prepared.clean() } }

                _ = try await prepared.startHelper(current: Bundle.main.bundleURL)
                handedOff = true
                status = "校验通过，正在退出并替换安装…"
                op.finish()
                RunLoop.main.perform(inModes: [.common]) {
                    NSApp.terminate(nil)
                }
            } catch {
                let code = (error as? UpdateError)?.diagnosticCode ?? "prepare_update_failed"
                op.finish(level: .error, errorCode: code)
                status = error.localizedDescription
            }
        }
    }
}

struct AppUpdateView: View {
    @ObservedObject var model: AppUpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isReleaseBuild ? "更新 Clipboard" : "更新 Clipboard Dev")
                .font(.title2.weight(.semibold))
            Text("当前版本 \(model.currentVersion)")
                .foregroundStyle(.secondary)
            Text(model.status)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.installHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if model.working {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Link("打开官方下载页", destination: model.releasePage)
                Button("检查更新", action: model.check)
                    .disabled(model.working)
                if model.canInstallInApp, model.offer != nil {
                    Button("更新并重启", action: model.install)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.working)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}
