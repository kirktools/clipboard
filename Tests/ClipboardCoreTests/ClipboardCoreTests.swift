import AppKit
import ClipboardCore
import ClipboardDiagnostics
import Foundation
import Testing
import UniformTypeIdentifiers

@MainActor
@Suite("ClipboardCore 验收测试")
struct ClipboardCoreTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSyntheticPNG(width: Int, height: Int, color: NSColor) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    @Test("复制文本、链接与图片，并支持去重更新最近时间")
    func ingestTextLinkImageAndDeduplicate() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClipboardStore(storage: ClipboardStorage(baseDirectory: dir))
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_060)
        let t3 = Date(timeIntervalSince1970: 1_700_000_120)
        let t4 = Date(timeIntervalSince1970: 1_700_000_180)

        let png = makeSyntheticPNG(width: 24, height: 16, color: .systemBlue)

        let textItem = store.ingest(.text("git status -sb"), now: t1)
        let linkItem = store.ingest(.link("https://example.com/docs"), now: t2)
        let imageItem = store.ingest(.image(pngData: png, width: 24, height: 16), now: t3)

        #expect(textItem?.kind == .text)
        #expect(linkItem?.kind == .link)
        #expect(imageItem?.kind == .image)
        #expect(store.history.count == 3)
        #expect(store.history[0].kind == .image)
        #expect(store.history[1].kind == .link)
        #expect(store.history[2].kind == .text)

        // 重复复制文本：更新最近时间并置顶，不产生重复记录。
        let deduped = store.ingest(.text("git status -sb"), now: t4)
        #expect(store.history.count == 3)
        #expect(deduped?.id == textItem?.id)
        #expect(store.history[0].id == textItem?.id)
        #expect(store.history[0].updatedAt == t4)
    }

    @Test("文本与链接分类以及关键词搜索")
    func classifyAndSearch() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PasteboardExtractor.classifyText("   \n\t ") == nil)
        #expect(PasteboardExtractor.classifyText("https://example.org/path?q=1") == .link("https://example.org/path?q=1"))
        #expect(PasteboardExtractor.classifyText("普通多行文本\nhttps://example.org") == .text("普通多行文本\nhttps://example.org"))

        let store = ClipboardStore(storage: ClipboardStorage(baseDirectory: dir))
        let cmd = store.ingest(.text("swift test --disable-xctest"))!
        _ = store.ingest(.link("https://example.com/swift-guide"))!
        store.toggleFavorite(for: cmd)
        let favID = store.favorites[0].id
        store.renameFavorite(id: favID, title: "常用测试命令")

        #expect(store.items(for: .history, matching: "swift").count == 2)
        #expect(store.items(for: .history, matching: "example.com").count == 1)
        #expect(store.items(for: .favorites, matching: "常用测试").count == 1)
        #expect(store.items(for: .favorites, matching: "常用测试 xctest").count == 1)
    }

    @Test("收藏独立于历史上限，清空历史与重启后仍保留完整文本与图片")
    func favoritesSurviveEvictionClearAndRestart() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storage = ClipboardStorage(baseDirectory: dir)
        let store = ClipboardStore(storage: storage)
        store.setMaxHistoryCount(10)

        let favPNG = makeSyntheticPNG(width: 32, height: 32, color: .systemGreen)
        let nonFavPNG = makeSyntheticPNG(width: 16, height: 16, color: .systemRed)

        let favText = store.ingest(.text("kubectl get pods -A"))!
        let favImage = store.ingest(.image(pngData: favPNG, width: 32, height: 32))!
        let nonFavImage = store.ingest(.image(pngData: nonFavPNG, width: 16, height: 16))!

        #expect(store.toggleFavorite(for: favText) == true)
        #expect(store.toggleFavorite(for: favImage) == true)

        // 写入足够多的新历史使上述条目因上限被淘汰。
        for i in 1...12 {
            store.ingest(.text("合成历史条目 \(i)"))
        }

        #expect(store.history.count == 10)
        #expect(store.favorites.count == 2)
        // 未收藏图片已被淘汰并清理，收藏图片仍在磁盘上。
        #expect(FileManager.default.fileExists(atPath: storage.imageURL(for: favImage.imageFileName!).path))
        #expect(!FileManager.default.fileExists(atPath: storage.imageURL(for: nonFavImage.imageFileName!).path))

        // 清空最近历史后，收藏及收藏图片必须完整保留。
        store.clearHistory()
        #expect(store.history.isEmpty)
        #expect(store.favorites.count == 2)
        #expect(FileManager.default.fileExists(atPath: storage.imageURL(for: favImage.imageFileName!).path))

        // 模拟应用重启：重新从磁盘加载。
        let restartedStore = ClipboardStore(storage: ClipboardStorage(baseDirectory: dir))
        #expect(restartedStore.history.isEmpty)
        #expect(restartedStore.favorites.count == 2)
        let restoredImageFav = restartedStore.favorites.first { $0.kind == .image }
        #expect(restoredImageFav != nil)
        #expect(restartedStore.image(for: restoredImageFav!) != nil)
        #expect(restartedStore.storage.loadImageData(fileName: restoredImageFav!.imageFileName!) == favPNG)
    }

    @Test("暂停记录期间不写入历史，恢复后正常记录")
    func pauseAndResumeRecording() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClipboardStore(storage: ClipboardStorage(baseDirectory: dir))
        store.setRecordingPaused(true)
        #expect(store.ingest(.text("暂停期间的文本")) == nil)
        #expect(store.history.isEmpty)

        store.setRecordingPaused(false)
        #expect(store.ingest(.text("恢复后的文本")) != nil)
        #expect(store.history.count == 1)
    }

    @Test("敏感、临时与自动生成标记内容不会被记录")
    func filterSensitiveAndTransientTypes() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        for marker in [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType",
            PasteboardFilter.internalCopyType.rawValue,
        ] {
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString("synthetic-secret-placeholder", forType: .string)
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
            board.writeObjects([item])

            #expect(PasteboardFilter.shouldIgnore(pasteboard: board))
            #expect(PasteboardExtractor.extract(from: board) == nil)
        }
    }

    @Test("选中历史重新复制回系统剪贴板不会产生重复记录")
    func copyBackDoesNotDuplicate() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        let store = ClipboardStore(storage: ClipboardStorage(baseDirectory: dir))
        let monitor = PasteboardMonitor(
            pasteboard: board,
            store: store,
            pollInterval: 10,
            stabilizationDelay: 0
        )

        let first = store.ingest(.text("第一条文本"))!
        _ = store.ingest(.text("第二条文本"))!

        let copied = store.copyToPasteboard(first, pasteboard: board)
        #expect(copied)
        #expect(board.string(forType: .string) == "第一条文本")

        monitor.pollOnce()
        #expect(store.history.count == 2)
        // 顺序保持不变且无重复记录。
        #expect(store.history[0].text == "第二条文本")
        #expect(store.history[1].text == "第一条文本")
    }

    @Test("划词翻译瞬态复制并恢复原剪贴板时不会污染历史")
    func transientCopyAndRestoreDoesNotPolluteHistory() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        // 初始系统剪贴板已有内容，并已记录在历史中。
        board.clearContents()
        board.setString("原剪贴板内容", forType: .string)

        let store = ClipboardStore(storage: ClipboardStorage(baseDirectory: dir))
        store.ingest(.text("原剪贴板内容"))

        let monitor = PasteboardMonitor(
            pasteboard: board,
            store: store,
            pollInterval: 10,
            stabilizationDelay: 0.12
        )

        // 模拟 Hotkey SelectionPasteboard.readByCopying：
        // 1) 临时写入划词文本；2) 监听层刚好在此刻轮询到变化；3) 30ms 后恢复原剪贴板。
        board.clearContents()
        board.setString("临时划词翻译文本", forType: .string)
        monitor.pollOnce()

        try await Task.sleep(for: .milliseconds(30))
        board.clearContents()
        board.setString("原剪贴板内容", forType: .string)

        // 等待防抖窗口结束。
        try await Task.sleep(for: .milliseconds(250))

        #expect(store.history.count == 1)
        #expect(store.history[0].text == "原剪贴板内容")
        #expect(!store.history.contains { $0.text == "临时划词翻译文本" })
    }

    @Test("诊断日志默认策略：Dev 默认开启，正式版默认关闭")
    func diagnosticsDefaultPolicy() {
        #expect(ClipboardDiagnostics.resolveEnabled(saved: nil, channel: .dev) == true)
        #expect(ClipboardDiagnostics.resolveEnabled(saved: nil, channel: .release) == false)
        #expect(ClipboardDiagnostics.resolveEnabled(saved: false, channel: .dev) == false)
        #expect(ClipboardDiagnostics.resolveEnabled(saved: true, channel: .release) == true)
    }

    @Test("诊断日志导出、筛选、清除与严格脱敏验证")
    func diagnosticsExportFilterClearAndRedaction() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let logsRoot = dir.appendingPathComponent("logs", isDirectory: true)
        let storeRoot = dir.appendingPathComponent("store", isDirectory: true)
        let exportURL = dir.appendingPathComponent("export.json", isDirectory: false)
        let failureExportURL = dir.appendingPathComponent("failures.json", isDirectory: false)

        let isolatedDomain = "dev.clipboard.app.test.\(UUID().uuidString)"
        let diagnostics = ClipboardDiagnostics(
            baseDirectory: logsRoot,
            preferenceDomain: isolatedDomain,
            forceEnableProcessRecording: true
        )
        defer {
            diagnostics.clearSavedPreference()
            let plistURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(isolatedDomain).plist")
            try? FileManager.default.removeItem(at: plistURL)
        }
        try diagnostics.setEnabled(true)

        let store = ClipboardStore(
            storage: ClipboardStorage(baseDirectory: storeRoot),
            diagnostics: diagnostics
        )

        let syntheticText = "SYNTHETIC_SECRET_CLIPBOARD_BODY_991827"
        let syntheticURL = "https://synthetic.example.invalid/token/abc987"
        let syntheticTitle = "SYNTHETIC_FAVORITE_TITLE_4421"
        let syntheticPNG = makeSyntheticPNG(width: 20, height: 20, color: .systemTeal)

        let textItem = store.ingest(.text(syntheticText))!
        let linkItem = store.ingest(.link(syntheticURL))!
        let imageItem = store.ingest(.image(pngData: syntheticPNG, width: 20, height: 20))!
        store.toggleFavorite(for: textItem)
        store.renameFavorite(id: store.favorites[0].id, title: syntheticTitle)
        store.setRecordingPaused(true)
        _ = store.ingest(.text("SYNTHETIC_PAUSED_SHOULD_NOT_RECORD"))
        store.setRecordingPaused(false)
        store.clearHistory()
        diagnostics.record(.warning, module: "monitor", event: "skipped_access_denied", errorCode: "pasteboard_access_denied")

        let totalExported = try await diagnostics.export(to: exportURL)
        #expect(totalExported > 0)

        let exportedText = try String(contentsOf: exportURL, encoding: .utf8)
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        for forbidden in [
            syntheticText,
            syntheticURL,
            syntheticTitle,
            textItem.contentHash,
            linkItem.contentHash,
            imageItem.contentHash,
            "SYNTHETIC_PAUSED_SHOULD_NOT_RECORD",
            homePath,
        ] {
            #expect(!exportedText.contains(forbidden))
        }

        let failureCount = try await diagnostics.export(to: failureExportURL, module: "monitor", failuresOnly: true)
        #expect(failureCount >= 1)

        try await diagnostics.clear()
        let afterClearURL = dir.appendingPathComponent("after-clear.json", isDirectory: false)
        let afterClearCount = try await diagnostics.export(to: afterClearURL)
        #expect(afterClearCount == 0)
    }

    @Test("从多种剪贴板来源提取图片：PNG/JPEG、浏览器附带链接的 TIFF、访达图片文件，并排除普通文件图标与富文本")
    func extractImagesFromRealWorldPasteboardSources() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        let png = makeSyntheticPNG(width: 28, height: 18, color: .systemOrange)
        let image = NSImage(data: png)!
        let tiff = image.tiffRepresentation!
        let bitmap = NSBitmapImageRep(data: tiff)!
        let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!

        // 1. 直接 JPEG 数据（附带文件名文本）
        board.clearContents()
        let jpegItem = NSPasteboardItem()
        jpegItem.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        jpegItem.setString("sample.jpg", forType: .string)
        board.writeObjects([jpegItem])
        if case .image(_, let w, let h) = PasteboardExtractor.extract(from: board) {
            #expect(w == 28 && h == 18)
        } else {
            Issue.record("应当从 JPEG 剪贴板提取出图片")
        }

        // 2. 浏览器/聊天软件复制图片：TIFF + 图片链接，无 RTF
        board.clearContents()
        let browserItem = NSPasteboardItem()
        browserItem.setData(tiff, forType: .tiff)
        browserItem.setString("https://example.com/photo.png", forType: .string)
        board.writeObjects([browserItem])
        if case .image(_, let w, let h) = PasteboardExtractor.extract(from: board) {
            #expect(w == 28 && h == 18)
        } else {
            Issue.record("应当优先提取浏览器/聊天软件复制的图片而非链接")
        }

        // 3. 访达复制单个本地图片文件
        let imageFileURL = dir.appendingPathComponent("synthetic-photo.png")
        try png.write(to: imageFileURL)
        board.clearContents()
        board.writeObjects([imageFileURL as NSURL])
        if case .image(_, let w, let h) = PasteboardExtractor.extract(from: board) {
            #expect(w == 28 && h == 18)
        } else {
            Issue.record("应当支持提取访达复制的本地图片文件")
        }

        // 4. 访达复制非图片文件（附带文件图标 TIFF）不应误判为图片
        let textFileURL = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: textFileURL)
        board.clearContents()
        let nonImageFileItem = NSPasteboardItem()
        nonImageFileItem.setString(textFileURL.absoluteString, forType: .fileURL)
        nonImageFileItem.setString("notes.txt", forType: .string)
        nonImageFileItem.setData(tiff, forType: .tiff)
        board.writeObjects([nonImageFileItem])
        #expect(PasteboardExtractor.extract(from: board) == .text("notes.txt"))

        // 5. 富文本复制（RTF + 纯文本 + 渲染预览 TIFF）应保持为文本而非图片
        board.clearContents()
        let rtfItem = NSPasteboardItem()
        rtfItem.setData(Data("{\\rtf1 hello}".utf8), forType: .rtf)
        rtfItem.setString("富文本正文", forType: .string)
        rtfItem.setData(tiff, forType: .tiff)
        board.writeObjects([rtfItem])
        #expect(PasteboardExtractor.extract(from: board) == .text("富文本正文"))

        // 6. 微信等沙盒应用复制图片（file-url 指向受保护 Containers 目录 + 剪贴板附带 TIFF），
        //    必须绕过容器磁盘文件读取，直接从剪贴板提取图片，避免触发 macOS 数据访问拦截。
        let protectedURL = URL(fileURLWithPath: "/Users/example/Library/Containers/com.example.chat/Data/temp.jpg")
        #expect(PasteboardExtractor.isProtectedAppContainerPath(protectedURL))
        board.clearContents()
        let wechatLikeItem = NSPasteboardItem()
        wechatLikeItem.setString(protectedURL.absoluteString, forType: .fileURL)
        wechatLikeItem.setData(tiff, forType: .tiff)
        board.writeObjects([wechatLikeItem])
        if case .image(_, let w, let h) = PasteboardExtractor.extract(from: board) {
            #expect(w == 28 && h == 18)
        } else {
            Issue.record("应当直接从剪贴板提取受保护容器应用的图片而不访问其磁盘容器")
        }
    }
}
