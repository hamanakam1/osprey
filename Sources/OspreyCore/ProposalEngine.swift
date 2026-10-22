import Foundation

/// Turns captured terminal output into a draft Taskrivet record.
///
/// Osprey does not decide that work happened. It reads what a terminal printed
/// and proposes a record an operator can accept, edit, or throw away. Every
/// proposal says where it came from and what it did not measure.
public struct ProposalEngine: Sendable {
    public struct Options: Sendable {
        /// How many characters of command output may appear in a summary.
        public var summaryCharacterLimit: Int = 240
        /// How many characters of captured text may be cited as evidence.
        public var evidenceCharacterLimit: Int = 400
        /// The maximum number of command lines a summary may quote.
        public var quotedCommands: Int = 3
        public init() {}
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Summarises one terminal's captured output.
    public func digest(for terminalID: String, evidence: [EvidenceRecord]) -> TerminalDigest {
        let text = evidence.map(\.text).joined(separator: "\n")
        return TerminalDigest(
            terminalID: terminalID,
            bytes: evidence.reduce(0) { $0 + $1.bytes },
            lines: text.split(separator: "\n", omittingEmptySubsequences: true).count,
            commands: Redactor.commandCandidates(in: text),
            failures: Redactor.failureCandidates(in: text),
            redactions: evidence.reduce(0) { $0 + $1.redactions }
        )
    }

    /// Builds a checkpoint proposal, or nil when there is nothing to propose.
    public func checkpointProposal(
        terminal: TaskrivetTerminal,
        evidence: [EvidenceRecord]
    ) -> Proposal? {
        let digest = digest(for: terminal.id, evidence: evidence)
        guard digest.bytes > 0 else { return nil }

        var summaryParts: [String] = []
        if !digest.commands.isEmpty {
            let quoted = digest.commands.suffix(options.quotedCommands).joined(separator: "; ")
            summaryParts.append("Terminal output shows: \(quoted)")
        } else {
            summaryParts.append("Terminal produced \(digest.bytes) bytes of output with no recognisable command line.")
        }
        if !digest.failures.isEmpty {
            summaryParts.append("Failure text present: \(digest.failures.first ?? "")")
        }
        let summary = String(summaryParts.joined(separator: " ").prefix(options.summaryCharacterLimit))

        let evidenceText = String(
            """
            Osprey capture: terminal \(terminal.id) (\(terminal.displayTitle)) in \(terminal.cwd); \
            \(digest.bytes) bytes across \(digest.lines) lines; \(digest.redactions) redaction(s) applied; \
            captured \(evidence.first?.capturedAt.formatted(.iso8601) ?? "unknown") to \
            \(evidence.last?.capturedAt.formatted(.iso8601) ?? "unknown"). \
            Redacted capture retained locally by Osprey. Reported token usage is not measured by Osprey.
            """.prefix(options.evidenceCharacterLimit)
        )

        return Proposal(
            kind: .checkpoint,
            terminalID: terminal.id,
            terminalTitle: terminal.displayTitle,
            session: terminal.session,
            task: terminal.task,
            summary: summary,
            evidence: evidenceText,
            next: "Operator to confirm the next step for this task.",
            tokens: 0,
            note: "Drafted from terminal output. Not verified progress, and not a claim that the task is complete."
        )
    }

    /// Builds a failure proposal when the output contains failure text.
    public func failureProposal(
        terminal: TaskrivetTerminal,
        evidence: [EvidenceRecord]
    ) -> Proposal? {
        let digest = digest(for: terminal.id, evidence: evidence)
        guard let first = digest.failures.first else { return nil }
        let summary = String("Captured terminal output reported: \(first)".prefix(options.summaryCharacterLimit))
        let evidenceText = String(
            """
            Osprey capture: terminal \(terminal.id) (\(terminal.displayTitle)); \
            \(digest.failures.count) failure line(s) observed in \(digest.bytes) bytes of local capture; \
            \(digest.redactions) redaction(s) applied.
            """.prefix(options.evidenceCharacterLimit)
        )
        return Proposal(
            kind: .failure,
            terminalID: terminal.id,
            terminalTitle: terminal.displayTitle,
            session: terminal.session,
            task: terminal.task,
            summary: summary,
            evidence: evidenceText,
            next: "Operator to decide whether this failure needs a different approach.",
            category: "terminal_output",
            tokens: 0,
            note: "Drafted from terminal output. A recorded failure is not a diagnosis."
        )
    }
}
