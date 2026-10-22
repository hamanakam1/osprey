import Foundation
import Testing
@testable import OspreyCore

@Suite("Proposal engine")
struct ProposalEngineTests {
    private let engine = ProposalEngine()

    private func terminal(session: String? = "sess-1", task: String? = "task-1") -> TaskrivetTerminal {
        TaskrivetTerminal(
            id: "term-1",
            cwd: "/tmp/project",
            task: task,
            session: session,
            title: "Fix the search state"
        )
    }

    @Test("a checkpoint proposal is drafted from the output")
    func checkpointProposalIsDraftedFromOutput() {
        let evidence = [
            EvidenceRecord(terminalID: "term-1", text: "$ git status\n$ make build\n", bytes: 24, redactions: 0)
        ]
        let proposal = engine.checkpointProposal(terminal: terminal(), evidence: evidence)
        #expect(proposal != nil)
        #expect(proposal?.kind == .checkpoint)
        #expect(proposal?.session == "sess-1")
        #expect(proposal?.task == "task-1")
        #expect(proposal.map { $0.summary.contains("git status") } == true)
        #expect(proposal.map { $0.evidence.contains("24 bytes") } == true)
    }

    @Test("no evidence means no proposal")
    func noEvidenceMeansNoProposal() {
        #expect(engine.checkpointProposal(terminal: terminal(), evidence: []) == nil)
    }

    @Test("a proposal never claims verified progress")
    func proposalNeverClaimsVerifiedProgress() {
        let evidence = [EvidenceRecord(terminalID: "term-1", text: "$ make build\n", bytes: 12, redactions: 0)]
        let proposal = engine.checkpointProposal(terminal: terminal(), evidence: evidence)
        #expect(proposal.map { $0.note?.contains("Not verified progress") == true } == true)
        #expect(proposal.map { $0.evidence.contains("not measured") } == true)
    }

    @Test("a failure proposal needs failure text")
    func failureProposalNeedsFailureText() {
        let clean = [EvidenceRecord(terminalID: "term-1", text: "$ make build\n", bytes: 12, redactions: 0)]
        #expect(engine.failureProposal(terminal: terminal(), evidence: clean) == nil)

        let broken = [EvidenceRecord(terminalID: "term-1", text: "error: no such module 'Foo'\n", bytes: 28, redactions: 0)]
        let proposal = engine.failureProposal(terminal: terminal(), evidence: broken)
        #expect(proposal != nil)
        #expect(proposal?.kind == .failure)
        #expect(proposal?.category == "terminal_output")
    }

    @Test("a proposal without a ledger session cannot be applied")
    func proposalWithoutLedgerSessionIsNotApplicable() {
        let evidence = [EvidenceRecord(terminalID: "term-1", text: "$ make build\n", bytes: 12, redactions: 0)]
        let proposal = engine.checkpointProposal(terminal: terminal(session: nil, task: nil), evidence: evidence)
        #expect(proposal?.session == nil)
        #expect(proposal?.isApplicable == false)
    }

    @Test("the digest counts bytes, lines and redactions")
    func digestCountsLinesCommandsAndRedactions() {
        let evidence = [
            EvidenceRecord(terminalID: "term-1", text: "a\nb\nc", bytes: 5, redactions: 2),
            EvidenceRecord(terminalID: "term-1", text: "$ git log\n", bytes: 10, redactions: 1),
        ]
        let digest = engine.digest(for: "term-1", evidence: evidence)
        #expect(digest.bytes == 15)
        #expect(digest.redactions == 3)
        #expect(digest.commands.contains("git log"))
    }

    @Test("a proposal round trips through JSON")
    func proposalRoundTripsThroughJSON() throws {
        let proposal = engine.checkpointProposal(
            terminal: terminal(),
            evidence: [EvidenceRecord(terminalID: "term-1", text: "$ make build\n", bytes: 12, redactions: 0)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(proposal)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(Proposal.self, from: data)
        #expect(restored.id == proposal?.id)
        #expect(restored.state == .proposed)
    }
}
