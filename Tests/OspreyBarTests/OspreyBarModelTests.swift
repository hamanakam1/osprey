import Foundation
import Testing
@testable import OspreyBar
@testable import OspreyCore

@Suite("Menu approval")
struct OspreyBarModelTests {
    @Test("an unverified checkpoint is stored and shown as failed")
    func unverifiedCheckpointFails() throws {
        try assertApproval(kind: .checkpoint, verified: false)
    }

    @Test("an unverified failure record is stored and shown as failed")
    func unverifiedFailureRecordFails() throws {
        try assertApproval(kind: .failure, verified: false)
    }

    @Test("a verified checkpoint is stored and shown as applied")
    func verifiedCheckpointSucceeds() throws {
        try assertApproval(kind: .checkpoint, verified: true)
    }

    @Test("a verified failure record is stored and shown as applied")
    func verifiedFailureRecordSucceeds() throws {
        try assertApproval(kind: .failure, verified: true)
    }

    private func assertApproval(kind: ProposalKind, verified: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osprey-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("evidence.sqlite")
        let store = try EvidenceStore(url: database)
        let proposal = Proposal(
            kind: kind,
            terminalID: "terminal-001",
            terminalTitle: "Synthetic tab",
            session: "session-001",
            task: "task-001",
            summary: "Synthetic approval",
            evidence: "Synthetic evidence",
            next: "Review the result"
        )
        try store.save(proposal)
        let result = LedgerClient.ApplyResult(
            sessionID: "session-001",
            status: kind == .checkpoint ? "active" : "failed",
            tokens: 120,
            verified: verified,
            detail: verified ? "Synthetic readback confirmed." : "Synthetic readback did not confirm the write."
        )

        // Call the same worker used by the menu without constructing the model,
        // whose initial refresh resolves the operator's real local paths.
        let outcome = try OspreyBarModel.finishApproval(proposal, result: result, store: store)
        let action = OspreyBarModel.Action(proposalID: proposal.id, outcome: outcome, when: Date())
        #expect(action.isFailure == !verified)
        #expect(action.message.contains(result.detail))

        let reopened = try EvidenceStore(url: database)
        let readback = try reopened.proposal(id: proposal.id)
        let recorded = try #require(readback)
        #expect(recorded.state == (verified ? .applied : .failed))
        if verified {
            #expect(recorded.appliedAt != nil)
        } else {
            #expect(recorded.appliedAt == nil)
            #expect(recorded.note?.contains(result.detail) == true)
        }
    }
}
