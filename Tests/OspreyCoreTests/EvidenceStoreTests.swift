import Foundation
import SQLite3
import Testing
@testable import OspreyCore

@Suite("Evidence store")
final class EvidenceStoreTests {
    private var directory: URL!
    private var store: EvidenceStore!

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osprey-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try EvidenceStore(url: directory.appendingPathComponent("evidence.sqlite"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("evidence round trips")
    func evidenceRoundTrips() throws {
        let record = EvidenceRecord(terminalID: "t1", text: "hello", bytes: 5, redactions: 0)
        try store.append(record)
        let read = try store.evidence(forTerminal: "t1")
        #expect(read.count == 1)
        #expect(read.first?.text == "hello")
        #expect(try store.evidenceCount() == 1)
    }

    @Test("empty evidence is not stored")
    func emptyEvidenceIsNotStored() throws {
        try store.append(EvidenceRecord(terminalID: "t1", text: "", bytes: 0, redactions: 0))
        #expect(try store.evidenceCount() == 0)
    }

    @Test("evidence is separated by terminal")
    func evidenceIsSeparatedByTerminal() throws {
        try store.append(EvidenceRecord(terminalID: "t1", text: "one", bytes: 3, redactions: 0))
        try store.append(EvidenceRecord(terminalID: "t2", text: "two", bytes: 3, redactions: 0))
        #expect(try store.evidence(forTerminal: "t1").count == 1)
        #expect(try store.evidence(forTerminal: "t2").first?.text == "two")
    }

    @Test("pruning removes only old evidence")
    func pruningRemovesOldEvidenceOnly() throws {
        let old = EvidenceRecord(
            terminalID: "t1",
            capturedAt: Date(timeIntervalSinceNow: -86_400 * 30),
            text: "old",
            bytes: 3,
            redactions: 0
        )
        let fresh = EvidenceRecord(terminalID: "t1", text: "fresh", bytes: 5, redactions: 0)
        try store.append(old)
        try store.append(fresh)
        let removed = try store.prune(olderThan: Date(timeIntervalSinceNow: -86_400 * 7))
        #expect(removed == 1)
        #expect(try store.evidenceCount() == 1)
        #expect(try store.evidence(forTerminal: "t1").first?.text == "fresh")
    }

    @Test("proposals keep their state")
    func proposalsKeepTheirState() throws {
        let proposal = Proposal(
            kind: .checkpoint,
            terminalID: "t1",
            terminalTitle: "A tab",
            session: "sess-1",
            task: "task-1",
            summary: "did a thing",
            evidence: "captured bytes",
            next: "confirm the next step"
        )
        try store.save(proposal)
        #expect(try store.proposals(state: .proposed).count == 1)
        #expect(try store.proposals(state: .applied).count == 0)
        try store.setProposalState(id: proposal.id, state: .applied, note: "verified")
        #expect(try store.proposals(state: .applied).count == 1)
        let applied = try store.proposal(id: proposal.id)
        #expect(applied?.note == "verified")
        #expect(applied?.appliedAt != nil)
    }

    private func fixtureProposal() -> Proposal {
        Proposal(
            id: "proposal-001", kind: .checkpoint, terminalID: "terminal-001",
            terminalTitle: "Synthetic tab", session: "session-001", task: "task-001",
            summary: "Synthetic proposal", evidence: "Synthetic evidence", next: "Review the result"
        )
    }

    private func executeFixtureSQL(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(store.url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw OspreyError.storeFailure("Could not open the synthetic fixture database.")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw OspreyError.storeFailure("Could not install the synthetic fixture trigger.")
        }
    }

    @Test("an absent proposal remains absent when its state is changed")
    func absentProposalRemainsAbsent() throws {
        #expect(try store.setProposalState(id: "proposal-missing", state: .applied) == nil)
        #expect(try store.proposals().isEmpty)
    }

    @Test("a proposal disappearing during its state change is not recreated")
    func disappearingProposalIsNotRecreated() throws {
        let proposal = fixtureProposal()
        try store.save(proposal)
        // Delete at the mutation boundary for either implementation: replacing
        // inserts recreate the row, while an update must report no matching row.
        try executeFixtureSQL("""
            CREATE TRIGGER disappear_before_insert BEFORE INSERT ON proposals
            BEGIN DELETE FROM proposals WHERE id = NEW.id; END;
            CREATE TRIGGER disappear_before_update BEFORE UPDATE ON proposals
            BEGIN
                DELETE FROM proposals WHERE id = OLD.id;
                SELECT RAISE(IGNORE);
            END;
            """)
        let updated = try store.setProposalState(id: proposal.id, state: .applied, note: "Synthetic confirmation")
        #expect(updated == nil)
        let reopened = try EvidenceStore(url: store.url)
        #expect(try reopened.proposal(id: proposal.id) == nil)
    }

    @Test("a state update error is thrown rather than reported as a missing proposal")
    func failedStateUpdateThrows() throws {
        let proposal = fixtureProposal()
        try store.save(proposal)
        try executeFixtureSQL("""
            CREATE TRIGGER reject_state_update BEFORE UPDATE ON proposals
            BEGIN SELECT RAISE(ABORT, 'synthetic update failure'); END;
            """)
        do {
            _ = try store.setProposalState(id: proposal.id, state: .applied)
            Issue.record("A rejected update must throw a storage error.")
        } catch OspreyError.storeFailure(let message) {
            #expect(message.contains("synthetic update failure"))
        }
        let readback = try store.proposal(id: proposal.id)
        #expect(readback?.state == .proposed)
        #expect(readback?.appliedAt == nil)
    }

    @Test("receipts are kept newest first")
    func receiptsAreKeptNewestFirst() throws {
        let older = ReleaseReceipt(action: .verified, occurredAt: Date(timeIntervalSinceNow: -600), version: "0.1.0", source: "a")
        let newer = ReleaseReceipt(action: .installed, version: "0.2.0", source: "b")
        try store.append(older)
        try store.append(newer)
        let receipts = try store.receipts()
        #expect(receipts.first?.version == "0.2.0")
    }

    @Test("meta round trips")
    func metaRoundTrips() throws {
        try store.setMeta("last-capture", "2026-01-01")
        #expect(try store.meta("last-capture") == "2026-01-01")
        #expect(try store.meta("missing") == nil)
    }
}
