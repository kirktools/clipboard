import Foundation

/// 展示层隐私脱敏辅助：自动推断常见密钥、令牌、高熵随机串、私钥与含密码连接串，
/// 采用「掐头去尾隐藏中间」的方式保留可辨识性，同时防止完整凭据暴露在屏幕上。
/// 仅影响界面展示，不改动剪贴板原始内容；无法保证识别所有密码或私密文本。
public enum SensitivePreview {
    private static let structuredSecretPatterns: [NSRegularExpression] = [
        // 常见服务商 API Key / Token 前缀
        try! NSRegularExpression(
            pattern: #"(?:^|[\s"'=:])(sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{16,}|(?:AKIA|ASIA)[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{20,}|ya29\.[0-9A-Za-z_-]{20,}|hf_[A-Za-z0-9]{20,}|npm_[A-Za-z0-9]{20,}|pypi-[A-Za-z0-9_-]{20,})"#
        ),
        // JWT
        try! NSRegularExpression(
            pattern: #"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#
        ),
        // Authorization: Bearer / Basic
        try! NSRegularExpression(
            pattern: #"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]{16,}"#
        ),
        // PEM 私钥块
        try! NSRegularExpression(
            pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"#
        ),
    ]

    private static let keyValueSecretRegex = try! NSRegularExpression(
        pattern: #"(?i)(\b[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|AUTH_?TOKEN|CLIENT_?SECRET)\s*[:=]\s*["']?)([^\s"'`]{6,})(["']?)"#
    )

    private static let credentialURLRegex = try! NSRegularExpression(
        pattern: #"([a-zA-Z][a-zA-Z0-9+.-]*://[^/\s:@]+:)([^/\s@]{3,})(@)"#
    )

    private static let pureHexRegex = try! NSRegularExpression(
        pattern: #"^[0-9a-fA-F]{32,}$"#
    )

    public static func looksSensitive(_ item: ClipboardItem) -> Bool {
        switch item.kind {
        case .image:
            return false
        case .text, .link:
            guard let raw = item.text ?? item.urlString, !raw.isEmpty else { return false }
            return looksSensitive(text: raw)
        }
    }

    public static func looksSensitive(text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if structuredSecretPatterns.contains(where: { $0.firstMatch(in: text, options: [], range: range) != nil }) {
            return true
        }
        if keyValueSecretRegex.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if credentialURLRegex.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        return looksLikeHighEntropySecretToken(text)
    }

    /// 自动推断无空格的长高熵随机字符串（如自定义 API Key、Webhook Secret、32+ 位十六进制密钥等）。
    private static func looksLikeHighEntropySecretToken(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 24,
              !trimmed.contains(where: \.isWhitespace),
              !trimmed.hasPrefix("http://"),
              !trimmed.hasPrefix("https://"),
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~/"),
              trimmed.allSatisfy({ $0.isASCII }) else {
            return false
        }

        // 排除标准 UUID（如 550e8400-e29b-41d4-a716-446655440000）
        if UUID(uuidString: trimmed) != nil {
            return false
        }

        // 32 位以上纯十六进制串（常见哈希密钥 / Secret Key）
        let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if pureHexRegex.firstMatch(in: trimmed, options: [], range: nsRange) != nil {
            return true
        }

        // 至少包含两类字符（如字母+数字，或大小写混合+符号）且香农熵足够高
        let hasLower = trimmed.contains { $0.isLowercase }
        let hasUpper = trimmed.contains { $0.isUppercase }
        let hasDigit = trimmed.contains { $0.isNumber }
        let hasSymbol = trimmed.contains { !$0.isLetter && !$0.isNumber }
        let classCount = [hasLower, hasUpper, hasDigit, hasSymbol].filter { $0 }.count
        guard classCount >= 2 else { return false }

        return shannonEntropy(trimmed) >= 3.6
    }

    private static func shannonEntropy(_ string: String) -> Double {
        guard !string.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for ch in string { counts[ch, default: 0] += 1 }
        let total = Double(string.count)
        return counts.values.reduce(0.0) { partial, count in
            let p = Double(count) / total
            return partial - p * log2(p)
        }
    }

    /// 掐头去尾、隐藏中间，保留足够辨识度。
    public static func maskMiddle(_ value: String, keepPrefix: Int = 4, keepSuffix: Int = 4) -> String {
        let chars = Array(value)
        if chars.count <= 8 {
            return "••••••"
        }
        let headCount = min(keepPrefix, max(2, chars.count / 4))
        let tailCount = min(keepSuffix, max(2, chars.count / 4))
        if headCount + tailCount >= chars.count {
            return String(chars.prefix(2)) + "••••••" + String(chars.suffix(2))
        }
        let head = String(chars.prefix(headCount))
        let tail = String(chars.suffix(tailCount))
        return "\(head)••••••\(tail)"
    }

    /// 针对疑似敏感文本生成掐头去尾的脱敏预览。
    public static func redactSensitivePreview(_ raw: String) -> String {
        let singleLine = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. PEM 私钥：仅保留头标识
        if let startRange = singleLine.range(of: "-----BEGIN "),
           let endRange = singleLine.range(of: "PRIVATE KEY-----", range: startRange.upperBound..<singleLine.endIndex) {
            return "\(singleLine[startRange.lowerBound..<endRange.upperBound]) ••••••"
        }

        // 2. 含密码连接串：仅打码密码段
        let nsRange = NSRange(singleLine.startIndex..<singleLine.endIndex, in: singleLine)
        if credentialURLRegex.firstMatch(in: singleLine, options: [], range: nsRange) != nil {
            return credentialURLRegex.stringByReplacingMatches(
                in: singleLine,
                options: [],
                range: nsRange,
                withTemplate: "$1••••••$3"
            )
        }

        // 3. KEY=SECRET 赋值：保留键名，对值掐头去尾
        if let match = keyValueSecretRegex.firstMatch(in: singleLine, options: [], range: nsRange),
           let prefixRange = Range(match.range(at: 1), in: singleLine),
           let secretRange = Range(match.range(at: 2), in: singleLine),
           let suffixRange = Range(match.range(at: 3), in: singleLine) {
            let maskedValue = maskMiddle(String(singleLine[secretRange]), keepPrefix: 3, keepSuffix: 3)
            return "\(singleLine[prefixRange])\(maskedValue)\(singleLine[suffixRange])"
        }

        // 4. Bearer / Basic Token：保留方案名，对令牌掐头去尾
        let parts = singleLine.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        if parts.count == 2, ["bearer", "basic"].contains(parts[0].lowercased()) {
            return "\(parts[0]) \(maskMiddle(String(parts[1]), keepPrefix: 4, keepSuffix: 4))"
        }

        // 5. 其他长串密钥（sk-xxx、ghp_xxx、JWT、高熵随机串）：掐头去尾
        let keepHead = singleLine.hasPrefix("github_pat_") ? 11
            : (singleLine.hasPrefix("sk-") || singleLine.hasPrefix("ghp_") || singleLine.hasPrefix("gho_") ? 6 : 4)
        return maskMiddle(singleLine, keepPrefix: keepHead, keepSuffix: 4)
    }

    /// 返回主展示文本（已根据自动敏感推断与隐私模式做掐头去尾脱敏）。
    public static func maskedPrimaryText(
        for item: ClipboardItem,
        privacyMode: Bool,
        isRevealed: Bool
    ) -> String {
        if isRevealed {
            return item.primaryDisplayText
        }
        if let customTitle = item.normalizedCustomTitle {
            return customTitle
        }
        let sensitive = looksSensitive(item)
        guard privacyMode || sensitive else {
            return item.primaryDisplayText
        }

        if sensitive, let raw = item.text ?? item.urlString {
            return redactSensitivePreview(raw)
        }

        switch item.kind {
        case .text:
            return maskMiddle(item.primaryDisplayText, keepPrefix: 4, keepSuffix: 3)
        case .link:
            if let urlString = item.urlString,
               let url = URL(string: urlString),
               let scheme = url.scheme,
               let host = url.host,
               !host.isEmpty {
                return "\(scheme)://\(host)/••••••"
            }
            return maskMiddle(item.primaryDisplayText, keepPrefix: 8, keepSuffix: 4)
        case .image:
            if let w = item.imageWidth, let h = item.imageHeight {
                return "已遮罩图片（\(w) × \(h)）"
            }
            return "已遮罩图片"
        }
    }

    public static func maskedSecondaryText(
        for item: ClipboardItem,
        privacyMode: Bool,
        isRevealed: Bool
    ) -> String? {
        if isRevealed {
            return item.secondaryDisplayText
        }
        let sensitive = looksSensitive(item)
        guard privacyMode || sensitive else {
            return item.secondaryDisplayText
        }
        if item.kind == .image {
            return "隐私模式已遮罩 · 按 ⌘E 临时查看"
        }
        return sensitive ? "已自动隐藏中间字符 · 按 ⌘E 查看完整内容" : "隐私模式已缩略 · 按 ⌘E 查看完整内容"
    }

    public static func shouldMaskImage(privacyMode: Bool, isRevealed: Bool) -> Bool {
        privacyMode && !isRevealed
    }
}
