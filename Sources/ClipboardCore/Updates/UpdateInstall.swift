import CryptoKit
import Darwin
import Foundation
import Security

public struct UpdateBundle: Equatable, Sendable {
    public let version: ReleaseVersion
    public let minimumOS: ReleaseVersion
    public let team: String?
    public let certificate: String?

    public init(version: ReleaseVersion, minimumOS: ReleaseVersion, team: String?, certificate: String?) {
        self.version = version
        self.minimumOS = minimumOS
        self.team = team
        self.certificate = certificate
    }

    /// 仅当存在 Team ID 或固定证书指纹时才视为可验证发布者身份；ad-hoc 签名不具备发布者身份。
    public var hasVerifiablePublisher: Bool {
        if let team, !team.isEmpty { return true }
        if let certificate, !certificate.isEmpty { return true }
        return false
    }

    public static func inspect(_ app: URL) throws -> UpdateBundle {
        let fm = FileManager.default
        guard app.lastPathComponent == "Clipboard.app",
              let iterator = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) else {
            throw UpdateError("更新中没有正确的应用目录。", diagnosticCode: "bundle_invalid")
        }
        var total = 0
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else {
                throw UpdateError("更新应用含不支持的符号链接。", diagnosticCode: "bundle_symlink")
            }
            total += values.fileSize ?? 0
            guard total <= 512 * 1024 * 1024 else {
                throw UpdateError("更新应用内容超过大小限制。", diagnosticCode: "bundle_too_large")
            }
        }
        guard try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw UpdateError("应用根目录不能是符号链接。", diagnosticCode: "bundle_symlink")
        }

        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard (try infoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1024 * 1024 else {
            throw UpdateError("应用版本信息过大。", diagnosticCode: "info_plist_invalid")
        }
        let data = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "dev.clipboard.app",
              let executableName = info["CFBundleExecutable"] as? String,
              executableName == "Clipboard",
              let versionText = info["CFBundleShortVersionString"] as? String else {
            throw UpdateError("更新应用的 Bundle ID 或版本信息无效。", diagnosticCode: "bundle_id_mismatch")
        }
        let version = try ReleaseVersion(versionText)
        let minimum = info["LSMinimumSystemVersion"] as? String ?? "14.0"
        let minimumOS = try ReleaseVersion(minimum.split(separator: ".").count == 2 ? minimum + ".0" : minimum)

        _ = try UpdateCommand.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])

        #if arch(arm64)
        let expectedCPU: UInt32 = 0x0100000c
        #else
        let expectedCPU: UInt32 = 0x01000007
        #endif
        guard try supportsArchitecture(app.appendingPathComponent("Contents/MacOS/" + executableName), cpu: expectedCPU) else {
            throw UpdateError("更新应用不包含当前芯片架构。", diagnosticCode: "arch_mismatch")
        }

        var code: SecStaticCode?
        var signing: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess else {
            throw UpdateError("无法读取更新应用的签名身份。", diagnosticCode: "signature_unreadable")
        }
        let details = signing as? [String: Any]
        let team = details?[kSecCodeInfoTeamIdentifier as String] as? String
        let certificates = details?[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let certificate = certificates?.first.map {
            SHA256.hash(data: SecCertificateCopyData($0) as Data).map { String(format: "%02x", $0) }.joined()
        }
        return UpdateBundle(version: version, minimumOS: minimumOS, team: team, certificate: certificate)
    }

    public static func supportsArchitecture(_ executable: URL, cpu: UInt32) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        let data = [UInt8](try handle.read(upToCount: 4096) ?? Data())
        guard data.count >= 8 else { return false }
        func word(_ offset: Int, little: Bool) -> UInt32 {
            let bytes = Array(data[offset..<(offset + 4)])
            return little
                ? bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
                : bytes.reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let magic = word(0, little: false)
        if magic == 0xcffaedfe { return word(4, little: true) == cpu }
        if magic == 0xfeedfacf { return word(4, little: false) == cpu }
        let little = magic == 0xbebafeca || magic == 0xbfbafeca
        guard [0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca].contains(magic) else { return false }
        let count = Int(word(4, little: little))
        let stride = (magic == 0xcafebabf || magic == 0xbfbafeca) ? 32 : 20
        guard count > 0, count <= 64, 8 + count * stride <= data.count else { return false }
        return (0..<count).contains { word(8 + $0 * stride, little: little) == cpu }
    }

    /// 校验候选更新包与当前安装版本兼容且延续同一可验证发布者身份。
    /// 严禁将 ad-hoc 签名或 SHA-256 当作发布者身份验证。
    public func requireCompatible(
        expected: ReleaseVersion,
        currentTeam: String?,
        currentCertificate: String?
    ) throws {
        guard version == expected else {
            throw UpdateError("更新包内版本与 Release 标签不一致。", diagnosticCode: "version_mismatch")
        }

        let currentHasPublisher = (currentTeam?.isEmpty == false) || (currentCertificate?.isEmpty == false)
        guard currentHasPublisher && hasVerifiablePublisher else {
            throw UpdateError(
                "当前应用或更新包缺少可验证的发布者证书（ad-hoc 签名不支持应用内替换），请前往官方发布页手动下载。",
                diagnosticCode: "publisher_unverifiable"
            )
        }

        if let currentTeam, !currentTeam.isEmpty {
            guard team == currentTeam else {
                throw UpdateError("更新签名团队与当前应用不同，已拒绝替换。", diagnosticCode: "publisher_mismatch")
            }
        } else if let currentCertificate, !currentCertificate.isEmpty {
            guard certificate == currentCertificate else {
                throw UpdateError("更新证书与当前应用不同，已拒绝替换以保护签名身份和已有授权。", diagnosticCode: "publisher_mismatch")
            }
        }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let running = try ReleaseVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        guard minimumOS <= running else {
            throw UpdateError("新版本需要 macOS \(minimumOS) 或更新系统。", diagnosticCode: "os_too_old")
        }
    }
}

public enum UpdatePaths {
    public static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.clipboard.app/Updates", isDirectory: true)
    }

    public static var receipt: URL {
        cache.appendingPathComponent("last-result.json")
    }

    public static func isTranslocated(_ app: URL) -> Bool {
        let components = app.standardizedFileURL.pathComponents
        guard let marker = components.lastIndex(of: "AppTranslocation"),
              components.count == marker + 4,
              UUID(uuidString: components[marker + 1]) != nil else {
            return false
        }
        return components[marker + 2] == "d" && components[marker + 3] == "Clipboard.app"
    }

    public static func canInstall(at app: URL) -> Bool {
        let app = app.standardizedFileURL
        let parent = app.deletingLastPathComponent()
        let homeApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        return app.lastPathComponent == "Clipboard.app"
            && ["/Applications", homeApps.path].contains(parent.path)
            && app.resolvingSymlinksInPath().path == app.path
            && FileManager.default.isWritableFile(atPath: parent.path)
    }
}

public struct UpdateOutcome: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case installed
        case relaunchFailed
        case validationFailed
        case quitTimedOut
        case replacementFailed
    }

    public let status: Status
    public let version: ReleaseVersion?

    public init(status: Status, version: ReleaseVersion?) {
        self.status = status
        self.version = version
    }

    public var message: String {
        switch status {
        case .installed, .relaunchFailed:
            let installed = version.map { "已更新至 \($0)。" } ?? "已完成更新。"
            let backup = "旧版备份位于更新缓存的 Backups 目录。"
            return installed + backup + (status == .relaunchFailed ? " macOS 未能自动重新打开应用，请在访达中手动打开。" : "")
        case .validationFailed:
            return "上次更新未通过安装前校验，已保留原版。"
        case .quitTimedOut:
            return "上次更新未能等到 Clipboard 退出，已保留原版。"
        case .replacementFailed:
            return "上次更新未能替换应用，已保留原版。"
        }
    }

    public static func takeLatest() -> Self? {
        take(from: UpdatePaths.receipt)
    }

    public static func take(from url: URL) -> Self? {
        let fm = FileManager.default
        guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              info.isRegularFile == true,
              let size = info.fileSize,
              size < 4096,
              let data = try? Data(contentsOf: url),
              let outcome = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        try? fm.removeItem(at: url)
        return outcome
    }

    fileprivate func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: UpdatePaths.cache,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: UpdatePaths.receipt, options: .atomic)
    }
}

private struct UpdateJob: Codable {
    let pid: Int32
    let current: String
    let version: ReleaseVersion
}

public struct PreparedUpdate: Sendable {
    let root: URL
    public let version: ReleaseVersion

    public func clean() {
        try? FileManager.default.removeItem(at: root)
    }

    public func startHelper(current: URL) async throws -> Process {
        guard UpdatePaths.canInstall(at: current), let executable = Bundle.main.executableURL else {
            throw UpdateError("请从可写的「应用程序」目录运行正式版 Clipboard。", diagnosticCode: "install_path_unwritable")
        }
        let helper = root.appendingPathComponent("UpdateInstaller")
        let ready = root.appendingPathComponent("ready")
        try? FileManager.default.removeItem(at: helper)
        try? FileManager.default.removeItem(at: ready)
        try FileManager.default.copyItem(at: executable, to: helper)

        let job = UpdateJob(pid: ProcessInfo.processInfo.processIdentifier, current: current.path, version: version)
        let file = root.appendingPathComponent("update-job.json")
        try JSONEncoder().encode(job).write(to: file, options: .atomic)

        let process = Process()
        process.executableURL = helper
        process.arguments = ["--apply-update", file.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        do {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(30)
            while clock.now < deadline {
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: ready.path), process.isRunning {
                    return process
                }
                if !process.isRunning {
                    throw UpdateError("安装助手未就绪，已保留当前应用。", diagnosticCode: "helper_not_ready")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw UpdateError("安装助手未在规定时间内就绪，已保留当前应用。", diagnosticCode: "helper_timeout")
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }
}

public enum UpdateInstaller {
    /// 在目标同盘完成校验后原子交换目录；任意阶段失败均保留旧版在原路径不动。
    public static func swap(
        source: URL,
        destination: URL,
        backupDirectory: URL,
        validate: (URL) throws -> Void
    ) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".clipboard-update-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }

        let stagedApp = staging.appendingPathComponent("Clipboard.app")
        _ = try UpdateCommand.run("/usr/bin/ditto", [source.path, stagedApp.path])
        try validate(stagedApp)

        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = backupDirectory.appendingPathComponent("Clipboard-\(UUID().uuidString).zip")
        do {
            _ = try UpdateCommand.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", destination.path, backup.path])
        } catch {
            try? fm.removeItem(at: backup)
            throw error
        }

        guard renameatx_np(AT_FDCWD, stagedApp.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateError("无法在此磁盘替换应用，已保留原版（\(errno)）。", diagnosticCode: "swap_failed")
        }
    }

    public static func runHelper(jobPath: String) -> Int32 {
        let fm = FileManager.default
        let file = URL(fileURLWithPath: jobPath).standardizedFileURL
        let root = file.deletingLastPathComponent()
        guard file.lastPathComponent == "update-job.json",
              root.deletingLastPathComponent().path == UpdatePaths.cache.standardizedFileURL.path,
              root.lastPathComponent.hasPrefix("pending-"),
              root.resolvingSymlinksInPath().path == root.path,
              file.resolvingSymlinksInPath().path == file.path else {
            return 1
        }

        let source = root.appendingPathComponent("extracted/Clipboard.app")
        var exited = false
        var destination: URL?
        var failure: UpdateOutcome.Status = .validationFailed
        do {
            guard try (file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 8192 else {
                throw UpdateError("更新任务无效。")
            }
            let job = try JSONDecoder().decode(UpdateJob.self, from: Data(contentsOf: file))
            let installed = URL(fileURLWithPath: job.current)
            guard job.pid == getppid(),
                  job.pid > 1,
                  UpdatePaths.canInstall(at: installed),
                  source.resolvingSymlinksInPath().path == source.path else {
                throw UpdateError("更新任务路径无效。")
            }
            destination = installed

            let lock = open(UpdatePaths.cache.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { throw UpdateError("无法锁定更新目录。") }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw UpdateError("另一个更新正在安装。") }

            let current = try UpdateBundle.inspect(installed)
            guard current.version < job.version else { throw UpdateError("当前应用版本已改变。") }

            func verify(_ app: URL) throws {
                try UpdateBundle.inspect(app).requireCompatible(
                    expected: job.version,
                    currentTeam: current.team,
                    currentCertificate: current.certificate
                )
            }

            try verify(source)
            try "ready".write(to: root.appendingPathComponent("ready"), atomically: true, encoding: .utf8)

            let deadline = ProcessInfo.processInfo.systemUptime + 45
            while getppid() == job.pid && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            failure = .quitTimedOut
            guard getppid() != job.pid else { throw UpdateError("Clipboard 尚未退出，安装已取消。") }
            exited = true

            failure = .replacementFailed
            let installedNow = try UpdateBundle.inspect(installed)
            guard installedNow.version == current.version,
                  installedNow.certificate == current.certificate,
                  installedNow.team == current.team else {
                throw UpdateError("原应用在等待期间发生变化。")
            }

            try swap(
                source: source,
                destination: installed,
                backupDirectory: UpdatePaths.cache.appendingPathComponent("Backups"),
                validate: verify
            )
            UpdateOutcome(status: .installed, version: job.version).save()
            do {
                _ = try UpdateCommand.run("/usr/bin/open", [installed.path])
            } catch {
                UpdateOutcome(status: .relaunchFailed, version: job.version).save()
            }
            try? fm.removeItem(at: root)
            return 0
        } catch {
            UpdateOutcome(status: failure, version: nil).save()
            if exited, let destination {
                _ = try? UpdateCommand.run("/usr/bin/open", [destination.path])
            }
            try? fm.removeItem(at: root)
            return 1
        }
    }
}
