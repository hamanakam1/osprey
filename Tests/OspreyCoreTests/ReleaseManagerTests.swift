import Foundation
import Testing
@testable import OspreyCore

@Suite("Release manager")
final class ReleaseManagerTests {
    private var scratch: URL!
    private var backups: URL!
    private var installed: URL!

    init() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("osprey-release-\(UUID().uuidString)", isDirectory: true)
        backups = scratch.appendingPathComponent("backups", isDirectory: true)
        installed = scratch.appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Taskrivet.app", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Builds a synthetic application bundle. No real application is involved.
    private func makeBundle(at url: URL, version: String = "9.9.9", withCore: Bool = true) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let executable = url.appendingPathComponent("Contents/MacOS/Taskrivet")
        try Data("#!/bin/sh\necho synthetic\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if withCore {
            try fileManager.createDirectory(
                at: url.appendingPathComponent("Contents/Resources/core/taskrivet"),
                withIntermediateDirectories: true
            )
            try Data("".utf8).write(to: url.appendingPathComponent("Contents/Resources/core/taskrivet/__init__.py"))
        }
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.taskrivet.desktop",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1",
            "CFBundleExecutable": "Taskrivet",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    private func manager() -> ReleaseManager {
        ReleaseManager(backupRoot: backups, installedPath: installed)
    }

    @Test("verification reads a synthetic bundle")
    func verifyReadsASyntheticBundle() throws {
        let bundle = scratch.appendingPathComponent("Taskrivet.app", isDirectory: true)
        try makeBundle(at: bundle, version: "9.9.9")
        let report = try manager().verify(bundle: bundle)
        #expect(report.identifier == "org.taskrivet.desktop")
        #expect(report.version == "9.9.9")
        #expect(report.executablePresent)
        #expect(report.corePresent)
        #expect(report.isUsable)
    }

    @Test("verification reports a missing core")
    func verifyReportsAMissingCore() throws {
        let bundle = scratch.appendingPathComponent("Broken.app", isDirectory: true)
        try makeBundle(at: bundle, withCore: false)
        let report = try manager().verify(bundle: bundle)
        #expect(!report.isUsable)
        #expect(report.problems.contains { $0.contains("Python core") })
    }

    @Test("verification rejects something that is not an application")
    func verifyRejectsSomethingThatIsNotAnApplication() throws {
        let plain = scratch.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: plain)
        #expect(throws: (any Error).self) { try manager().verify(bundle: plain) }
    }

    @Test("installing keeps a backup of the previous build")
    func installBacksUpThePreviousBuild() throws {
        let bundle = scratch.appendingPathComponent("Taskrivet.app", isDirectory: true)
        try makeBundle(at: bundle, version: "1.0.0")
        try makeBundle(at: installed, version: "0.9.0")

        let outcome = try manager().install(bundle: bundle, runSmokeTest: false)
        #expect(FileManager.default.fileExists(atPath: installed.path))
        #expect(outcome.backupPath != nil)
        #expect(FileManager.default.fileExists(atPath: outcome.backupPath!))
        #expect(try manager().verify(bundle: installed).version == "1.0.0")
    }

    @Test("rollback restores the previous build")
    func rollbackRestoresThePreviousBuild() throws {
        let bundle = scratch.appendingPathComponent("Taskrivet.app", isDirectory: true)
        try makeBundle(at: bundle, version: "1.0.0")
        try makeBundle(at: installed, version: "0.9.0")
        let release = manager()
        _ = try release.install(bundle: bundle, runSmokeTest: false)
        let outcome = try release.rollback()
        #expect(outcome.rolledBack)
        #expect(try release.verify(bundle: installed).version == "0.9.0")
    }

    @Test("rollback without a backup fails")
    func rollbackWithoutABackupFails() {
        #expect(throws: (any Error).self) { try manager().rollback() }
    }

    @Test("the smoke test fails on a bundle without a working core")
    func smokeTestFailsOnABundleWithoutAWorkingCore() throws {
        let bundle = scratch.appendingPathComponent("Taskrivet.app", isDirectory: true)
        try makeBundle(at: bundle, withCore: false)
        let result = try manager().smokeTest(bundle: bundle)
        #expect(!result.passed)
    }

    @Test("backups are listed newest first")
    func backupsAreListedNewestFirst() throws {
        let bundle = scratch.appendingPathComponent("Taskrivet.app", isDirectory: true)
        try makeBundle(at: bundle, version: "1.0.0")
        try makeBundle(at: installed, version: "0.9.0")
        let release = manager()
        _ = try release.install(bundle: bundle, runSmokeTest: false)
        _ = try release.install(bundle: bundle, runSmokeTest: false)
        let list = release.listBackups()
        #expect(list.count == 2)
        #expect((list.first?.path ?? "") > (list.last?.path ?? ""))
    }
}
