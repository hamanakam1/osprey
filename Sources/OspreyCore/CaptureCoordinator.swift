import Foundation

/// Captures terminal output from the Taskrivet session service and turns it
/// into draft records.
///
/// The order is deliberate: read, redact, store, then propose. Nothing is
/// written to the Taskrivet ledger by this type.
public final class CaptureCoordinator {
    public struct Options: Sendable {
        /// Which tabs to capture. `nil` means every running tab.
        public var terminalIDs: Set<String>?
        /// How long to follow live output, in seconds.
        public var seconds: Int = 5
        /// The most output Osprey will keep per terminal, in bytes.
        public var maxBytesPerTerminal: Int = 256_000
        /// The most evidence records Osprey will store per terminal.
        public var maxRecordsPerTerminal: Int = 400
        public init() {}
    }

    public struct Summary: Sendable {
        public let terminals: [TaskrivetTerminal]
        public let recordsStored: Int
        public let bytesRedacted: Int
        public let redactions: Int
        public let proposals: [Proposal]
    }

    private let store: EvidenceStore
    private let client: TaskrivetSessionClient
    private let engine: ProposalEngine
    private let options: Options
    private let lock = NSLock()
    private var live: [String: String] = [:]
    private var liveBytes: [String: Int] = [:]
    private var liveRedactions: [String: Int] = [:]

    public init(
        store: EvidenceStore,
        client: TaskrivetSessionClient,
        engine: ProposalEngine = ProposalEngine(),
        options: Options = Options()
    ) {
        self.store = store
        self.client = client
        self.engine = engine
        self.options = options
    }

    /// Reads the selected tabs, stores redacted evidence, and drafts records.
    public func run() throws -> Summary {
        try client.connect()
        defer { client.close() }

        let all = try client.list()
        let selected = selectTerminals(from: all)
        guard !selected.isEmpty else {
            throw OspreyError.invalidInput("No Taskrivet tabs matched the selection, so nothing was captured.")
        }

        var stored = 0
        var bytes = 0
        var redactions = 0

        for terminal in selected {
            // The service keeps a bounded tail per tab. Capture it first so a
            // proposal can be drafted even when nothing new arrives.
            let buffered = bufferedText(for: terminal)
            if !buffered.isEmpty {
                let (text, count) = redact(buffered)
                let record = EvidenceRecord(
                    terminalID: terminal.id,
                    text: text,
                    bytes: text.utf8.count,
                    redactions: count
                )
                try store.append(record)
                stored += 1
                bytes += record.bytes
                redactions += count
            }
        }

        client.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .data(let terminalID, _, let text):
                self.lock.lock()
                var combined = (self.live[terminalID] ?? "") + text
                if combined.utf8.count > self.options.maxBytesPerTerminal {
                    combined = String(combined.suffix(self.options.maxBytesPerTerminal))
                }
                self.live[terminalID] = combined
                self.liveBytes[terminalID] = (self.liveBytes[terminalID] ?? 0) + text.utf8.count
                self.lock.unlock()
            case .exit:
                break
            }
        }

        let deadline = Date().addingTimeInterval(TimeInterval(max(0, options.seconds)))
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }

        lock.lock()
        let pending = live
        let pendingBytes = liveBytes
        let pendingRedactions = liveRedactions
        live.removeAll()
        liveBytes.removeAll()
        liveRedactions.removeAll()
        lock.unlock()

        for (terminalID, text) in pending {
            guard !text.isEmpty else { continue }
            let (clean, count) = redact(text)
            let record = EvidenceRecord(
                terminalID: terminalID,
                text: clean,
                bytes: clean.utf8.count,
                redactions: count
            )
            try store.append(record)
            stored += 1
            bytes += record.bytes
            redactions += count
            _ = pendingBytes[terminalID]
            _ = pendingRedactions[terminalID]
        }

        var proposals: [Proposal] = []
        for terminal in selected {
            let evidence = try store.evidence(forTerminal: terminal.id, limit: options.maxRecordsPerTerminal)
            if let proposal = engine.checkpointProposal(terminal: terminal, evidence: evidence) {
                try store.save(proposal)
                proposals.append(proposal)
            }
            if let failure = engine.failureProposal(terminal: terminal, evidence: evidence) {
                try store.save(failure)
                proposals.append(failure)
            }
        }

        return Summary(
            terminals: selected,
            recordsStored: stored,
            bytesRedacted: bytes,
            redactions: redactions,
            proposals: proposals
        )
    }

    private func selectTerminals(from all: [TaskrivetTerminal]) -> [TaskrivetTerminal] {
        guard let wanted = options.terminalIDs else {
            return all.filter(\.isRunning)
        }
        if wanted.isEmpty { return all.filter(\.isRunning) }
        return all.filter { wanted.contains($0.id) }
    }

    private func bufferedText(for terminal: TaskrivetTerminal) -> String {
        // The service snapshot keeps a bounded chunk list per tab.
        guard let chunks = terminal.chunks, !chunks.isEmpty else { return "" }
        let text = chunks.map(\.data).joined()
        if text.utf8.count > options.maxBytesPerTerminal {
            return String(text.suffix(options.maxBytesPerTerminal))
        }
        return text
    }

    private func redact(_ text: String) -> (String, Int) {
        var redactor = Redactor()
        let clean = redactor.redact(text)
        return (clean, redactor.replacements)
    }
}
