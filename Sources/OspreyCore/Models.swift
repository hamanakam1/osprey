import Foundation

/// One buffered chunk of terminal output as the session service keeps it.
public struct TerminalChunk: Codable, Equatable, Sendable {
    public let seq: Int
    public let data: String

    public init(seq: Int, data: String) {
        self.seq = seq
        self.data = data
    }
}

/// A terminal tab as reported by the Taskrivet local session service.
/// Only the fields Osprey needs are decoded; unknown fields are ignored.
public struct TaskrivetTerminal: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let cwd: String
    public let task: String?
    public let session: String?
    public let shell: String
    public let state: String
    public let exitCode: Int?
    public let pid: Int?
    public let title: String?
    public let kind: String?
    public let ref: String?
    /// The bounded output tail the service keeps for reconnecting clients.
    public let chunks: [TerminalChunk]?

    public init(
        id: String,
        cwd: String,
        task: String? = nil,
        session: String? = nil,
        shell: String = "/bin/zsh",
        state: String = "running",
        exitCode: Int? = nil,
        pid: Int? = nil,
        title: String? = nil,
        kind: String? = nil,
        ref: String? = nil,
        chunks: [TerminalChunk]? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.task = task
        self.session = session
        self.shell = shell
        self.state = state
        self.exitCode = exitCode
        self.pid = pid
        self.title = title
        self.kind = kind
        self.ref = ref
        self.chunks = chunks
    }

    /// The label a person would recognise. OpenCode tabs carry a session title.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let task, !task.isEmpty { return task }
        return (shell as NSString).lastPathComponent
    }

    public var isRunning: Bool { state == "running" }
    public var isOpenCode: Bool { kind == "opencode" }
}

/// One captured, already-redacted piece of terminal output.
public struct EvidenceRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let terminalID: String
    public let capturedAt: Date
    public let text: String
    public let bytes: Int
    public let redactions: Int

    public init(
        id: String = UUID().uuidString,
        terminalID: String,
        capturedAt: Date = Date(),
        text: String,
        bytes: Int,
        redactions: Int
    ) {
        self.id = id
        self.terminalID = terminalID
        self.capturedAt = capturedAt
        self.text = text
        self.bytes = bytes
        self.redactions = redactions
    }
}

/// What a proposal would record in the Taskrivet ledger.
public enum ProposalKind: String, Codable, Equatable, Sendable {
    case checkpoint
    case failure
}

/// The lifecycle of a proposal. Osprey never moves a proposal forward by itself.
public enum ProposalState: String, Codable, Equatable, Sendable {
    case proposed
    case applied
    case failed
    case withdrawn
}

/// A reviewable draft. Osprey proposes; a person approves; the ledger records.
public struct Proposal: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ProposalKind
    public let terminalID: String
    public let terminalTitle: String
    /// The Taskrivet ledger session this proposal would be written to.
    public let session: String?
    public let task: String?
    public let summary: String
    public let evidence: String
    public let next: String
    public let category: String?
    public let tokens: Int
    public let createdAt: Date
    public var state: ProposalState
    public var appliedAt: Date?
    public var note: String?

    public init(
        id: String = UUID().uuidString,
        kind: ProposalKind,
        terminalID: String,
        terminalTitle: String,
        session: String?,
        task: String?,
        summary: String,
        evidence: String,
        next: String,
        category: String? = nil,
        tokens: Int = 0,
        createdAt: Date = Date(),
        state: ProposalState = .proposed,
        appliedAt: Date? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.terminalID = terminalID
        self.terminalTitle = terminalTitle
        self.session = session
        self.task = task
        self.summary = summary
        self.evidence = evidence
        self.next = next
        self.category = category
        self.tokens = tokens
        self.createdAt = createdAt
        self.state = state
        self.appliedAt = appliedAt
        self.note = note
    }

    /// Whether this proposal can be written to a ledger session at all.
    public var isApplicable: Bool {
        kind == .checkpoint ? (session?.isEmpty == false) : (session?.isEmpty == false)
    }
}

/// A record of one build that was verified, installed, or rolled back.
public struct ReleaseReceipt: Codable, Equatable, Identifiable, Sendable {
    public enum Action: String, Codable, Equatable, Sendable {
        case verified
        case installed
        case rolledBack
        case failed
    }

    public let id: String
    public let action: Action
    public let occurredAt: Date
    public let version: String
    public let source: String
    public let backupPath: String?
    public let installedPath: String?
    public let smokeTest: String?
    public let detail: String

    public init(
        id: String = UUID().uuidString,
        action: Action,
        occurredAt: Date = Date(),
        version: String,
        source: String,
        backupPath: String? = nil,
        installedPath: String? = nil,
        smokeTest: String? = nil,
        detail: String = ""
    ) {
        self.id = id
        self.action = action
        self.occurredAt = occurredAt
        self.version = version
        self.source = source
        self.backupPath = backupPath
        self.installedPath = installedPath
        self.smokeTest = smokeTest
        self.detail = detail
    }
}

/// A redacted, countable summary of a terminal's output.
public struct TerminalDigest: Codable, Equatable, Sendable {
    public let terminalID: String
    public let bytes: Int
    public let lines: Int
    public let commands: [String]
    public let failures: [String]
    public let redactions: Int

    public init(
        terminalID: String,
        bytes: Int,
        lines: Int,
        commands: [String],
        failures: [String],
        redactions: Int
    ) {
        self.terminalID = terminalID
        self.bytes = bytes
        self.lines = lines
        self.commands = commands
        self.failures = failures
        self.redactions = redactions
    }
}
