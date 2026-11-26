import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("site/assets", isDirectory: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func renderBitmap(width: Int, height: Int, draw: (CGSize) -> Void) -> Data {
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
    draw(CGSize(width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func drawClipboardIcon(in rect: NSRect) {
    let s = min(rect.width, rect.height)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.23, yRadius: s * 0.23)
    NSColor(calibratedRed: 0.09, green: 0.21, blue: 0.37, alpha: 1.0).setFill()
    bg.fill()

    let boardW = s * 0.48
    let boardH = s * 0.56
    let boardRect = NSRect(
        x: rect.midX - boardW / 2,
        y: rect.midY - boardH / 2 - s * 0.03,
        width: boardW,
        height: boardH
    )
    let board = NSBezierPath(roundedRect: boardRect, xRadius: s * 0.07, yRadius: s * 0.07)
    board.lineWidth = max(1.5, s * 0.06)
    NSColor.white.setStroke()
    board.stroke()

    let clipW = boardW * 0.48
    let clipH = boardH * 0.22
    let clipRect = NSRect(
        x: rect.midX - clipW / 2,
        y: boardRect.maxY - clipH * 0.45,
        width: clipW,
        height: clipH
    )
    let clip = NSBezierPath(roundedRect: clipRect, xRadius: s * 0.04, yRadius: s * 0.04)
    NSColor(calibratedRed: 0.09, green: 0.21, blue: 0.37, alpha: 1.0).setFill()
    clip.fill()
    clip.lineWidth = max(1.5, s * 0.06)
    NSColor(calibratedRed: 0.37, green: 0.92, blue: 0.83, alpha: 1.0).setStroke()
    clip.stroke()

    let lineH = max(1.5, s * 0.055)
    NSColor.white.setFill()
    for (idx, ratio) in [0.58, 0.44, 0.32].enumerated() {
        let y = boardRect.maxY - boardRect.height * (0.36 + CGFloat(idx) * 0.21)
        let r = NSRect(
            x: boardRect.minX + boardRect.width * 0.20,
            y: y,
            width: boardRect.width * CGFloat(ratio),
            height: lineH
        )
        NSBezierPath(roundedRect: r, xRadius: lineH / 2, yRadius: lineH / 2).fill()
    }
}

try renderBitmap(width: 32, height: 32) { size in
    drawClipboardIcon(in: NSRect(origin: .zero, size: size))
}.write(to: assets.appendingPathComponent("favicon-32.png"))

try renderBitmap(width: 180, height: 180) { size in
    drawClipboardIcon(in: NSRect(origin: .zero, size: size))
}.write(to: assets.appendingPathComponent("apple-touch-icon.png"))

try renderBitmap(width: 1200, height: 630) { size in
    let bg = NSGradient(
        starting: NSColor(calibratedRed: 0.07, green: 0.14, blue: 0.24, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.15, alpha: 1.0)
    )!
    bg.draw(in: NSRect(origin: .zero, size: size), angle: -35)

    drawClipboardIcon(in: NSRect(x: 96, y: 215, width: 200, height: 200))

    let title = "Clipboard" as NSString
    title.draw(at: NSPoint(x: 344, y: 332), withAttributes: [
        .font: NSFont.systemFont(ofSize: 74, weight: .bold),
        .foregroundColor: NSColor.white,
    ])

    let subtitle = "原生 macOS 菜单栏剪贴板历史与长期收藏工具" as NSString
    subtitle.draw(at: NSPoint(x: 348, y: 266), withAttributes: [
        .font: NSFont.systemFont(ofSize: 30, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1.0),
    ])

    let detail = "纯文本 · 链接 · 图片 · 本地存储 · 键盘优先" as NSString
    detail.draw(at: NSPoint(x: 348, y: 214), withAttributes: [
        .font: NSFont.systemFont(ofSize: 22, weight: .regular),
        .foregroundColor: NSColor(calibratedRed: 0.37, green: 0.92, blue: 0.83, alpha: 1.0),
    ])
}.write(to: assets.appendingPathComponent("social-card.png"))

print("已生成官网图标与分享卡片：site/assets/")
