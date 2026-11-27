import AppKit
import ClipboardDiagnostics
import Combine
import Foundation

@MainActor
public final class ClipboardStore: ObservableObject {
    @Published public private(set) var history: [ClipboardItem] = []
    @Published public private(set) var favorites: [ClipboardItem] = []
    @Published public private(set) var settings: ClipboardSettings = ClipboardSettings()
    @Published public private(set) var accessState: PasteboardAccessState = .unsupportedOS

    public let storage: ClipboardStorage
    private let diagnostics: ClipboardDiagnostics
    private let thumbnailCache = NSCache<NSString, NSImage>()

    public var onWriteToPasteboard: ((Int) -> Void)?

    public init(
        storage: ClipboardStorage = ClipboardStorage(),
        diagnostics: ClipboardDiagnostics? = nil
    ) {
        let resolvedDiagnostics = diagnostics ?? .shared
        self.storage = storage
        self.diagnostics = resolvedDiagnostics
        self.thumbnailCache.countLimit = 120
        let op = resolvedDiagnostics.begin("store", "snapshot_load")
        let snapshot = storage.loadSnapshot()
        self.history = snapshot.history
        self.favorites = snapshot.favorites
        self.settings = snapshot.settings
        trimHistoryIfNeeded()
        pruneUnusedImages()
        op.finish()
    }

    public var isRecordingPaused: Bool {
        settings.isRecordingPaused
    }

    public var isPrivacyModeEnabled: Bool {
        settings.isPrivacyModeEnabled
    }

    public var isMenuBarIconHidden: Bool {
        settings.hideMenuBarIcon
    }

    public var maxHistoryCount: Int {
        settings.maxHistoryCount
    }

    public func refreshAccessState(for pasteboard: NSPasteboard = .general) {
        let next = PasteboardFilter.accessState(for: pasteboard)
        if next != accessState {
            accessState = next
            switch next {
            case .alwaysDeny:
                diagnostics.record(.warning, module: "monitor", event: "access_state_denied")
            case .askOnAccess:
                diagnostics.record(.info, module: "monitor", event: "access_state_ask")
            case .alwaysAllow:
                diagnostics.record(.info, module: "monitor", event: "access_state_allowed")
            case .defaultPrompt:
                diagnostics.record(.info, module: "monitor", event: "access_state_default")
            case .unsupportedOS:
                break
            }
        }
    }

    // MARK: - Recording & Ingest

    @discardableResult
    public func ingest(
        _ payload: CapturedPayload,
        sourceAppName: String? = nil,
        now: Date = Date()
    ) -> ClipboardItem? {
        guard !settings.isRecordingPaused else {
            ClipboardLog.store.debug("ingest_skipped_paused")
            diagnostics.record(.debug, module: "store", event: "skipped_paused")
            return nil
        }

        let op = diagnostics.begin("store", "ingest")
        let hash = payload.contentHash

        // 重复复制同一内容时更新最近时间并置顶，避免出现多条重复记录。
        if let existingIndex = history.firstIndex(where: { $0.contentHash == hash }) {
            var existing = history.remove(at: existingIndex)
            existing.updatedAt = now
            history.insert(existing, at: 0)
            persist()
            ClipboardLog.store.debug("ingest_deduped kind=\(existing.kind.rawValue, privacy: .public)")
            op.finish(level: .debug)
            return existing
        }

        let newItem: ClipboardItem
        switch payload {
        case .text(let text):
            newItem = ClipboardItem(
                kind: .text,
                text: text,
                contentHash: hash,
                createdAt: now,
                updatedAt: now,
                sourceAppName: sourceAppName
            )
        case .link(let urlString):
            newItem = ClipboardItem(
                kind: .link,
                text: urlString,
                urlString: urlString,
                contentHash: hash,
                createdAt: now,
                updatedAt: now,
                sourceAppName: sourceAppName
            )
        case .image(let pngData, let width, let height):
            do {
                let fileName = try storage.saveImageData(pngData, contentHash: hash)
                newItem = ClipboardItem(
                    kind: .image,
                    imageFileName: fileName,
                    imageWidth: width,
                    imageHeight: height,
                    imageByteCount: pngData.count,
                    contentHash: hash,
                    createdAt: now,
                    updatedAt: now,
                    sourceAppName: sourceAppName
                )
            } catch {
                ClipboardLog.store.error("image_save_failed")
                op.finish(level: .error, errorCode: "image_save_failed")
                return nil
            }
        }

        history.insert(newItem, at: 0)
        trimHistoryIfNeeded()
        pruneUnusedImages()
        persist()
        ClipboardLog.store.debug("ingest_recorded kind=\(newItem.kind.rawValue, privacy: .public) history_count=\(self.history.count, privacy: .public)")
        op.finish(level: .info)
        return newItem
    }

    // MARK: - History Operations

    public func deleteHistoryItem(id: UUID) {
        let before = history.count
        history.removeAll { $0.id == id }
        guard history.count != before else { return }
        pruneUnusedImages()
        persist()
    }

    public func clearHistory() {
        guard !history.isEmpty else { return }
        history.removeAll()
        pruneUnusedImages()
        persist()
        ClipboardLog.store.info("history_cleared favorites_preserved=\(self.favorites.count, privacy: .public)")
        diagnostics.record(.info, module: "store", event: "history_cleared")
    }

    // MARK: - Favorites Operations

    public func isFavorited(_ item: ClipboardItem) -> Bool {
        favorites.contains { $0.contentHash == item.contentHash }
    }

    @discardableResult
    public func toggleFavorite(for item: ClipboardItem, now: Date = Date()) -> Bool {
        if let index = favorites.firstIndex(where: { $0.contentHash == item.contentHash }) {
            favorites.remove(at: index)
            pruneUnusedImages()
            persist()
            return false
        } else {
            let favoriteCopy = ClipboardItem(
                id: UUID(),
                kind: item.kind,
                title: item.title,
                text: item.text,
                urlString: item.urlString,
                imageFileName: item.imageFileName,
                imageWidth: item.imageWidth,
                imageHeight: item.imageHeight,
                imageByteCount: item.imageByteCount,
                contentHash: item.contentHash,
                createdAt: now,
                updatedAt: now,
                sourceAppName: item.sourceAppName
            )
            favorites.insert(favoriteCopy, at: 0)
            persist()
            return true
        }
    }

    public func removeFavorite(id: UUID) {
        let before = favorites.count
        favorites.removeAll { $0.id == id }
        guard favorites.count != before else { return }
        pruneUnusedImages()
        persist()
    }

    public func renameFavorite(id: UUID, title: String) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        favorites[index].title = trimmed.isEmpty ? nil : trimmed
        favorites[index].updatedAt = Date()
        persist()
    }

    // MARK: - Settings Operations

    public func setRecordingPaused(_ paused: Bool) {
        guard settings.isRecordingPaused != paused else { return }
        settings.isRecordingPaused = paused
        persist()
        ClipboardLog.store.info("recording_paused_changed paused=\(paused, privacy: .public)")
        diagnostics.record(.info, module: "monitor", event: paused ? "recording_paused" : "recording_resumed")
    }

    public func toggleRecordingPaused() {
        setRecordingPaused(!settings.isRecordingPaused)
    }

    public func setPrivacyModeEnabled(_ enabled: Bool) {
        guard settings.isPrivacyModeEnabled != enabled else { return }
        settings.isPrivacyModeEnabled = enabled
        persist()
        diagnostics.record(.info, module: "app", event: enabled ? "privacy_mode_enabled" : "privacy_mode_disabled")
    }

    public func togglePrivacyMode() {
        setPrivacyModeEnabled(!settings.isPrivacyModeEnabled)
    }

    public func setMenuBarIconHidden(_ hidden: Bool) {
        guard settings.hideMenuBarIcon != hidden else { return }
        settings.hideMenuBarIcon = hidden
        persist()
        diagnostics.record(.info, module: "app", event: hidden ? "menubar_icon_hidden" : "menubar_icon_shown")
    }

    public func setMaxHistoryCount(_ count: Int) {
        let clamped = ClipboardSettings.clampedMaxHistoryCount(count)
        guard settings.maxHistoryCount != clamped else { return }
        settings.maxHistoryCount = clamped
        trimHistoryIfNeeded()
        pruneUnusedImages()
        persist()
    }

    // MARK: - Search & Copy Back

    public func items(for tab: ClipboardTab, matching query: String) -> [ClipboardItem] {
        let source = tab == .history ? history : favorites
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return source }
        return source.filter { $0.matches(query: trimmed) }
    }

    @discardableResult
    public func copyToPasteboard(_ item: ClipboardItem, pasteboard: NSPasteboard = .general) -> Bool {
        let imageData: Data?
        if item.kind == .image, let fileName = item.imageFileName {
            imageData = storage.loadImageData(fileName: fileName)
        } else {
            imageData = nil
        }

        let op = diagnostics.begin("store", "copy_back")
        let success = PasteboardExtractor.write(item: item, imageData: imageData, to: pasteboard)
        if success {
            onWriteToPasteboard?(pasteboard.changeCount)
            ClipboardLog.store.debug("copy_back_succeeded kind=\(item.kind.rawValue, privacy: .public)")
            op.finish(level: .info)
        } else {
            ClipboardLog.store.error("copy_back_failed kind=\(item.kind.rawValue, privacy: .public)")
            op.finish(level: .error, errorCode: "copy_back_failed")
        }
        return success
    }

    // MARK: - Image Loading

    public func image(for item: ClipboardItem) -> NSImage? {
        guard item.kind == .image, let fileName = item.imageFileName else { return nil }
        let key = fileName as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        guard let data = storage.loadImageData(fileName: fileName),
              let image = NSImage(data: data) else {
            return nil
        }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Persistence Helpers

    private func trimHistoryIfNeeded() {
        let limit = settings.maxHistoryCount
        if history.count > limit {
            history.removeLast(history.count - limit)
        }
    }

    private func pruneUnusedImages() {
        var referenced = Set<String>()
        for item in history {
            if let name = item.imageFileName { referenced.insert(name) }
        }
        for item in favorites {
            if let name = item.imageFileName { referenced.insert(name) }
        }
        storage.pruneUnusedImages(keeping: referenced)
    }

    private func persist() {
        let snapshot = ClipboardSnapshot(
            schemaVersion: ClipboardSnapshot.currentSchemaVersion,
            history: history,
            favorites: favorites,
            settings: settings
        )
        do {
            try storage.saveSnapshot(snapshot)
        } catch {
            ClipboardLog.store.error("snapshot_save_failed")
            diagnostics.record(.error, module: "store", event: "snapshot_save", errorCode: "snapshot_save_failed")
        }
    }
}
