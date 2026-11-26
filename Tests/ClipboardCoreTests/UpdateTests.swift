import ClipboardCore
import Foundation
import Testing

@Suite("ClipboardCore 应用内更新测试")
struct UpdateTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-update-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRelease(
        tag: String = "v0.2.0",
        draft: Bool = false,
        prerelease: Bool = false,
        arch: String = AppRelease.architecture,
        zipURL: String? = nil,
        digest: String? = nil
    ) -> AppRelease {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let zipName = "Clipboard-\(version)-macos-\(arch).zip"
        let officialZip = zipURL ?? "https://github.com/kirktools/clipboard/releases/download/\(tag)/\(zipName)"
        let officialSums = "https://github.com/kirktools/clipboard/releases/download/\(tag)/SHA256SUMS"
        return AppRelease(
            tag_name: tag,
            draft: draft,
            prerelease: prerelease,
            assets: [
                ReleaseAsset(id: 1, name: zipName, size: 1024, browser_download_url: URL(string: officialZip)!, digest: digest),
                ReleaseAsset(id: 2, name: "SHA256SUMS", size: 256, browser_download_url: URL(string: officialSums)!),
            ]
        )
    }

    @Test("发现新正式版并拒绝草稿、预发布、非官方地址与旧版本")
    func updateDiscoveryRules() throws {
        let current = try ReleaseVersion("0.1.3")

        let newer = makeRelease(tag: "v0.2.0")
        let pkg = try newer.package(current: current)
        #expect(pkg?.version == (try ReleaseVersion("0.2.0")))
        #expect(pkg?.archive.name == "Clipboard-0.2.0-macos-\(AppRelease.architecture).zip")

        // 同版本或旧版本返回 nil
        #expect(try makeRelease(tag: "v0.1.3").package(current: current) == nil)
        #expect(try makeRelease(tag: "v0.1.2").package(current: current) == nil)

        // 草稿与预发布被拒绝
        #expect(throws: UpdateError.self) {
            _ = try makeRelease(tag: "v0.2.0", draft: true).package(current: current)
        }
        #expect(throws: UpdateError.self) {
            _ = try makeRelease(tag: "v0.2.0", prerelease: true).package(current: current)
        }

        // 非官方下载地址被拒绝
        #expect(throws: UpdateError.self) {
            _ = try makeRelease(
                tag: "v0.2.0",
                zipURL: "https://evil.example.com/Clipboard-0.2.0-macos-\(AppRelease.architecture).zip"
            ).package(current: current)
        }
    }

    @Test("SHA256SUMS 校验失败与 digest 不一致时拒绝更新")
    func checksumValidationFailures() throws {
        let validHash = String(repeating: "a", count: 64)
        let otherHash = String(repeating: "b", count: 64)
        let release = makeRelease(tag: "v0.2.0", digest: "sha256:\(validHash)")
        let pkg = try release.package(current: try ReleaseVersion("0.1.3"))!

        let okSums = "\(validHash)  \(pkg.archive.name)\n"
        #expect(try pkg.expectedHash(okSums) == validHash)

        // 缺少对应文件条目
        #expect(throws: UpdateError.self) {
            _ = try pkg.expectedHash("\(validHash)  Other-0.2.0.zip\n")
        }

        // SHA256SUMS 与 Release asset digest 不一致
        #expect(throws: UpdateError.self) {
            _ = try pkg.expectedHash("\(otherHash)  \(pkg.archive.name)\n")
        }
    }

    @Test("发布者身份校验：拒绝 ad-hoc 与证书/团队不符，允许延续同证书")
    func publisherIdentityVerification() throws {
        let expected = try ReleaseVersion("0.2.0")
        let minOS = try ReleaseVersion("14.0.0")
        let certA = String(repeating: "1", count: 64)
        let certB = String(repeating: "2", count: 64)

        // 1. ad-hoc（无 Team 且无证书）必须被拒绝，不能把 SHA-256 或 ad-hoc 当发布者身份
        let adhocCandidate = UpdateBundle(version: expected, minimumOS: minOS, team: nil, certificate: nil)
        #expect(!adhocCandidate.hasVerifiablePublisher)
        #expect(throws: UpdateError.self) {
            try adhocCandidate.requireCompatible(expected: expected, currentTeam: nil, currentCertificate: nil)
        }
        #expect(throws: UpdateError.self) {
            try adhocCandidate.requireCompatible(expected: expected, currentTeam: nil, currentCertificate: certA)
        }

        // 2. 当前为 ad-hoc 时，即使候选有证书也不能自动替换
        let signedA = UpdateBundle(version: expected, minimumOS: minOS, team: nil, certificate: certA)
        #expect(signedA.hasVerifiablePublisher)
        #expect(throws: UpdateError.self) {
            try signedA.requireCompatible(expected: expected, currentTeam: nil, currentCertificate: nil)
        }

        // 3. 证书不符被拒绝
        let signedB = UpdateBundle(version: expected, minimumOS: minOS, team: nil, certificate: certB)
        #expect(throws: UpdateError.self) {
            try signedB.requireCompatible(expected: expected, currentTeam: nil, currentCertificate: certA)
        }

        // 4. 同固定自签名证书通过
        try signedA.requireCompatible(expected: expected, currentTeam: nil, currentCertificate: certA)

        // 5. 版本不一致被拒绝
        let wrongVersion = UpdateBundle(version: try ReleaseVersion("0.2.1"), minimumOS: minOS, team: nil, certificate: certA)
        #expect(throws: UpdateError.self) {
            try wrongVersion.requireCompatible(expected: expected, currentTeam: nil, currentCertificate: certA)
        }

        // 6. 团队不一致被拒绝
        let teamA = UpdateBundle(version: expected, minimumOS: minOS, team: "TEAMAAAAAA", certificate: certA)
        let teamB = UpdateBundle(version: expected, minimumOS: minOS, team: "TEAMBBBBBB", certificate: certB)
        try teamA.requireCompatible(expected: expected, currentTeam: "TEAMAAAAAA", currentCertificate: certA)
        #expect(throws: UpdateError.self) {
            try teamB.requireCompatible(expected: expected, currentTeam: "TEAMAAAAAA", currentCertificate: certA)
        }
    }

    @Test("原子替换成功时保留备份，校验失败时完整保留旧版不损坏")
    func atomicSwapAndRollbackPreservesPreviousApp() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldApp = dir.appendingPathComponent("Clipboard.app")
        let newSource = dir.appendingPathComponent("incoming/Clipboard.app")
        let backups = dir.appendingPathComponent("Backups")

        try FileManager.default.createDirectory(at: oldApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "OLD_VERSION_0_1_3".write(to: oldApp.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: newSource.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "NEW_VERSION_0_2_0".write(to: newSource.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)

        // 1. 校验失败时，原应用目录必须完整保留
        #expect(throws: UpdateError.self) {
            try UpdateInstaller.swap(source: newSource, destination: oldApp, backupDirectory: backups) { _ in
                throw UpdateError("模拟验签失败", diagnosticCode: "publisher_mismatch")
            }
        }
        let stillOld = try String(contentsOf: oldApp.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
        #expect(stillOld == "OLD_VERSION_0_1_3")

        // 2. 校验通过时，原子替换为新版并生成旧版 ZIP 备份
        try UpdateInstaller.swap(source: newSource, destination: oldApp, backupDirectory: backups) { _ in }
        let nowNew = try String(contentsOf: oldApp.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
        #expect(nowNew == "NEW_VERSION_0_2_0")
        let backupFiles = try FileManager.default.contentsOfDirectory(atPath: backups.path).filter { $0.hasSuffix(".zip") }
        #expect(backupFiles.count == 1)
    }

    @Test("安装路径与 AppTranslocation 检测")
    func installPathAndTranslocationDetection() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/aa/bb/T/AppTranslocation/\(UUID().uuidString)/d/Clipboard.app")
        #expect(UpdatePaths.isTranslocated(translocated))
        #expect(!UpdatePaths.canInstall(at: translocated))
        #expect(!UpdatePaths.canInstall(at: URL(fileURLWithPath: "/tmp/Clipboard.app")))
        #expect(!UpdatePaths.canInstall(at: URL(fileURLWithPath: "/Applications/Clipboard Dev.app")))
    }
}
