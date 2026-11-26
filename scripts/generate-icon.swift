import AppKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("用法：generate-icon <iconset目录> <dev|release> <输出.icns>\n", stderr)
    exit(2)
}

let iconsetDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let mode = CommandLine.arguments[2]
let outputICNS = URL(fileURLWithPath: CommandLine.arguments[3])

let fm = FileManager.default
try? fm.removeItem(at: iconsetDir)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func renderIcon(size: Int, isDev: Bool) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = rect.width * 0.225
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    let topColor = isDev
        ? NSColor(calibratedRed: 0.24, green: 0.34, blue: 0.44, alpha: 1.0)
        : NSColor(calibratedRed: 0.14, green: 0.44, blue: 0.92, alpha: 1.0)
    let bottomColor = isDev
        ? NSColor(calibratedRed: 0.14, green: 0.20, blue: 0.28, alpha: 1.0)
        : NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.72, alpha: 1.0)

    let gradient = NSGradient(starting: topColor, ending: bottomColor)!
    gradient.draw(in: bgPath, angle: -90)

    // 剪贴板纸张外框
    let boardWidth = rect.width * 0.54
    let boardHeight = rect.height * 0.62
    let boardRect = NSRect(
        x: rect.midX - boardWidth / 2,
        y: rect.midY - boardHeight / 2 - rect.height * 0.03,
        width: boardWidth,
        height: boardHeight
    )
    let boardPath = NSBezierPath(roundedRect: boardRect, xRadius: s * 0.06, yRadius: s * 0.06)
    NSColor.white.withAlphaComponent(0.95).setFill()
    boardPath.fill()

    // 顶部夹子
    let clipWidth = boardWidth * 0.48
    let clipHeight = boardHeight * 0.18
    let clipRect = NSRect(
        x: rect.midX - clipWidth / 2,
        y: boardRect.maxY - clipHeight * 0.45,
        width: clipWidth,
        height: clipHeight
    )
    let clipPath = NSBezierPath(roundedRect: clipRect, xRadius: clipHeight * 0.35, yRadius: clipHeight * 0.35)
    NSColor(calibratedWhite: 0.88, alpha: 1.0).setFill()
    clipPath.fill()

    // 纸面文本线条
    let lineColor = bottomColor.withAlphaComponent(0.35)
    lineColor.setFill()
    let lineMarginX = boardRect.width * 0.16
    let lineHeight = max(1, s * 0.036)
    for (idx, ratio) in [0.68, 0.52, 0.60].enumerated() {
        let y = boardRect.maxY - boardRect.height * (0.34 + CGFloat(idx) * 0.19)
        let lineRect = NSRect(
            x: boardRect.minX + lineMarginX,
            y: y,
            width: (boardRect.width - lineMarginX * 2) * CGFloat(ratio) / 0.68,
            height: lineHeight
        )
        NSBezierPath(roundedRect: lineRect, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
    }

    // 开发版在右下角叠加醒目的橙色 DEV 角标，便于与正式版区分。
    if isDev {
        let badgeWidth = rect.width * 0.58
        let badgeHeight = rect.height * 0.28
        let badgeRect = NSRect(
            x: rect.maxX - badgeWidth - rect.width * 0.04,
            y: rect.minY + rect.height * 0.04,
            width: badgeWidth,
            height: badgeHeight
        )
        NSColor.systemOrange.setFill()
        NSBezierPath(
            roundedRect: badgeRect,
            xRadius: badgeHeight * 0.28,
            yRadius: badgeHeight * 0.28
        ).fill()

        let text = "DEV" as NSString
        let font = NSFont.systemFont(ofSize: badgeHeight * 0.72, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let textSize = text.size(withAttributes: attrs)
        let textOrigin = NSPoint(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2 - badgeHeight * 0.02
        )
        text.draw(at: textOrigin, withAttributes: attrs)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let isDev = (mode == "dev")
for (name, px) in sizes {
    let data = renderIcon(size: px, isDev: isDev)
    try data.write(to: iconsetDir.appendingPathComponent(name))
}

// 直接拼接标准 ICNS PNG 块，不依赖 iconutil 服务，可在受限环境稳定构建。
func bigEndian(_ value: Int) -> Data {
    var number = UInt32(value).bigEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}

var chunks = Data()
for (type, name) in [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
] {
    let png = try Data(contentsOf: iconsetDir.appendingPathComponent(name))
    chunks.append(Data(type.utf8))
    chunks.append(bigEndian(png.count + 8))
    chunks.append(png)
}

var family = Data("icns".utf8)
family.append(bigEndian(chunks.count + 8))
family.append(chunks)
try family.write(to: outputICNS)
