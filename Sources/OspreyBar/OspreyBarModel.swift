import Combine
import Foundation
import OspreyCore

/// The state behind the Osprey menu-bar item.
///
/// Everything the model does is local: it reads the Osprey SQLite store and,
/// only when a person clicks Approve, writes to the Taskrivet ledger. Nothing
/// is sent anywhere and nothing is approved on its own.
final class OspreyBarModel: ObservableObject {

    /// The outcome of one Approve or Withdraw click.
    struct Action: Identifiable {
        enum Outcome {
            case success(String)
            case failure(String)
        }

        let id = UUID()
        let proposalID: String
        let outcome: Outcome
        let when: Date

        var message: String {
            switch outcome {
            case .success(let text), .failure(let text): return text
            }
        }

        var isFailure: Bool {
            if case .failure = outcome { return true }
            return false
        }
    }

    // MARK: - Published state

    @Published private(set) var pending: [Proposal] = []
    @Published private(set) var evidenceCount: Int = 0
    @Published private(set) var bundleVersion: String = "not installed"
    @Published private(set) var bundleNote: String?
    @Published private(set) var actions: [Action] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var busyProposalIDs: Set<String> = []

    // MARK: - Private state

    private let fileManager = FileManager.default
    /// Work that touches the disk happens here, so the menu stays responsive.
    private let queue = DispatchQueue(label: "osprey.bar.work", qos: .userInitiated)
    /// Only read and written on `queue`.
    private var cachedReleaseManager: ReleaseManager?

    init() {
        refresh()
    }

    // MARK: - Derived values

    var pendingCount: Int { pending.count }

    /// The latest outcome recorded for one proposal, if any.
    func action(for proposalID: String) -> Action? {
        actions.first { $0.proposalID == proposalID }
    }

    /// Outcomes for proposals that are no longer waiting for review, such as a
    /// successful approval, so the message survives the row leaving the list.
    var detachedActions: [Action] {
        let pendingIDs = Set(pending.map(\.id))
        return actions.filter { !pendingIDs.contains($0.proposalID) }
    }

    func isBusy(_ proposalID: String) -> Bool {
        busyProposalIDs.contains(proposalID)
    }

    /// The menu-bar icon reflects whether anything needs a person.
    var statusSymbol: String {
        if statusMessage != nil { return "exclamationmark.triangle.fill" }
        return pendingCount > 0 ? "bird.fill" : "bird"
    }

    // MARK: - Reading

    /// Re-reads the store. Safe to call at any time; it never writes.
    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.loadSnapshot()
            DispatchQueue.main.async {
                self.statusMessage = snapshot.failure
                self.pending = snapshot.pending
                self.evidenceCount = snapshot.evidenceCount
                self.bundleVersion = snapshot.bundleVersion
                self.bundleNote = snapshot.bundleNote
            }
        }
    }

    // MARK: - Acting

    /// Approves one proposal. Only ever called from an explicit button click.
    func approve(_ proposal: Proposal) {
        guard proposal.isApplicable else {
            record(proposalID: proposal.id, outcome: .failure(
                "No Taskrivet ledger session is linked to this terminal, so there is no record to write."
            ))
            return
        }
        run(proposal: proposal, work: self.performApprove)
    }

    /// Withdraws one proposal. Writes to the Osprey store only.
    func withdraw(_ proposal: Proposal) {
        run(proposal: proposal, work: self.performWithdraw)
    }

    /// Runs one action off the main thread and then reports the outcome.
    private func run(proposal: Proposal, work: @escaping (Proposal) -> Action.Outcome) {
        setBusy(proposal.id, true)
        queue.async { [weak self] in
            guard let self else { return }
            let outcome = work(proposal)
            DispatchQueue.main.async {
                self.setBusy(proposal.id, false)
                self.record(proposalID: proposal.id, outcome: outcome)
                self.refresh()
            }
        }
    }

    // MARK: - Work on the queue

    private struct Snapshot {
        var pending: [Proposal] = []
        var evidenceCount = 0
        var bundleVersion = "not installed"
        var bundleNote: String?
        var failure: String?
    }

    private func loadSnapshot() -> Snapshot {
        var snapshot = Snapshot()
        do {
            let store = try openStore()
            snapshot.pending = try store.proposals(state: .proposed)
            snapshot.evidenceCount = try store.evidenceCount()
        } catch {
            snapshot.pending = []
            snapshot.evidenceCount = 0
            snapshot.failure = "Could not read the Osprey store: \(describe(error))"
        }
        let bundle = bundleReport()
        snapshot.bundleVersion = bundle.version
        snapshot.bundleNote = bundle.note
        return snapshot
    }

    private func performApprove(_ proposal: Proposal) -> Action.Outcome {
        let result: LedgerClient.ApplyResult
        do {
            let client = LedgerClient(
                database: TaskrivetLocator.ledgerDatabase(fileManager: fileManager),
                coreRoot: TaskrivetLocator.coreRoot(fileManager: fileManager),
                fileManager: fileManager
            )
            result = try client.apply(proposal: proposal)
        } catch {
            return .failure(describe(error))
        }
        do {
            let store = try openStore()
            let note = "Approved from the Osprey menu bar on \(Self.timestamp())."
            _ = try store.setProposalState(id: proposal.id, state: .applied, note: note)
        } catch {
            return .failure(
                "The ledger accepted the record, but the Osprey store could not be updated: \(describe(error))"
            )
        }
        if result.verified {
            return .success("Applied to session \(result.sessionID). \(result.detail)")
        }
        return .success(
            "Written to session \(result.sessionID) (status \(result.status)), but not verified. \(result.detail)"
        )
    }

    private func performWithdraw(_ proposal: Proposal) -> Action.Outcome {
        do {
            let store = try openStore()
            let updated = try store.setProposalState(
                id: proposal.id,
                state: .withdrawn,
                note: "Withdrawn from the Osprey menu bar on \(Self.timestamp())."
            )
            guard updated != nil else {
                return .failure("That proposal is no longer in the Osprey store.")
            }
            return .success("Withdrawn. Nothing was written to the Taskrivet ledger.")
        } catch {
            return .failure(describe(error))
        }
    }

    // MARK: - Helpers

    private func openStore() throws -> EvidenceStore {
        try OspreyPaths.ensureStateDirectory(fileManager: fileManager)
        return try EvidenceStore(url: OspreyPaths.evidenceDatabase(fileManager: fileManager))
    }

    /// Reads the installed Taskrivet bundle. Any failure means "not installed".
    private func bundleReport() -> (version: String, note: String?) {
        let bundle = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Taskrivet.app", isDirectory: true)
        let manager: ReleaseManager
        if let cached = cachedReleaseManager {
            manager = cached
        } else {
            manager = ReleaseManager(fileManager: fileManager)
            cachedReleaseManager = manager
        }
        do {
            let report = try manager.verify(bundle: bundle)
            if report.problems.isEmpty {
                return (report.version, "build \(report.build)")
            }
            return (report.version, report.problems.joined(separator: "; "))
        } catch {
            return ("not installed", nil)
        }
    }

    private func record(proposalID: String, outcome: Action.Outcome) {
        actions.removeAll { $0.proposalID == proposalID }
        actions.insert(Action(proposalID: proposalID, outcome: outcome, when: Date()), at: 0)
        if actions.count > 20 { actions.removeLast(actions.count - 20) }
    }

    private func setBusy(_ proposalID: String, _ busy: Bool) {
        if busy {
            busyProposalIDs.insert(proposalID)
        } else {
            busyProposalIDs.remove(proposalID)
        }
    }

    /// OspreyCore's errors carry their own `description`, so this shows the
    /// operator the reason Osprey wrote down rather than a generic failure.
    private func describe(_ error: Error) -> String {
        let text = String(describing: error)
        return text.isEmpty ? error.localizedDescription : text
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
