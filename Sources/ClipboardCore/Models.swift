import CryptoKit
import Foundation

public enum ClipboardKind: String, Codable, Sendable, CaseIterable {
    case text
    case link
    case image

    public var label: String {
        switch self {
        case .text: "文本"
        case .link: "链接"
        case .image: "图片"
        }
    }
}

public enum ClipboardTab: String, CaseIterable, Sendable {
    case history
    case favorites

    public var title: String {
        switch self {
        case .history: "最近"
        case .favorites: "收藏"
        }
    }
}

public struct ClipboardSettings: Codable, Equatable, Sendable {
    public static let defaultMaxHistoryCount = 50
    public static let minHistoryCount = 10
    public static let maxHistoryCountLimit = 500

    public var maxHistoryCount: Int
    public var isRecordingPaused: Bool

    public init(
        maxHistoryCount: Int = ClipboardSettings.defaultMaxHistoryCount,
        isRecordingPaused: Bool = false
    ) {
        self.maxHistoryCount = Self.clampedMaxHistoryCount(maxHistoryCount)
        self.isRecordingPaused = isRecordingPaused
    }

    public static func clampedMaxHistoryCount(_ value: Int) -> Int {
        min(max(value, minHistoryCount), maxHistoryCountLimit)
    }
}

public struct ClipboardItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: ClipboardKind
    public var title: String?
    public let text: String?
    public let urlString: String?
    public let imageFileName: String?
    public let imageWidth: Int?
    public let imageHeight: Int?
    public let imageByteCount: Int?
    public let contentHash: String
    public let createdAt: Date
    public var updatedAt: Date
    public let sourceAppName: String?

    public init(
        id: UUID = UUID(),
        kind: ClipboardKind,
        title: String? = nil,
        text: String? = nil,
        urlString: String? = nil,
        imageFileName: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        imageByteCount: Int? = nil,
        contentHash: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceAppName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.urlString = urlString
        self.imageFileName = imageFileName
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imageByteCount = imageByteCount
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceAppName = sourceAppName
    }

    /// 供列表主标题展示的单行摘要。
    public var primaryDisplayText: String {
        if let custom = normalizedCustomTitle {
            return custom
        }
        switch kind {
        case .text:
            return Self.singleLinePreview(text ?? "")
        case .link:
            return urlString ?? Self.singleLinePreview(text ?? "")
        case .image:
            if let width = imageWidth, let height = imageHeight {
                return "图片 \(width) × \(height)"
            }
            return "图片"
        }
    }

    /// 当条目拥有自定义名称时，在副标题中显示原始内容预览。
    public var secondaryDisplayText: String? {
        guard normalizedCustomTitle != nil else {
            switch kind {
            case .text:
                let lines = (text ?? "").components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return lines.count > 1 ? lines.dropFirst().joined(separator: " · ") : nil
            case .link:
                if let urlString, let url = URL(string: urlString), let host = url.host, !host.isEmpty {
                    return host
                }
                return nil
            case .image:
                return formattedImageMeta
            }
        }

        switch kind {
        case .text:
            return Self.singleLinePreview(text ?? "")
        case .link:
            return urlString
        case .image:
            return formattedImageMeta
        }
    }

    public var formattedImageMeta: String? {
        var parts: [String] = []
        if let w = imageWidth, let h = imageHeight {
            parts.append("\(w) × \(h)")
        }
        if let bytes = imageByteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var normalizedCustomTitle: String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// 搜索匹配：支持按条目名称、文本内容和链接进行多词不区分大小写匹配。
    public func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let terms = trimmed.split(whereSeparator: \.isWhitespace).map { String($0) }
        guard !terms.isEmpty else { return true }

        let haystacks: [String] = [
            title,
            text,
            urlString,
            kind == .image ? "图片 image" : nil,
        ].compactMap { $0 }

        return terms.allSatisfy { term in
            haystacks.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    private static func singleLinePreview(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "（空白文本）" : collapsed
    }
}

public struct ClipboardSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var history: [ClipboardItem]
    public var favorites: [ClipboardItem]
    public var settings: ClipboardSettings

    public init(
        schemaVersion: Int = ClipboardSnapshot.currentSchemaVersion,
        history: [ClipboardItem] = [],
        favorites: [ClipboardItem] = [],
        settings: ClipboardSettings = ClipboardSettings()
    ) {
        self.schemaVersion = schemaVersion
        self.history = history
        self.favorites = favorites
        self.settings = settings
    }
}

public enum CapturedPayload: Equatable, Sendable {
    case text(String)
    case link(String)
    case image(pngData: Data, width: Int, height: Int)

    public var kind: ClipboardKind {
        switch self {
        case .text: .text
        case .link: .link
        case .image: .image
        }
    }

    public var contentHash: String {
        switch self {
        case .text(let value):
            return Self.sha256Hex(prefix: "text:", data: Data(value.utf8))
        case .link(let value):
            return Self.sha256Hex(prefix: "link:", data: Data(value.utf8))
        case .image(let pngData, _, _):
            return Self.sha256Hex(prefix: "image:", data: pngData)
        }
    }

    private static func sha256Hex(prefix: String, data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(prefix.utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
