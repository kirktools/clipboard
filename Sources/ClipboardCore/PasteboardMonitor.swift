import AppKit
import ClipboardDiagnostics
import Foundation

/// 监听系统剪贴板变化并写入 `ClipboardStore`。
/// 内置短暂稳定防抖窗口（默认 120ms），可自动吸收划词翻译等工具的“临时复制再恢复原剪贴板”瞬态写入。
@MainActor
public final class PasteboardMonitor {
    private let pasteboard: NSPasteboard
    private let store: ClipboardStore
    private let diagnostics: ClipboardDiagnostics
    private let pollInterval: TimeInterval
    private let stabilizationDelay: TimeInterval

    private var timer: Timer?
    private var settleWorkItem: DispatchWorkItem?
    private var lastObservedChangeCount: Int
    private var lastSelfWriteChangeCount: Int?
    private var pendingChangeCount: Int?

    public init(
        pasteboard: NSPasteboard = .general,
        store: ClipboardStore,
        diagnostics: ClipboardDiagnostics? = nil,
        pollInterval: TimeInterval = 0.30,
        stabilizationDelay: TimeInterval = 0.12
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.diagnostics = diagnostics ?? .shared
        self.pollInterval = pollInterval
        self.stabilizationDelay = stabilizationDelay
        self.lastObservedChangeCount = pasteboard.changeCount

        store.onWriteToPasteboard = { [weak self] changeCount in
            self?.markSelfWrite(changeCount: changeCount)
        }
    }

    public func start() {
        guard timer == nil else { return }
        lastObservedChangeCount = pasteboard.changeCount
        store.refreshAccessState(for: pasteboard)
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollOnce()
            }
        }
        timer.tolerance = min(pollInterval * 0.25, 0.1)
        self.timer = timer
        ClipboardLog.monitor.info("monitor_started")
        diagnostics.record(.info, module: "monitor", event: "monitor_started")
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        settleWorkItem?.cancel()
        settleWorkItem = nil
        pendingChangeCount = nil
        ClipboardLog.monitor.info("monitor_stopped")
        diagnostics.record(.info, module: "monitor", event: "monitor_stopped")
    }

    public func markSelfWrite(changeCount: Int) {
        lastSelfWriteChangeCount = changeCount
        lastObservedChangeCount = changeCount
        settleWorkItem?.cancel()
        settleWorkItem = nil
        pendingChangeCount = nil
    }

    /// 供定时器和测试调用的单次轮询。
    public func pollOnce() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastObservedChangeCount else { return }
        lastObservedChangeCount = currentCount

        if lastSelfWriteChangeCount == currentCount {
            diagnostics.record(.debug, module: "monitor", event: "skipped_self_write")
            return
        }

        guard !store.isRecordingPaused else {
            diagnostics.record(.debug, module: "monitor", event: "skipped_paused")
            return
        }

        scheduleStabilizedRead(for: currentCount)
    }

    private func scheduleStabilizedRead(for targetChangeCount: Int) {
        settleWorkItem?.cancel()
        pendingChangeCount = targetChangeCount

        if stabilizationDelay <= 0 {
            processIfSettled(expectedChangeCount: targetChangeCount)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.processIfSettled(expectedChangeCount: targetChangeCount)
            }
        }
        settleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + stabilizationDelay, execute: workItem)
    }

    private func processIfSettled(expectedChangeCount: Int) {
        let currentCount = pasteboard.changeCount
        if currentCount != expectedChangeCount {
            // 剪贴板在稳定窗口内再次变化（例如划词翻译完成了“临时复制→恢复原剪贴板”）。
            // 放弃中间态，重新针对最新 changeCount 等待稳定。
            diagnostics.record(.debug, module: "monitor", event: "skipped_transient_change")
            lastObservedChangeCount = currentCount
            if lastSelfWriteChangeCount != currentCount, !store.isRecordingPaused {
                scheduleStabilizedRead(for: currentCount)
            }
            return
        }

        pendingChangeCount = nil
        settleWorkItem = nil

        guard !store.isRecordingPaused else { return }
        guard lastSelfWriteChangeCount != currentCount else { return }

        store.refreshAccessState(for: pasteboard)
        if store.accessState == .alwaysDeny {
            ClipboardLog.monitor.warning("pasteboard_access_denied")
            diagnostics.record(.warning, module: "monitor", event: "skipped_access_denied", errorCode: "pasteboard_access_denied")
            return
        }

        if PasteboardFilter.shouldIgnore(pasteboard: pasteboard) {
            ClipboardLog.monitor.debug("pasteboard_ignored_by_filter")
            diagnostics.record(.debug, module: "monitor", event: "skipped_filtered")
            return
        }

        guard let payload = PasteboardExtractor.extract(from: pasteboard) else {
            diagnostics.record(.debug, module: "monitor", event: "skipped_empty_or_unsupported")
            return
        }

        // 若稳定后的内容与历史顶部完全一致（例如划词翻译恢复了之前的剪贴板内容），
        // 直接复用现有顶部条目，不产生重复记录也不打乱顺序。
        if let top = store.history.first, top.contentHash == payload.contentHash {
            // 仍更新最近时间以符合“重复复制同一内容时更新最近时间”的规则。
            _ = store.ingest(payload, sourceAppName: frontmostAppName())
            return
        }

        _ = store.ingest(payload, sourceAppName: frontmostAppName())
    }

    private func frontmostAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        return app.localizedName
    }
}
