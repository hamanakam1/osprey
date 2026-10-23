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

    @Test("a verified ledger result cannot complete a missing local proposal")
    func missingVerifiedProposalFails() throws {
        try assertApproval(kind: .checkpoint, verified: true, saved: false)
    }

    @Test("an unverified ledger result cannot claim a missing proposal was marked failed")
    func missingUnverifiedProposalFails() throws {
        try assertApproval(kind: .checkpoint, verified: false, saved: false)
    }

    private func assertApproval(kind: ProposalKind, verified: Bool, saved: Bool = true) throws {
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
        if saved { try store.save(proposal) }
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
        if !saved {
            #expect(action.isFailure)
            #expect(action.message.contains("no longer in the Osprey store"))
            #expect(action.message.contains("may already"))
            #expect(action.message.contains("before retrying"))
            #expect(!action.message.contains("marked failed"))
            let reopened = try EvidenceStore(url: database)
            #expect(try reopened.proposal(id: proposal.id) == nil)
            return
        }
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
