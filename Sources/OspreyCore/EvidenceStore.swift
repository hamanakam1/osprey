import Foundation
import SQLite3

/// SQLite needs to copy bound text, because Swift strings do not have a
/// guaranteed lifetime that matches the C API.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The local evidence and proposal store.
///
/// Osprey keeps one SQLite file under its own state directory. Nothing is sent
/// anywhere. Terminal output is stored already redacted, bounded in size, and
/// bounded in age.
public final class EvidenceStore {
    private var handle: OpaquePointer?
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw OspreyError.storeFailure("Could not open the evidence store at \(url.path): \(message)")
        }
        handle = db
        try createSchema()
    }

    deinit { sqlite3_close(handle) }

    public enum StoreError: Error, Equatable, Sendable {
        case storeFailure(String)
    }

    private func createSchema() throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS evidence (
              id TEXT PRIMARY KEY,
              terminal_id TEXT NOT NULL,
              captured_at REAL NOT NULL,
              text TEXT NOT NULL,
              bytes INTEGER NOT NULL,
              redactions INTEGER NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS evidence_terminal_idx ON evidence (terminal_id, captured_at);",
            """
            CREATE TABLE IF NOT EXISTS proposals (
              id TEXT PRIMARY KEY,
              state TEXT NOT NULL,
              created_at REAL NOT NULL,
              applied_at REAL,
              json TEXT NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS proposals_state_idx ON proposals (state, created_at);",
            """
            CREATE TABLE IF NOT EXISTS receipts (
              id TEXT PRIMARY KEY,
              occurred_at REAL NOT NULL,
              action TEXT NOT NULL,
              json TEXT NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS receipts_time_idx ON receipts (occurred_at);",
            """
            CREATE TABLE IF NOT EXISTS meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            """,
        ]
        for statement in statements {
            try execute(statement)
        }
    }

    // MARK: - Primitive helpers

    @discardableResult
    private func execute(_ sql: String, _ bindings: [String] = []) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw OspreyError.storeFailure("Could not prepare a statement: \(message)")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            let message = String(cString: sqlite3_errmsg(handle))
            throw OspreyError.storeFailure("Statement failed: \(message)")
        }
        return result
    }

    private func query(_ sql: String, _ bindings: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw OspreyError.storeFailure("Could not read from the evidence store.")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }
        var rows: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                if let text = sqlite3_column_text(statement, column) {
                    row[name] = String(cString: text)
                } else {
                    row[name] = ""
                }
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - Evidence

    /// Stores one redacted chunk. Empty text is ignored.
    public func append(_ record: EvidenceRecord) throws {
        guard !record.text.isEmpty else { return }
        try execute(
            "INSERT OR REPLACE INTO evidence (id, terminal_id, captured_at, text, bytes, redactions) VALUES (?,?,?,?,?,?);",
            [
                record.id,
                record.terminalID,
                String(record.capturedAt.timeIntervalSince1970),
                record.text,
                String(record.bytes),
                String(record.redactions),
            ]
        )
    }

    public func evidence(forTerminal terminalID: String, limit: Int = 200) throws -> [EvidenceRecord] {
        let rows = try query(
            "SELECT id, terminal_id, captured_at, text, bytes, redactions FROM evidence WHERE terminal_id = ? ORDER BY captured_at ASC LIMIT ?;",
            [terminalID, String(max(1, limit))]
        )
        return rows.compactMap { row -> EvidenceRecord? in
            let id = row["id"] ?? ""
            let terminal = row["terminal_id"] ?? ""
            let text = row["text"] ?? ""
            guard !id.isEmpty, !terminal.isEmpty else { return nil }
            return EvidenceRecord(
                id: id,
                terminalID: terminal,
                capturedAt: Date(timeIntervalSince1970: Double(row["captured_at"] ?? "0") ?? 0),
                text: text,
                bytes: Int(row["bytes"] ?? "0") ?? 0,
                redactions: Int(row["redactions"] ?? "0") ?? 0
            )
        }
    }

    public func recentEvidence(limit: Int = 200) throws -> [EvidenceRecord] {
        let rows = try query(
            "SELECT id, terminal_id, captured_at, text, bytes, redactions FROM evidence ORDER BY captured_at DESC LIMIT ?;",
            [String(max(1, limit))]
        )
        return rows.compactMap { row -> EvidenceRecord? in
            let id = row["id"] ?? ""
            let terminal = row["terminal_id"] ?? ""
            let text = row["text"] ?? ""
            guard !id.isEmpty, !terminal.isEmpty else { return nil }
            return EvidenceRecord(
                id: id,
                terminalID: terminal,
                capturedAt: Date(timeIntervalSince1970: Double(row["captured_at"] ?? "0") ?? 0),
                text: text,
                bytes: Int(row["bytes"] ?? "0") ?? 0,
                redactions: Int(row["redactions"] ?? "0") ?? 0
            )
        }
    }

    /// Removes evidence older than the retention window and returns the count.
    @discardableResult
    public func prune(olderThan date: Date) throws -> Int {
        let rows = try query("SELECT COUNT(*) AS n FROM evidence WHERE captured_at < ?;", [String(date.timeIntervalSince1970)])
        let count = Int(rows.first?["n"] ?? "0") ?? 0
        try execute("DELETE FROM evidence WHERE captured_at < ?;", [String(date.timeIntervalSince1970)])
        return count
    }

    public func evidenceCount() throws -> Int {
        let rows = try query("SELECT COUNT(*) AS n FROM evidence;")
        return Int(rows.first?["n"] ?? "0") ?? 0
    }

    // MARK: - Proposals

    public func save(_ proposal: Proposal) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(proposal), encoding: .utf8) ?? "{}"
        try execute(
            "INSERT OR REPLACE INTO proposals (id, state, created_at, applied_at, json) VALUES (?,?,?,?,?);",
            [
                proposal.id,
                proposal.state.rawValue,
                String(proposal.createdAt.timeIntervalSince1970),
                proposal.appliedAt.map { String($0.timeIntervalSince1970) } ?? "",
                json,
            ]
        )
    }

    public func proposals(state: ProposalState? = nil) throws -> [Proposal] {
        let rows: [[String: String]]
        if let state {
            rows = try query(
                "SELECT json FROM proposals WHERE state = ? ORDER BY created_at DESC;",
                [state.rawValue]
            )
        } else {
            rows = try query("SELECT json FROM proposals ORDER BY created_at DESC;")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return rows.compactMap { row in
            let json = row["json"] ?? ""
            guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
            return try? decoder.decode(Proposal.self, from: data)
        }
    }

    public func proposal(id: String) throws -> Proposal? {
        try proposals().first { $0.id == id }
    }

    @discardableResult
    public func setProposalState(id: String, state: ProposalState, note: String? = nil) throws -> Proposal? {
        guard var proposal = try proposal(id: id) else { return nil }
        proposal.state = state
        if state == .applied { proposal.appliedAt = Date() }
        if let note { proposal.note = note }
        try save(proposal)
        return proposal
    }

    // MARK: - Receipts

    public func append(_ receipt: ReleaseReceipt) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(receipt), encoding: .utf8) ?? "{}"
        try execute(
            "INSERT OR REPLACE INTO receipts (id, occurred_at, action, json) VALUES (?,?,?,?);",
            [receipt.id, String(receipt.occurredAt.timeIntervalSince1970), receipt.action.rawValue, json]
        )
    }

    public func receipts(limit: Int = 50) throws -> [ReleaseReceipt] {
        let rows = try query("SELECT json FROM receipts ORDER BY occurred_at DESC LIMIT ?;", [String(max(1, limit))])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return rows.compactMap { row in
            let json = row["json"] ?? ""
            guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
            return try? decoder.decode(ReleaseReceipt.self, from: data)
        }
    }

    // MARK: - Meta

    public func setMeta(_ key: String, _ value: String) throws {
        try execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?,?);", [key, value])
    }

    public func meta(_ key: String) throws -> String? {
        let value = try query("SELECT value FROM meta WHERE key = ?;", [key]).first?["value"] ?? ""
        return value.isEmpty ? nil : value
    }
}

/// Errors the operator can act on.
public enum OspreyError: Error, Equatable, Sendable, CustomStringConvertible {
    case storeFailure(String)
    case taskrivetUnavailable(String)
    case notApplicable(String)
    case invalidInput(String)
    case releaseFailure(String)

    public var description: String {
        switch self {
        case .storeFailure(let message): return message
        case .taskrivetUnavailable(let message): return message
        case .notApplicable(let message): return message
        case .invalidInput(let message): return message
        case .releaseFailure(let message): return message
        }
    }
}
