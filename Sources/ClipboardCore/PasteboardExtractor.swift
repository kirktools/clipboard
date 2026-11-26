import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PasteboardExtractor {
    /// 限制单张图片编码后的最大体积，避免超大位图占用过多内存和磁盘。
    public static let maxImageBytes = 20 * 1024 * 1024

    /// 常见浏览器、聊天软件、预览与截图工具写入的直接图片类型（按优先级排序）。
    private static let directImageTypes: [NSPasteboard.PasteboardType] = [
        .png,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.webP.identifier),
        NSPasteboard.PasteboardType(UTType.bmp.identifier),
    ]

    /// 从系统剪贴板提取受支持的内容（纯文本、链接或图片）。
    /// 调用前应先通过 `PasteboardFilter` 过滤敏感/临时内容。
    public static func extract(from pasteboard: NSPasteboard) -> CapturedPayload? {
        if PasteboardFilter.shouldIgnore(pasteboard: pasteboard) {
            return nil
        }

        let types = Set(pasteboard.types ?? [])
        let hasFileURL = types.contains(.fileURL)
        let hasTIFF = types.contains(.tiff)
        let hasRichText = types.contains(.rtf) || types.contains(.rtfd)

        // 1. 访达复制单个本地图片文件（如 PNG/JPG/HEIC/WebP/GIF/TIFF）时直接读取原图。
        if hasFileURL, let fileImage = extractImageFromFileURL(in: pasteboard) {
            return fileImage
        }

        // 2. 显式图片格式（PNG/JPEG/HEIC/GIF/WebP/BMP）且非访达普通文件复制，
        //    优先按图片记录（即使浏览器/微信同时附带图片 URL 或文件名文本）。
        if !hasFileURL, let directImage = extractDirectImage(from: pasteboard, includeTIFF: false) {
            return directImage
        }

        // 3. 仅有 TIFF 图片且不是富文本复制（排除 Word/Pages/Notes 富文本附带的渲染预览），
        //    同时覆盖浏览器/微信/预览/截图等写入 TIFF + 图片链接的场景。
        if !hasFileURL && hasTIFF && !hasRichText,
           let tiffImage = extractDirectImage(from: pasteboard, includeTIFF: true) {
            return tiffImage
        }

        // 4. 文本或链接。
        if let rawString = pasteboard.string(forType: .string),
           let textPayload = classifyText(rawString) {
            return textPayload
        }

        // 5. 仅存在 URL 类型时提取网页链接。
        if let urlString = pasteboard.string(forType: .URL),
           let linkPayload = classifyLink(urlString) {
            return linkPayload
        }

        // 6. 兜底提取可由 NSImage 读取的非文件图片（避免误将访达文件图标记作图片）。
        if !hasFileURL && !hasRichText,
           let fallbackImage = extractNSImageFallback(from: pasteboard) {
            return fallbackImage
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

    private static func extractDirectImage(from pasteboard: NSPasteboard, includeTIFF: Bool) -> CapturedPayload? {
        let candidates = includeTIFF ? (directImageTypes + [.tiff]) : directImageTypes
        for type in candidates {
            if let data = pasteboard.data(forType: type),
               let normalized = normalizeImageData(data) {
                return .image(pngData: normalized.pngData, width: normalized.width, height: normalized.height)
            }
        }
        return nil
    }

    private static func extractImageFromFileURL(in pasteboard: NSPasteboard) -> CapturedPayload? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              urls.count == 1,
              let fileURL = urls.first,
              fileURL.isFileURL else {
            return nil
        }

        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values?.isRegularFile == true else { return nil }
        if let fileSize = values?.fileSize, fileSize > maxImageBytes {
            return nil
        }

        let contentType = values?.contentType ?? UTType(filenameExtension: fileURL.pathExtension)
        guard let contentType, contentType.conforms(to: .image) else {
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL),
              data.count <= maxImageBytes,
              let normalized = normalizeImageData(data) else {
            return nil
        }
        return .image(pngData: normalized.pngData, width: normalized.width, height: normalized.height)
    }

    private static func extractNSImageFallback(from pasteboard: NSPasteboard) -> CapturedPayload? {
        guard pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
              let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              let image = images.first,
              let tiff = image.tiffRepresentation,
              let normalized = normalizeImageData(tiff) else {
            return nil
        }
        return .image(pngData: normalized.pngData, width: normalized.width, height: normalized.height)
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
