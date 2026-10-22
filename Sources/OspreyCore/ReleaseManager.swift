import Foundation

/// Verifies, installs, and rolls back the Taskrivet desktop build on this Mac.
///
/// The rule is the same one the rest of Osprey follows: prepare, check, then
/// act, and be able to undo. A failed install restores the previous build
/// instead of leaving a broken application behind.
public final class ReleaseManager {
    public struct BundleReport: Sendable, Equatable {
        public let path: String
        public let identifier: String
        public let version: String
        public let build: String
        public let executablePresent: Bool
        public let corePresent: Bool
        public let problems: [String]

        public var isUsable: Bool { problems.isEmpty }
    }

    public struct InstallOutcome: Sendable {
        public let installedPath: String
        public let backupPath: String?
        public let smokeTestPassed: Bool
        public let rolledBack: Bool
        public let detail: String
    }

    public enum ReleaseError: Error, CustomStringConvertible, Sendable {
        case notAnApplication(String)
        case unusableBundle([String])
        case installFailed(String)
        case nothingToRollBack(String)

        public var description: String {
            switch self {
            case .notAnApplication(let message): return message
            case .unusableBundle(let problems): return "The bundle is not usable: " + problems.joined(separator: "; ")
            case .installFailed(let message): return message
            case .nothingToRollBack(let message): return message
            }
        }
    }

    private let fileManager: FileManager
    public let backupRoot: URL
    public let installedPath: URL
    private let python: String?

    public init(
        fileManager: FileManager = .default,
        backupRoot: URL? = nil,
        installedPath: URL? = nil,
        python: String? = nil
    ) {
        self.fileManager = fileManager
        self.backupRoot = backupRoot ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".taskrivet", isDirectory: true)
            .appendingPathComponent("app-backups", isDirectory: true)
        self.installedPath = installedPath ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Taskrivet.app", isDirectory: true)
        self.python = python ?? LedgerClient.findPython(fileManager: fileManager)
    }

    // MARK: - Verification

    /// Reads a built application bundle and reports what is inside it.
    public func verify(bundle: URL) throws -> BundleReport {
        var problems: [String] = []
        let infoPlist = bundle.appendingPathComponent("Contents/Info.plist")
        guard fileManager.fileExists(atPath: infoPlist.path) else {
            throw ReleaseError.notAnApplication("\(bundle.path) does not look like a macOS application bundle.")
        }
        let info = try PropertyListReader.read(infoPlist)
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let executableName = info["CFBundleExecutable"] as? String ?? "Taskrivet"
        let executable = bundle.appendingPathComponent("Contents/MacOS/\(executableName)")
        let executablePresent = fileManager.isExecutableFile(atPath: executable.path)
        let core = bundle.appendingPathComponent("Contents/Resources/core/taskrivet")
        let corePresent = fileManager.fileExists(atPath: core.path)

        if identifier.isEmpty { problems.append("CFBundleIdentifier is missing") }
        if version.isEmpty { problems.append("CFBundleShortVersionString is missing") }
        if !executablePresent { problems.append("the executable is missing") }
        if !corePresent { problems.append("the packaged Python core is missing") }

        return BundleReport(
            path: bundle.path,
            identifier: identifier,
            version: version.isEmpty ? "unknown" : version,
            build: build.isEmpty ? "unknown" : build,
            executablePresent: executablePresent,
            corePresent: corePresent,
            problems: problems
        )
    }

    /// Runs the packaged Python core to prove the build actually works.
    ///
    /// The check uses a throwaway database, so it never touches the real ledger.
    public func smokeTest(bundle: URL) throws -> (passed: Bool, detail: String) {
        guard let python else {
            return (false, "Python 3.11 or newer is required for the smoke test.")
        }
        let coreRoot = bundle.appendingPathComponent("Contents/Resources/core")
        guard fileManager.fileExists(atPath: coreRoot.appendingPathComponent("taskrivet").path) else {
            return (false, "The bundle has no packaged Python core.")
        }
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("osprey-smoke-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let database = scratch.appendingPathComponent("smoke.sqlite")
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = coreRoot.path
        let result = try LedgerClient.run(
            [python, "-m", "taskrivet", "--db", database.path, "status"],
            environment: environment,
            workingDirectory: coreRoot,
            fileManager: fileManager
        )
        if result.status == 0 {
            return (true, "The packaged core answered a ledger status read.")
        }
        let message = String(data: result.stderr, encoding: .utf8) ?? "unknown error"
        return (false, "The packaged core failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    // MARK: - Install and rollback

    /// Installs a built bundle, keeping a backup of whatever was there before.
    ///
    /// If the smoke test fails, the previous bundle is restored and the failure
    /// is reported. A half-installed application is never left behind.
    public func install(bundle: URL, runSmokeTest: Bool = true) throws -> InstallOutcome {
        let report = try verify(bundle: bundle)
        guard report.isUsable else { throw ReleaseError.unusableBundle(report.problems) }

        var backupPath: URL?
        if fileManager.fileExists(atPath: installedPath.path) {
            let folder = try makeBackupFolder()
            let destination = folder.appendingPathComponent(installedPath.lastPathComponent, isDirectory: true)
            try fileManager.copyItem(at: installedPath, to: destination)
            backupPath = destination
        }

        let staging = installedPath.deletingLastPathComponent()
            .appendingPathComponent(".osprey-staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: bundle, to: staging)
            if fileManager.fileExists(atPath: installedPath.path) {
                try fileManager.removeItem(at: installedPath)
            }
            try fileManager.moveItem(at: staging, to: installedPath)
        } catch {
            try? fileManager.removeItem(at: staging)
            if let backupPath { try? fileManager.removeItem(at: installedPath) ; try? fileManager.moveItem(at: backupPath, to: installedPath) }
            throw ReleaseError.installFailed("Could not install the bundle: \(error.localizedDescription)")
        }

        if runSmokeTest {
            let smoke = try smokeTest(bundle: installedPath)
            if !smoke.passed {
                try? fileManager.removeItem(at: installedPath)
                if let backupPath { try? fileManager.moveItem(at: backupPath, to: installedPath) }
                return InstallOutcome(
                    installedPath: installedPath.path,
                    backupPath: backupPath?.path,
                    smokeTestPassed: false,
                    rolledBack: backupPath != nil,
                    detail: "The smoke test failed, so the previous build was restored. " + smoke.detail
                )
            }
            return InstallOutcome(
                installedPath: installedPath.path,
                backupPath: backupPath?.path,
                smokeTestPassed: true,
                rolledBack: false,
                detail: "Installed and verified. " + smoke.detail
            )
        }

        return InstallOutcome(
            installedPath: installedPath.path,
            backupPath: backupPath?.path,
            smokeTestPassed: false,
            rolledBack: false,
            detail: "Installed without a smoke test."
        )
    }

    /// Restores a previous build from the backup folder.
    public func rollback(backup: URL? = nil) throws -> InstallOutcome {
        let source = try backup ?? latestBackup()
        guard fileManager.fileExists(atPath: source.path) else {
            throw ReleaseError.nothingToRollBack("No backup was found at \(source.path).")
        }
        let current = installedPath.deletingLastPathComponent()
            .appendingPathComponent(".osprey-rollback-\(UUID().uuidString)", isDirectory: true)
        if fileManager.fileExists(atPath: installedPath.path) {
            try fileManager.moveItem(at: installedPath, to: current)
        }
        do {
            try fileManager.copyItem(at: source, to: installedPath)
            try? fileManager.removeItem(at: current)
        } catch {
            if fileManager.fileExists(atPath: current.path) {
                try? fileManager.moveItem(at: current, to: installedPath)
            }
            throw ReleaseError.installFailed("Could not restore the backup: \(error.localizedDescription)")
        }
        return InstallOutcome(
            installedPath: installedPath.path,
            backupPath: source.path,
            smokeTestPassed: false,
            rolledBack: true,
            detail: "Restored the previous build from \(source.path)."
        )
    }

    /// The most recent backup Osprey or Taskrivet made.
    public func latestBackup() throws -> URL {
        let entries = try fileManager.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let candidates = entries
            .filter { $0.hasDirectoryPath }
            .flatMap { entry -> [URL] in
                let child = entry.appendingPathComponent(installedPath.lastPathComponent, isDirectory: true)
                return fileManager.fileExists(atPath: child.path) ? [child] : []
            }
            .sorted { $0.path > $1.path }
        guard let newest = candidates.first else {
            throw ReleaseError.nothingToRollBack("No Taskrivet backup was found in \(backupRoot.path).")
        }
        return newest
    }

    public func listBackups() -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.hasDirectoryPath }
            .flatMap { entry -> [URL] in
                let child = entry.appendingPathComponent(installedPath.lastPathComponent, isDirectory: true)
                return fileManager.fileExists(atPath: child.path) ? [child] : []
            }
            .sorted { $0.path > $1.path }
    }

    /// A fresh backup folder. Two installs in the same second get separate folders.
    private func makeBackupFolder() throws -> URL {
        let base = timestamp()
        var candidate = backupRoot.appendingPathComponent(base, isDirectory: true)
        var counter = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = backupRoot.appendingPathComponent("\(base)-\(counter)", isDirectory: true)
            counter += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}

/// Reads the parts of a property list Osprey needs from a built bundle.
enum PropertyListReader {
    static func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return (object as? [String: Any]) ?? [:]
    }
}
