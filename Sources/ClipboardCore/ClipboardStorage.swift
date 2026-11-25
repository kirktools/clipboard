import Foundation

public final class ClipboardStorage: @unchecked Sendable {
    public let baseDirectory: URL
    public let storeFileURL: URL
    public let imagesDirectory: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let resolvedBase = baseDirectory ?? Self.defaultBaseDirectory(fileManager: fileManager)
        self.baseDirectory = resolvedBase
        self.storeFileURL = resolvedBase.appendingPathComponent("store.json", isDirectory: false)
        self.imagesDirectory = resolvedBase.appendingPathComponent("images", isDirectory: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public static func defaultBaseDirectory(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folderName = (Bundle.main.object(forInfoDictionaryKey: "ClipboardDataDirectoryName") as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? "Clipboard"
        return appSupport.appendingPathComponent(folderName, isDirectory: true)
    }

    public func ensureDirectories() throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public func loadSnapshot() -> ClipboardSnapshot {
        guard fileManager.fileExists(atPath: storeFileURL.path) else {
            return ClipboardSnapshot()
        }
        do {
            let data = try Data(contentsOf: storeFileURL)
            var snapshot = try decoder.decode(ClipboardSnapshot.self, from: data)
            snapshot.settings.maxHistoryCount = ClipboardSettings.clampedMaxHistoryCount(snapshot.settings.maxHistoryCount)
            return snapshot
        } catch {
            ClipboardLog.store.error("snapshot_load_failed")
            return ClipboardSnapshot()
        }
    }

    public func saveSnapshot(_ snapshot: ClipboardSnapshot) throws {
        try ensureDirectories()
        let data = try encoder.encode(snapshot)
        try data.write(to: storeFileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeFileURL.path)
    }

    public func saveImageData(_ data: Data, contentHash: String) throws -> String {
        try ensureDirectories()
        let fileName = "\(contentHash).png"
        let fileURL = imagesDirectory.appendingPathComponent(fileName, isDirectory: false)
        if !fileManager.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        return fileName
    }

    public func imageURL(for fileName: String) -> URL {
        imagesDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    public func loadImageData(fileName: String) -> Data? {
        let url = imageURL(for: fileName)
        return try? Data(contentsOf: url)
    }

    /// 清理不再被最近历史或收藏引用的图片文件，确保收藏图片不会因历史淘汰或清空而丢失。
    public func pruneUnusedImages(keeping referencedFileNames: Set<String>) {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path) else {
            return
        }
        var removedCount = 0
        for name in entries where !referencedFileNames.contains(name) {
            let url = imagesDirectory.appendingPathComponent(name, isDirectory: false)
            if (try? fileManager.removeItem(at: url)) != nil {
                removedCount += 1
            }
        }
        if removedCount > 0 {
            ClipboardLog.store.debug("pruned_unused_images count=\(removedCount, privacy: .public)")
        }
    }
}
