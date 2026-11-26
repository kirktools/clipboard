import Foundation
import KirkLogging
import os

public enum ClipboardChannel: String, Sendable {
    case release
    case dev

    public var diagnosticChannel: DiagnosticChannel {
        switch self {
        case .release: return .release
        case .dev: return .dev
        }
    }

    public static func current(bundle: Bundle = .main) -> ClipboardChannel {
        let id = bundle.bundleIdentifier ?? ""
        return id.hasSuffix(".dev") ? .dev : .release
    }
}

/// 本机诊断日志控制器：复用 KirkLogging 实现异步写入、文件轮转、筛选导出与清除。
/// 所有字段均限定为编译期静态常量或数值/随机 UUID，严禁记录剪贴板正文、链接、图片、
/// 收藏标题、内容哈希、凭据、个人路径或原始错误文本。
@MainActor
public final class ClipboardDiagnostics {
    public static let shared = ClipboardDiagnostics()

    public let channel: ClipboardChannel
    public let preferenceDomain: String
    private let config: DiagnosticLog.Configuration
    private let baseDirectory: URL?
    private let isAppProcess: Bool
    private var logger: DiagnosticLog?

    private static let enabledPreferenceKey = "diagnosticLoggingEnabled" as CFString
    private static let osSubsystem = Bundle.main.bundleIdentifier ?? "dev.clipboard.app"
    private static let osLog = Logger(subsystem: osSubsystem, category: "diagnostics")

    public init(
        bundle: Bundle = .main,
        baseDirectory: URL? = nil,
        preferenceDomain: String? = nil,
        forceEnableProcessRecording: Bool? = nil
    ) {
        let id = bundle.bundleIdentifier ?? ""
        let resolvedChannel = ClipboardChannel.current(bundle: bundle)
        self.channel = resolvedChannel
        let domain = preferenceDomain ?? (resolvedChannel == .dev ? "dev.clipboard.app.dev" : "dev.clipboard.app")
        self.preferenceDomain = domain
        self.baseDirectory = baseDirectory

        let baseID = id.hasSuffix(".dev") ? String(id.dropLast(".dev".count)) : id
        self.isAppProcess = forceEnableProcessRecording ?? (baseID == "dev.clipboard.app")

        let version = Self.sanitizedIdentifier(
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            fallback: "0.0.0"
        )
        let build = Self.sanitizedIdentifier(
            bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            fallback: "0"
        )
        self.config = DiagnosticLog.Configuration(
            app: "Clipboard",
            channel: resolvedChannel.diagnosticChannel,
            role: "host",
            version: version,
            build: build
        )
    }

    /// 解析默认开关：Dev 默认开启，正式版默认关闭。
    public static func resolveEnabled(saved: Bool?, channel: ClipboardChannel) -> Bool {
        if let saved { return saved }
        return channel == .dev
    }

    public var isEnabled: Bool {
        let domain = preferenceDomain as CFString
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let saved = CFPreferencesCopyValue(
            Self.enabledPreferenceKey,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? Bool
        return Self.resolveEnabled(saved: saved, channel: channel)
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            _ = try writer()
        }
        let domain = preferenceDomain as CFString
        CFPreferencesSetValue(
            Self.enabledPreferenceKey,
            enabled ? kCFBooleanTrue : kCFBooleanFalse,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw CocoaError(.fileWriteUnknown)
        }
        logger?.setEnabled(enabled)
    }

    public var logDirectory: URL? {
        try? writer().directory
    }

    private func writer() throws -> DiagnosticLog {
        if let logger { return logger }
        let instance = try DiagnosticLog(
            configuration: config,
            enabled: false,
            baseDirectory: baseDirectory
        )
        logger = instance
        return instance
    }

    public func record(
        _ level: DiagnosticLevel,
        module: StaticString,
        event: StaticString,
        operationID: UUID? = nil,
        errorCode: StaticString? = nil,
        elapsedMS: Double? = nil
    ) {
        Self.osLog.debug("\(module, privacy: .public).\(event, privacy: .public)")
        guard isAppProcess, isEnabled, let logger = try? writer() else { return }
        logger.setEnabled(true)
        logger.record(
            level,
            module: module,
            event: event,
            operationID: operationID,
            errorCode: errorCode,
            elapsedMS: elapsedMS
        )
    }

    public func begin(_ module: StaticString, _ event: StaticString) -> DiagnosticOperation {
        let op = DiagnosticOperation(module: module, event: event, diagnostics: self)
        record(.info, module: module, event: event, operationID: op.id)
        return op
    }

    public func export(
        to url: URL,
        since: Date? = nil,
        module: StaticString? = nil,
        failuresOnly: Bool = false
    ) async throws -> Int {
        let levels: Set<DiagnosticLevel> = failuresOnly ? [.warning, .error] : []
        return try await writer().export(
            to: url,
            matching: DiagnosticFilter(since: since, module: module, levels: levels)
        )
    }

    public func clear() async throws {
        try await writer().clear()
    }

    /// 清除当前偏好域下保存的诊断开关（用于测试隔离清理）。
    public func clearSavedPreference() {
        UserDefaults.standard.removePersistentDomain(forName: preferenceDomain)
        let domain = preferenceDomain as CFString
        CFPreferencesSetValue(
            Self.enabledPreferenceKey,
            nil,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func sanitizedIdentifier(_ raw: String?, fallback: String) -> String {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 96,
              raw != ".", raw != "..",
              raw.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
              }) else {
            return fallback
        }
        return raw
    }
}

public struct DiagnosticOperation {
    public let module: StaticString
    public let event: StaticString
    public let id = UUID()
    private let start = ContinuousClock.now
    private let diagnostics: ClipboardDiagnostics

    init(module: StaticString, event: StaticString, diagnostics: ClipboardDiagnostics) {
        self.module = module
        self.event = event
        self.diagnostics = diagnostics
    }

    @MainActor
    public func finish(level: DiagnosticLevel? = nil, errorCode: StaticString? = nil) {
        let duration = start.duration(to: .now).components
        let millis = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        diagnostics.record(
            level ?? (errorCode == nil ? .info : .error),
            module: module,
            event: event,
            operationID: id,
            errorCode: errorCode,
            elapsedMS: millis
        )
    }
}
