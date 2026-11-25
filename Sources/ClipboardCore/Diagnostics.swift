import Foundation
import os

/// 元数据级诊断日志：严禁记录剪贴板原文、链接、标题、图片数据或凭据。
public enum ClipboardLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dev.clipboard.app"
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let monitor = Logger(subsystem: subsystem, category: "monitor")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
