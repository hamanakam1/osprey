import Foundation
import Testing
@testable import OspreyCore

/// An end-to-end check of the ledger client against a synthetic Taskrivet CLI.
///
/// The fixture under Tests/Fixtures/fake_taskrivet implements the small slice of
/// the Taskrivet command contract that Osprey uses, including the rule that a
/// cumulative token count cannot decrease. Nothing here touches a real ledger.
@Suite("Ledger round trip")
struct LedgerRoundTripTests {
    /// Builds a throwaway folder with the synthetic Taskrivet package in it.
    private func makeFixture() throws -> (core: URL, database: URL, python: String) {
        guard let python = LedgerClient.findPython() else {
            throw OspreyError.taskrivetUnavailable("No Python 3.11 or newer interpreter is available.")
        }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake_taskrivet", isDirectory: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("osprey-ledger-\(UUID().uuidString)", isDirectory: true)
        let core = scratch.appendingPathComponent("core", isDirectory: true)
        let package = core.appendingPathComponent("taskrivet", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        for name in ["__init__.py", "__main__.py"] {
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(name),
                to: package.appendingPathComponent(name)
            )
        }
        return (core, scratch.appendingPathComponent("ledger.sqlite"), python)
    }

    private func runTaskrivet(_ arguments: [String], core: URL, database: URL, python: String) throws -> [String: Any] {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = core.path
        let result = try LedgerClient.run(
            [python, "-m", "taskrivet", "--db", database.path] + arguments,
            environment: environment,
            workingDirectory: core,
            fileManager: .default
        )
        guard result.status == 0 else {
            let message = String(data: result.stderr, encoding: .utf8) ?? "unknown error"
            throw OspreyError.taskrivetUnavailable("The synthetic Taskrivet CLI failed: \(message)")
        }
        return try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] ?? [:]
    }

    @Test("a checkpoint is written and read back")
    func checkpointIsWrittenAndReadBack() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.core.deletingLastPathComponent()) }
        let core = fixture.core
        let database = fixture.database
        let python = fixture.python

        _ = try runTaskrivet([
            "task-add", "osprey-demo",
            "--objective", "Prove a checkpoint can be written",
            "--acceptance", "The ledger reads the checkpoint back",
            "--scope", "osprey-demo",
        ], core: core, database: database, python: python)
        let started = try runTaskrivet(
            ["start", "osprey-demo", "--owner", "osprey-test"],
            core: core, database: database, python: python
        )
        guard let sessionID = started["session_id"] as? String else {
            Issue.record("The synthetic ledger did not return a session id.")
            return
        }

        let client = LedgerClient(database: database, coreRoot: core, python: python)
        let proposal = Proposal(
            kind: .checkpoint,
            terminalID: "term-1",
            terminalTitle: "A tab",
            session: sessionID,
            task: "osprey-demo",
            summary: "Captured output shows the build was run.",
            evidence: "Osprey capture: 128 bytes across 12 lines.",
            next: "Operator to confirm the next step."
        )
        let result = try client.apply(proposal: proposal)
        if !result.verified {
            Issue.record("The ledger did not confirm the write: \(result.detail)")
        }
        #expect(result.verified)
        #expect(result.status == "active")

        let readback = try client.session(id: sessionID)
        #expect(readback != nil)
        #expect(readback?.status == "active")
    }

    @Test("a failure is written and read back")
    func failureIsWrittenAndReadBack() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.core.deletingLastPathComponent()) }
        let core = fixture.core
        let database = fixture.database
        let python = fixture.python

        _ = try runTaskrivet([
            "task-add", "osprey-fail",
            "--objective", "Prove a failure can be written",
            "--acceptance", "The ledger reads the failure back",
            "--scope", "osprey-fail",
        ], core: core, database: database, python: python)
        let started = try runTaskrivet(
            ["start", "osprey-fail", "--owner", "osprey-test"],
            core: core, database: database, python: python
        )
        guard let sessionID = started["session_id"] as? String else {
            Issue.record("The synthetic ledger did not return a session id.")
            return
        }

        let client = LedgerClient(database: database, coreRoot: core, python: python)
        let proposal = Proposal(
            kind: .failure,
            terminalID: "term-1",
            terminalTitle: "A tab",
            session: sessionID,
            task: "osprey-fail",
            summary: "Captured terminal output reported: error: no such module 'Foo'",
            evidence: "Osprey capture: 64 bytes of local capture.",
            next: "Operator to decide whether this failure needs a different approach.",
            category: "terminal_output"
        )
        let result = try client.apply(proposal: proposal)
        if !result.verified {
            Issue.record("The ledger did not confirm the write: \(result.detail)")
        }
        #expect(result.verified)
        let readback = try client.session(id: sessionID)
        #expect(readback?.status == "failed")
    }

    @Test("a reported token count is carried forward, never reset")
    func reportedTokenCountIsCarriedForward() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.core.deletingLastPathComponent()) }
        let core = fixture.core
        let database = fixture.database
        let python = fixture.python

        _ = try runTaskrivet([
            "task-add", "osprey-tokens",
            "--objective", "Prove the count is carried forward",
            "--acceptance", "The second checkpoint does not decrease the count",
            "--scope", "osprey-tokens",
        ], core: core, database: database, python: python)
        let started = try runTaskrivet(
            ["start", "osprey-tokens", "--owner", "osprey-test"],
            core: core, database: database, python: python
        )
        guard let sessionID = started["session_id"] as? String else {
            Issue.record("The synthetic ledger did not return a session id.")
            return
        }

        let client = LedgerClient(database: database, coreRoot: core, python: python)
        let first = try client.apply(
            proposal: Proposal(
                kind: .checkpoint,
                terminalID: "term-1",
                terminalTitle: "A tab",
                session: sessionID,
                task: "osprey-tokens",
                summary: "first",
                evidence: "evidence one",
                next: "next"
            ),
            tokens: 120
        )
        #expect(first.verified)
        #expect(first.tokens == 120)

        // No new count is stated, so Osprey carries the last reported one forward.
        let second = try client.apply(
            proposal: Proposal(
                kind: .checkpoint,
                terminalID: "term-1",
                terminalTitle: "A tab",
                session: sessionID,
                task: "osprey-tokens",
                summary: "second",
                evidence: "evidence two",
                next: "next"
            )
        )
        #expect(second.verified)
        #expect(second.tokens == 120)
        #expect(try client.session(id: sessionID)?.tokens == 120)
    }
}
