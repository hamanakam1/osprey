import Foundation
import Testing
@testable import OspreyCore

/// Proves the capture path end to end against a synthetic session service.
///
/// The fixture speaks the same socket protocol as the Taskrivet session
/// service and reports synthetic tabs, including one whose buffered output
/// contains a secret. The tests check redaction, proposal drafting and the
/// boundary between selected tabs and unrelated live events.
@Suite("Capture")
final class CaptureCoordinatorTests {
    private var scratch: URL!
    private var service: Process?
    private var store: EvidenceStore!

    init() throws {
        // A local socket path is limited to about 104 bytes, so the fixture
        // lives in a short folder rather than the long temporary directory.
        scratch = URL(fileURLWithPath: "/tmp/osprey-cap-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = try EvidenceStore(url: scratch.appendingPathComponent("evidence.sqlite"))
    }

    deinit {
        service?.terminate()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func startFixtureService(selectionScenario: Bool = false) throws -> URL {
        guard let python = LedgerClient.findPython() else {
            throw OspreyError.taskrivetUnavailable("No Python 3.11 or newer interpreter is available.")
        }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake_session_service.py")
        let runtime = scratch.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [fixture.path, runtime.path]
        if selectionScenario { process.arguments?.append("--selection") }
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        service = process

        // Wait for the socket to appear.
        let socket = TaskrivetLocator.sessionSocket(runtimeDirectory: runtime)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socket.path) { return socket }
            if !process.isRunning {
                let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "no output"
                throw OspreyError.taskrivetUnavailable("The synthetic session service stopped: \(message)")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw OspreyError.taskrivetUnavailable("The synthetic session service did not start.")
    }

    @Test("captured output is redacted, stored and drafted")
    func capturedOutputIsRedactedStoredAndDrafted() throws {
        let socket = try startFixtureService()
        let token = try SessionTokenReader.read(at: socket.deletingLastPathComponent().appendingPathComponent("token"))
        let client = TaskrivetSessionClient(socketURL: socket, token: token)

        var options = CaptureCoordinator.Options()
        options.seconds = 2
        let coordinator = CaptureCoordinator(store: store, client: client, options: options)
        let summary = try coordinator.run()

        #expect(summary.terminals.count == 1)
        #expect(summary.terminals.first?.id == "term-fixture-1")
        #expect(summary.recordsStored > 0)
        #expect(summary.redactions > 0)

        let stored = try store.evidence(forTerminal: "term-fixture-1")
        #expect(!stored.isEmpty)
        let all = stored.map(\.text).joined(separator: "\n")
        #expect(!all.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
        #expect(all.contains("[openai-key REDACTED]"))

        #expect(!summary.proposals.isEmpty)
        let proposal = try #require(summary.proposals.first)
        #expect(proposal.kind == .checkpoint)
        #expect(proposal.session == "ses_fixture")
        #expect(proposal.summary.contains("make build") == true)
        #expect(proposal.note?.contains("Not verified progress") == true)
    }

    @Test("named capture ignores other tabs and unknown or malformed event identifiers")
    func namedCaptureKeepsOnlySelectedTabs() throws {
        try assertCaptureSelection(
            ["term-fixture-1", "term-fixture-new"],
            expected: ["term-fixture-1"]
        )
    }

    @Test("default capture keeps only tabs that were running when listed")
    func defaultCaptureKeepsOnlyRunningTabs() throws {
        try assertCaptureSelection(nil, expected: ["term-fixture-1", "term-fixture-2"])
    }

    @Test("an empty selection keeps only tabs that were running when listed")
    func emptySelectionKeepsOnlyRunningTabs() throws {
        try assertCaptureSelection([], expected: ["term-fixture-1", "term-fixture-2"])
    }

    @Test("a stopped tab can still be selected explicitly")
    func namedCaptureCanKeepAStoppedTab() throws {
        try assertCaptureSelection(["term-fixture-stopped"], expected: ["term-fixture-stopped"])
    }

    private func assertCaptureSelection(_ terminalIDs: Set<String>?, expected: Set<String>) throws {
        let socket = try startFixtureService(selectionScenario: true)
        let token = try SessionTokenReader.read(at: socket.deletingLastPathComponent().appendingPathComponent("token"))
        let client = TaskrivetSessionClient(socketURL: socket, token: token)
        var options = CaptureCoordinator.Options()
        options.terminalIDs = terminalIDs
        options.seconds = 2
        let summary = try CaptureCoordinator(store: store, client: client, options: options).run()

        #expect(Set(summary.terminals.map(\.id)) == expected)
        #expect(Set(summary.proposals.map(\.terminalID)) == expected)
        #expect(Set(try store.proposals().map(\.terminalID)) == expected)

        var selectedRecordCount = 0
        for id in expected {
            let evidence = try store.evidence(forTerminal: id)
            selectedRecordCount += evidence.count
            let text = evidence.map(\.text).joined(separator: "\n")
            #expect(text.contains("live output from \(id)"))
        }
        // The reader omits malformed rows with empty terminal identifiers, so
        // check the raw row count as well as the per-terminal evidence.
        #expect(try store.evidenceCount() == selectedRecordCount)
        let emittedIDs: Set<String> = [
            "term-fixture-1", "term-fixture-2", "term-fixture-stopped", "term-fixture-new", "",
        ]
        for id in emittedIDs.subtracting(expected) {
            #expect(try store.evidence(forTerminal: id).isEmpty, "Unexpected evidence for terminal '\(id)'")
        }
    }

    @Test("a wrong token is refused")
    func aWrongTokenIsRefused() throws {
        let socket = try startFixtureService()
        let client = TaskrivetSessionClient(socketURL: socket, token: "not-the-token")
        #expect(throws: (any Error).self) {
            try client.connect()
        }
    }

    @Test("a token file that others can read is refused")
    func aReadableTokenFileIsRefused() throws {
        let socket = try startFixtureService()
        let tokenPath = socket.deletingLastPathComponent().appendingPathComponent("token")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenPath.path)
        #expect(throws: (any Error).self) {
            _ = try SessionTokenReader.read(at: tokenPath)
        }
    }
}
