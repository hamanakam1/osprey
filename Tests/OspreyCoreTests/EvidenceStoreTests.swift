import Foundation
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
