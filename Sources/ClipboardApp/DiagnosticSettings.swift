import AppKit
import ClipboardDiagnostics
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DiagnosticSettingsModel: ObservableObject {
    enum Module: String, CaseIterable {
        case all = "全部"
        case monitor = "剪贴板监听"
        case store = "存储与记录"
        case app = "应用与面板"

        var code: StaticString? {
            switch self {
            case .all: return nil
            case .monitor: return "monitor"
            case .store: return "store"
            case .app: return "app"
            }
        }
    }

    @Published private(set) var isEnabled: Bool
    @Published var days = 1
    @Published var module: Module = .all
    @Published var failuresOnly = false
    @Published private(set) var busy = false
    @Published private(set) var status: String?

    private let diagnostics: ClipboardDiagnostics

    init(diagnostics: ClipboardDiagnostics? = nil) {
        let resolved = diagnostics ?? .shared
        self.diagnostics = resolved
        self.isEnabled = resolved.isEnabled
    }

    func refresh() {
        isEnabled = diagnostics.isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try diagnostics.setEnabled(enabled)
            status = enabled ? "已开启本机诊断日志。" : "已关闭本机诊断日志。"
        } catch {
            status = "无法保存日志设置，请重试。"
        }
        isEnabled = diagnostics.isEnabled
    }

    func exportLogs() async {
        guard !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let suffix = diagnostics.channel == .dev ? "-Dev" : ""
        panel.nameFieldStringValue = "Clipboard\(suffix)-Diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        busy = true
        defer { busy = false }
        let since = days == 0 ? nil : Date().addingTimeInterval(-Double(days) * 86400)
        do {
            let count = try await diagnostics.export(
                to: url,
                since: since,
                module: module.code,
                failuresOnly: failuresOnly
            )
            status = "已导出 \(count) 条诊断记录。"
        } catch {
            status = "导出失败，请检查目标目录写入权限。"
        }
    }

    func clearLogs() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await diagnostics.clear()
            status = "已清除当前通道的本机诊断日志。"
        } catch {
            status = "清除日志失败，请重试。"
        }
    }
}

struct DiagnosticSettingsSection: View {
    @ObservedObject var model: DiagnosticSettingsModel

    var body: some View {
        Section("本机诊断日志") {
            Toggle(
                "记录本机诊断日志",
                isOn: Binding(
                    get: { model.isEnabled },
                    set: { model.setEnabled($0) }
                )
            )
            Text("正式版默认关闭，开发版默认开启。仅记录监听状态、权限变化、跳过原因、存储失败与耗时，不包含剪贴板正文、链接、图片、收藏标题、内容哈希或个人路径。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("导出时段", selection: $model.days) {
                Text("最近 24 小时").tag(1)
                Text("最近 7 天").tag(7)
                Text("全部保留记录").tag(0)
            }
            Picker("导出模块", selection: $model.module) {
                ForEach(DiagnosticSettingsModel.Module.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            Toggle("仅导出警告及错误", isOn: $model.failuresOnly)

            HStack {
                Button("导出诊断日志…") {
                    Task { await model.exportLogs() }
                }
                .disabled(model.busy)

                Button("清除日志") {
                    Task { await model.clearLogs() }
                }
                .disabled(model.busy)
            }

            if let status = model.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            model.refresh()
        }
    }
}
