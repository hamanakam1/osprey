import Foundation
import Testing
@testable import OspreyCore

@Suite("Ledger client")
struct LedgerClientTests {
    @Test("an interpreter is found when one is installed")
    func pythonDetectionFindsAnInterpreter() throws {
        guard let python = LedgerClient.findPython() else {
            Issue.record("No Python 3.11 or newer interpreter is available on this machine.")
            return
        }
        let version = LedgerClient.pythonVersion(python)
        #expect(version.0 >= 3)
        #expect(version.1 >= 11)
    }

    @Test("a missing interpreter is reported, not guessed")
    func missingInterpreterIsReportedNotGuessed() {
        #expect(LedgerClient.findPython(candidates: ["/nonexistent/python3"]) == nil)
    }

    @Test("applying without a ledger session is refused")
    func applyingWithoutALedgerSessionIsRefused() throws {
        let client = LedgerClient(
            database: URL(fileURLWithPath: "/tmp/osprey-test.sqlite"),
            coreRoot: nil,
            python: nil
        )
        let proposal = Proposal(
            kind: .checkpoint,
            terminalID: "t1",
            terminalTitle: "A tab",
            session: nil,
            task: nil,
            summary: "s",
            evidence: "e",
            next: "n"
        )
        var message = ""
        do {
            _ = try client.apply(proposal: proposal)
            Issue.record("Applying a proposal without a ledger session should fail.")
        } catch {
            message = "\(error)"
        }
        #expect(message.contains("not linked to a Taskrivet ledger session"))
    }
}
