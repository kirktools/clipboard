import Foundation

public struct UpdateError: LocalizedError, Sendable {
    public let message: String
    public let diagnosticCode: StaticString?

    public var errorDescription: String? { message }

    public init(_ message: String, diagnosticCode: StaticString? = nil) {
        self.message = message
        self.diagnosticCode = diagnosticCode
    }
}

public struct ReleaseVersion: Equatable, Comparable, CustomStringConvertible, Codable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ text: String) throws {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } && ($0 == "0" || !$0.hasPrefix("0")) }),
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else {
            throw UpdateError("版本号必须是 x.y.z：\(text)", diagnosticCode: "invalid_version")
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct ReleaseAsset: Decodable, Sendable {
    public let id: Int
    public let name: String
    public let size: Int
    public let browser_download_url: URL
    public let digest: String?

    public init(id: Int, name: String, size: Int, browser_download_url: URL, digest: String? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.browser_download_url = browser_download_url
        self.digest = digest
    }
}

public struct AppRelease: Decodable, Sendable {
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [ReleaseAsset]

    public init(tag_name: String, draft: Bool, prerelease: Bool, assets: [ReleaseAsset]) {
        self.tag_name = tag_name
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
    }

    public var version: ReleaseVersion {
        get throws { try ReleaseVersion(tag_name) }
    }

    public var page: URL {
        URL(string: "https://github.com/kirktools/clipboard/releases/tag/\(tag_name)")!
    }

    public func package(current: ReleaseVersion, architecture: String = Self.architecture) throws -> ReleasePackage? {
        guard !draft && !prerelease else {
            throw UpdateError("应用内更新只接受正式发布版本。", diagnosticCode: "non_release_rejected")
        }
        let version = try self.version
        guard tag_name == "v\(version)" else {
            throw UpdateError("Release 标签不是标准 vX.Y.Z。", diagnosticCode: "invalid_tag")
        }
        guard version > current else { return nil }
        let name = "Clipboard-\(version)-macos-\(architecture).zip"
        return try archive(named: name, version: version)
    }

    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func archive(named name: String, version: ReleaseVersion) throws -> ReleasePackage {
        ReleasePackage(
            version: version,
            tag: tag_name,
            archive: try asset(name, limit: 128 * 1024 * 1024),
            checksums: try asset("SHA256SUMS", limit: 64 * 1024),
            page: page
        )
    }

    private func asset(_ name: String, limit: Int) throws -> ReleaseAsset {
        let matches = assets.filter { $0.name == name }
        guard matches.count == 1,
              let asset = matches.first,
              asset.id > 0,
              asset.size > 0,
              asset.size <= limit,
              Self.isOfficialDownload(asset.browser_download_url, tag: tag_name, name: name) else {
            throw UpdateError("正式版缺少有效的 \(name)，或下载地址与大小不符合要求。", diagnosticCode: "asset_invalid")
        }
        return asset
    }

    public static func isOfficialDownload(_ url: URL, tag: String, name: String) -> Bool {
        url.scheme == "https"
            && url.host == "github.com"
            && url.user == nil
            && url.password == nil
            && (url.port == nil || url.port == 443)
            && url.query == nil
            && url.fragment == nil
            && url.path == "/kirktools/clipboard/releases/download/\(tag)/\(name)"
    }
}

public struct ReleasePackage: Sendable {
    public let version: ReleaseVersion
    public let tag: String
    public let archive: ReleaseAsset
    public let checksums: ReleaseAsset
    public let page: URL

    public func expectedHash(_ text: String) throws -> String {
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { return nil }
            let hash = String(fields[0]).lowercased()
            let name = String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard name == archive.name || name == "dist/\(archive.name)",
                  hash.count == 64,
                  hash.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
                return nil
            }
            return hash
        }
        guard matches.count == 1 else {
            throw UpdateError("SHA256SUMS 缺少唯一、有效的 ZIP 校验值。", diagnosticCode: "checksum_missing")
        }
        if let digest = archive.digest, digest != "sha256:\(matches[0])" {
            throw UpdateError("Release 的两份 SHA-256 校验信息不一致。", diagnosticCode: "checksum_mismatch")
        }
        return matches[0]
    }
}

/// 解压前校验 ZIP 中央目录：拒绝路径穿越、符号链接、重复路径、加密及超限包。
public enum UpdateZipPolicy {
    public static func validate(
        _ data: Data,
        root expectedRoot: String = "Clipboard.app",
        required: [String] = ["Contents/Info.plist", "Contents/MacOS/Clipboard"]
    ) throws {
        guard data.count >= 22, data.count <= 128 * 1024 * 1024 else {
            throw UpdateError("更新 ZIP 大小无效。", diagnosticCode: "archive_invalid")
        }
        func number(_ offset: Int, _ size: Int) throws -> Int {
            guard offset >= 0 && offset <= data.count - size else {
                throw UpdateError("更新 ZIP 结构不完整。", diagnosticCode: "archive_invalid")
            }
            return (0..<size).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }

        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try number(i, 4) == 0x06054b50, i + 22 + (try number(i + 20, 2)) == data.count {
                end = i
                break
            }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else {
            throw UpdateError("不支持分卷或不完整的更新 ZIP。", diagnosticCode: "archive_invalid")
        }

        let count = try number(end + 10, 2)
        let start = try number(end + 16, 4)
        let length = try number(end + 12, 4)
        guard count > 0 && count < 8192, try number(end + 8, 2) == count, start + length == end else {
            throw UpdateError("更新 ZIP 的目录无效或过大。", diagnosticCode: "archive_invalid")
        }

        var cursor = start
        var total = 0
        var paths = Set<String>()
        var appRoots = Set<String>()
        for _ in 0..<count {
            guard try number(cursor, 4) == 0x02014b50 else {
                throw UpdateError("更新 ZIP 的目录损坏。", diagnosticCode: "archive_invalid")
            }
            let flags = try number(cursor + 8, 2)
            let method = try number(cursor + 10, 2)
            let size = try number(cursor + 24, 4)
            let mode = try number(cursor + 38, 4) >> 16
            let nameLength = try number(cursor + 28, 2)
            let extra = try number(cursor + 30, 2)
            let comment = try number(cursor + 32, 2)
            let nameStart = cursor + 46
            let next = nameStart + nameLength + extra + comment

            guard next <= end,
                  flags & 1 == 0,
                  [0, 8].contains(method),
                  size < 512 * 1024 * 1024,
                  mode & 0o170000 != 0o120000,
                  mode & 0o170000 == 0 || [0o100000, 0o040000].contains(mode & 0o170000),
                  let name = String(data: data.subdata(in: nameStart..<nameStart + nameLength), encoding: .utf8) else {
                throw UpdateError("更新 ZIP 含不支持的条目。", diagnosticCode: "archive_invalid")
            }

            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"),
                  !name.contains("\\"),
                  !name.contains(":"),
                  !name.unicodeScalars.contains(where: { $0.value < 32 }),
                  !parts.dropLast().contains(""),
                  !parts.contains(".."),
                  !parts.contains("."),
                  [expectedRoot, "__MACOSX"].contains(String(parts.first ?? "")) else {
                throw UpdateError("更新 ZIP 含不安全路径。", diagnosticCode: "archive_invalid")
            }
            if parts.first != "__MACOSX", let root = parts.first {
                appRoots.insert(String(root).lowercased())
            }

            let local = try number(cursor + 42, 4)
            guard local >= 0 && local < start,
                  try number(local, 4) == 0x04034b50,
                  try number(local + 6, 2) == flags,
                  try number(local + 8, 2) == method else {
                throw UpdateError("ZIP 本地目录与中央目录不一致。", diagnosticCode: "archive_invalid")
            }
            let localNameLength = try number(local + 26, 2)
            guard local + 30 + localNameLength <= start,
                  String(data: data.subdata(in: local + 30..<local + 30 + localNameLength), encoding: .utf8) == name else {
                throw UpdateError("ZIP 本地文件路径不一致。", diagnosticCode: "archive_invalid")
            }

            let key = name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(key).inserted else {
                throw UpdateError("更新 ZIP 含重复路径。", diagnosticCode: "archive_invalid")
            }
            total += size
            guard total <= 512 * 1024 * 1024 else {
                throw UpdateError("更新解压内容超过 512 MB 限制。", diagnosticCode: "archive_invalid")
            }
            cursor = next
        }

        guard cursor == end,
              appRoots.count == 1,
              let root = appRoots.first,
              required.allSatisfy({ paths.contains(root + "/" + $0.lowercased()) }) else {
            throw UpdateError("更新 ZIP 缺少必要文件。", diagnosticCode: "archive_invalid")
        }
    }
}
