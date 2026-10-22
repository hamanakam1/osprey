import Foundation

/// Writes an approved proposal into the Taskrivet ledger, then reads it back.
///
/// The ledger is Taskrivet's, not Osprey's. Osprey calls the Taskrivet CLI with
/// an explicit argument vector, never a shell, and verifies the write by
/// reading the session back from the same source of truth.
public final class LedgerClient {
    public struct ApplyResult: Sendable {
        public let sessionID: String
        public let status: String
        public let tokens: Int
        public let verified: Bool
        public let detail: String
    }

    public struct SessionStatus: Sendable {
        public let id: String
        public let taskID: String
        public let tokens: Int
        public let status: String
    }

    public enum LedgerError: Error, CustomStringConvertible, Sendable {
        case pythonMissing(String)
        case coreMissing([String])
        case commandFailed(String)
        case unreadable(String)
        case notApplicable(String)

        public var description: String {
            switch self {
            case .pythonMissing(let message): return message
            case .coreMissing(let paths): return
                "The Taskrivet Python core was not found. Set TASKRIVET_CORE to the folder that contains the taskrivet package. Looked in: \(paths.joined(separator: ", "))"
            case .commandFailed(let message): return message
            case .unreadable(let message): return message
            case .notApplicable(let message): return message
            }
        }
    }

    private let database: URL
    private let coreRoot: URL?
    private let python: String?
    private let fileManager: FileManager

    public init(
        database: URL,
        coreRoot: URL?,
        python: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.coreRoot = coreRoot
        self.python = python ?? Self.findPython(fileManager: fileManager)
        self.fileManager = fileManager
    }

    /// Finds a Python 3.11 or newer interpreter.
    public static func findPython(candidates explicit: [String]? = nil, fileManager: FileManager = .default) -> String? {
        var candidates: [String] = []
        if let explicit {
            candidates = explicit
        } else {
            if fileManager.isExecutableFile(atPath: "/opt/homebrew/bin/python3") { candidates.append("/opt/homebrew/bin/python3") }
            if fileManager.isExecutableFile(atPath: "/usr/local/bin/python3") { candidates.append("/usr/local/bin/python3") }
            candidates.append("/usr/bin/python3")
        }
        for candidate in candidates {
            if Self.pythonVersion(candidate, fileManager: fileManager) >= (3, 11) { return candidate }
        }
        return nil
    }

    public static func pythonVersion(_ path: String, fileManager: FileManager = .default) -> (Int, Int) {
        guard let output = try? Self.run(
            [path, "-c", "import sys; print(sys.version_info[0], sys.version_info[1])"],
            environment: nil,
            workingDirectory: nil,
            fileManager: fileManager
        ), output.status == 0 else { return (0, 0) }
        let text = String(data: output.stdout, encoding: .utf8) ?? ""
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .compactMap { Int($0) }
        guard parts.count >= 2 else { return (0, 0) }
        return (parts[0], parts[1])
    }

    // MARK: - Reading

    /// Reads the ledger status. This is the same read the desktop inspector uses.
    public func status() throws -> [String: Any] {
        let result = try runTaskrivet(arguments: ["status"])
        guard let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw LedgerError.unreadable("The Taskrivet ledger returned a status Osprey could not read.")
        }
        return object
    }

    /// The ledger sessions Taskrivet currently knows about.
    public func sessions() throws -> [SessionStatus] {
        let status = try status()
        guard let rows = status["sessions"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return SessionStatus(
                id: id,
                taskID: row["task_id"] as? String ?? "",
                tokens: (row["tokens"] as? Int) ?? 0,
                status: row["status"] as? String ?? "unknown"
            )
        }
    }

    public func session(id: String) throws -> SessionStatus? {
        try sessions().first { $0.id == id }
    }

    // MARK: - Writing

    /// Applies an approved proposal and verifies the write by reading it back.
    ///
    /// `tokens` is the cumulative reported count for the session. Osprey does
    /// not measure usage, so the caller carries the last reported count forward
    /// unless the operator states a new one.
    public func apply(proposal: Proposal, tokens: Int? = nil) throws -> ApplyResult {
        guard let sessionID = proposal.session, !sessionID.isEmpty else {
            throw LedgerError.notApplicable(
                "This terminal is not linked to a Taskrivet ledger session, so there is no record to write. Open the terminal with a task assignment first."
            )
        }
        guard let coreRoot else {
            throw LedgerError.coreMissing(
                TaskrivetLocator.coreRootSearchPaths().map(\.path)
            )
        }
        guard let python else {
            throw LedgerError.pythonMissing("Python 3.11 or newer is required to write to the Taskrivet ledger.")
        }

        let current = try session(id: sessionID)
        let carried = current?.tokens ?? 0
        let reported = max(tokens ?? carried, carried)

        switch proposal.kind {
        case .checkpoint:
            let arguments = [
                "checkpoint", sessionID,
                "--summary", proposal.summary,
                "--evidence", proposal.evidence,
                "--next", proposal.next,
                "--tokens", String(reported),
            ]
            let result = try runTaskrivet(arguments: arguments)
            let payload = (try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]) ?? [:]
            let status = payload["status"] as? String ?? "unknown"
            let readback = try session(id: sessionID)
            let verified = readback != nil && readback?.tokens == reported
            return ApplyResult(
                sessionID: sessionID,
                status: status,
                tokens: reported,
                verified: verified,
                detail: verified
                    ? "Ledger readback confirms \(reported) reported token(s) on session \(sessionID)."
                    : "The ledger accepted the record but the readback did not confirm the reported token count."
            )
        case .failure:
            let category = proposal.category ?? "terminal_output"
            let arguments = ["fail", sessionID, "--category", category, "--summary", proposal.summary]
            let result = try runTaskrivet(arguments: arguments)
            let payload = (try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]) ?? [:]
            let readback = try session(id: sessionID)
            return ApplyResult(
                sessionID: sessionID,
                status: payload["status"] as? String ?? readback?.status ?? "unknown",
                tokens: readback?.tokens ?? reported,
                verified: readback?.status == "failed",
                detail: "Failure record written to session \(sessionID). A recorded failure is not a diagnosis."
            )
        }
    }

    // MARK: - Process helpers

    private func runTaskrivet(arguments: [String]) throws -> CommandResult {
        guard let coreRoot else {
            throw LedgerError.coreMissing(TaskrivetLocator.coreRootSearchPaths().map(\.path))
        }
        guard let python else {
            throw LedgerError.pythonMissing("Python 3.11 or newer is required to write to the Taskrivet ledger.")
        }
        var argv = [python, "-m", "taskrivet", "--db", database.path]
        argv.append(contentsOf: arguments)
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = coreRoot.path
        return try Self.run(argv, environment: environment, workingDirectory: coreRoot, fileManager: fileManager)
    }

    struct CommandResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    @discardableResult
    static func run(
        _ arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?,
        fileManager: FileManager = .default
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: outData, stderr: errData)
    }
}
