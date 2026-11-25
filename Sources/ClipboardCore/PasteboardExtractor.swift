import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PasteboardExtractor {
    /// 限制单张图片编码后的最大体积，避免超大位图占用过多内存和磁盘。
    public static let maxImageBytes = 20 * 1024 * 1024

    /// 从系统剪贴板提取受支持的内容（纯文本、链接或图片）。
    /// 调用前应先通过 `PasteboardFilter` 过滤敏感/临时内容。
    public static func extract(from pasteboard: NSPasteboard) -> CapturedPayload? {
        if PasteboardFilter.shouldIgnore(pasteboard: pasteboard) {
            return nil
        }

        let types = Set(pasteboard.types ?? [])
        let hasFileURL = types.contains(.fileURL)
        let hasPNG = types.contains(.png)
        let hasTIFF = types.contains(.tiff)

        // 1. 显式 PNG 图片且非 Finder 文件复制（如截图、浏览器复制图片、预览复制）优先按图片处理。
        if hasPNG && !hasFileURL, let payload = extractImage(from: pasteboard) {
            return payload
        }

        // 2. 非文件复制且无纯文本时的 TIFF 图片（如部分设计工具/截图工具）。
        let rawString = pasteboard.string(forType: .string)
        let hasNonEmptyString = rawString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        if hasTIFF && !hasFileURL && !hasNonEmptyString, let payload = extractImage(from: pasteboard) {
            return payload
        }

        // 3. 文本或链接。
        if let rawString, let textPayload = classifyText(rawString) {
            return textPayload
        }

        // 4. 仅存在 URL 类型时提取网页链接。
        if let urlString = pasteboard.string(forType: .URL), let linkPayload = classifyLink(urlString) {
            return linkPayload
        }

        // 5. 兜底提取图片（避免 Finder 文件图标误判为图片）。
        if !hasFileURL && (hasPNG || hasTIFF), let payload = extractImage(from: pasteboard) {
            return payload
        }

        return nil
    }

    /// 将纯文本分类为 `.link` 或 `.text`；纯空白返回 nil。
    public static func classifyText(_ raw: String) -> CapturedPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let link = classifyLink(trimmed) {
            return link
        }
        return .text(raw)
    }

    public static func classifyLink(_ raw: String) -> CapturedPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        return .link(trimmed)
    }

    /// 将图像数据规范化为 PNG 并返回像素宽高。
    public static func normalizeImageData(_ data: Data) -> (pngData: Data, width: Int, height: Int)? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        // 若原始数据已是合法 PNG 且体积在限制内，直接复用，保证哈希稳定且零额外损耗。
        if let typeIdentifier = CGImageSourceGetType(source) as String?,
           typeIdentifier == UTType.png.identifier,
           data.count <= maxImageBytes {
            return (data, width, height)
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]),
              pngData.count <= maxImageBytes else {
            return nil
        }
        return (pngData, width, height)
    }

    private static func extractImage(from pasteboard: NSPasteboard) -> CapturedPayload? {
        if let pngData = pasteboard.data(forType: .png),
           let normalized = normalizeImageData(pngData) {
            return .image(pngData: normalized.pngData, width: normalized.width, height: normalized.height)
        }
        if let tiffData = pasteboard.data(forType: .tiff),
           let normalized = normalizeImageData(tiffData) {
            return .image(pngData: normalized.pngData, width: normalized.width, height: normalized.height)
        }
        return nil
    }

    /// 将条目写回系统剪贴板，并附带内部标记避免监听层重复记录。
    @discardableResult
    public static func write(item: ClipboardItem, imageData: Data?, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let pbItem = NSPasteboardItem()
        pbItem.setData(Data([1]), forType: PasteboardFilter.internalCopyType)

        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            pbItem.setString(text, forType: .string)
            return pasteboard.writeObjects([pbItem])

        case .link:
            guard let urlString = item.urlString ?? item.text else { return false }
            pbItem.setString(urlString, forType: .string)
            pbItem.setString(urlString, forType: .URL)
            return pasteboard.writeObjects([pbItem])

        case .image:
            guard let imageData else { return false }
            pbItem.setData(imageData, forType: .png)
            if let image = NSImage(data: imageData), let tiff = image.tiffRepresentation {
                pbItem.setData(tiff, forType: .tiff)
            }
            return pasteboard.writeObjects([pbItem])
        }
    }
}
