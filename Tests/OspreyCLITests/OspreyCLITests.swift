import Foundation
import Testing
@testable import osprey
@testable import OspreyCore

@Suite("CLI approval")
struct OspreyCLITests {
    @Test("a verified ledger result cannot complete a missing local proposal")
    func missingVerifiedProposalFails() throws {
        try assertApproval(verified: true, saved: false)
    }

    @Test("an unverified ledger result cannot claim a missing proposal was marked failed")
    func missingUnverifiedProposalFails() throws {
        try assertApproval(verified: false, saved: false)
    }

    @Test("a verified approval persists its applied state")
    func verifiedApprovalPersists() throws {
        try assertApproval(verified: true, saved: true)
    }

    @Test("an unverified approval persists its failed state")
    func unverifiedApprovalPersists() throws {
        try assertApproval(verified: false, saved: true)
    }

    private func assertApproval(verified: Bool, saved: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osprey-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("evidence.sqlite")
        let store = try EvidenceStore(url: database)
        let proposal = Proposal(
            id: "proposal-001", kind: .checkpoint, terminalID: "terminal-001",
            terminalTitle: "Synthetic tab", session: "session-001", task: "task-001",
            summary: "Synthetic approval", evidence: "Synthetic evidence", next: "Review the result"
        )
        if saved { try store.save(proposal) }
        let result = LedgerClient.ApplyResult(
            sessionID: "session-001", status: "active", tokens: 120,
            verified: verified, detail: "Synthetic verification detail."
        )

        if saved {
            try OspreyCLI.finishApproval(id: proposal.id, result: result, store: store)
            let reopened = try EvidenceStore(url: database)
            let readback = try reopened.proposal(id: proposal.id)
            let recorded = try #require(readback)
            #expect(recorded.state == (verified ? .applied : .failed))
            #expect((recorded.appliedAt != nil) == verified)
            #expect(recorded.note == result.detail)
        } else {
            do {
                try OspreyCLI.finishApproval(id: proposal.id, result: result, store: store)
                Issue.record("A missing local proposal must stop approval completion.")
            } catch OspreyError.storeFailure(let message) {
                #expect(message.contains("no longer in the Osprey store"))
                #expect(message.contains("may already"))
                #expect(message.contains("before retrying"))
                #expect(!message.contains("marked failed"))
            }
            let reopened = try EvidenceStore(url: database)
            #expect(try reopened.proposal(id: proposal.id) == nil)
        }
    }
}
