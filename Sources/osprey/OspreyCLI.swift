import Foundation
import OspreyCore

/// The `osprey` command line.
///
/// Every command that changes something says so before it changes it, and
/// every command that fails explains what a person can do next.
struct OspreyCLI {
    let arguments: [String]
    private let out = FileHandle.standardOutput
    private let err = FileHandle.standardError

    init(arguments: [String]) {
        self.arguments = arguments
    }

    // MARK: - Dispatch

    func run() throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }
        let options = OptionSet(Array(arguments.dropFirst()))
        switch command {
        case "status": try runStatus(options)
        case "terminals": try runTerminals(options)
        case "capture": try runCapture(options)
        case "propose": try runPropose(options)
        case "proposals": try runProposals(options)
        case "show": try runShow(options)
        case "approve": try runApprove(options)
        case "withdraw": try runWithdraw(options)
        case "doctor": try runDoctor(options)
        case "redact": try runRedact(options)
        case "privacy": try runPrivacy(options)
        case "release": try runRelease(options)
        case "help", "--help", "-h": printHelp()
        case "version", "--version": printVersion()
        default:
            throw OspreyError.invalidInput("Unknown command '\(command)'. Run 'osprey help' for the command list.")
        }
    }

    // MARK: - Shared helpers

    private func database() -> URL { TaskrivetLocator.ledgerDatabase() }

    private func coreRoot() throws -> URL {
        guard let root = TaskrivetLocator.coreRoot() else {
            throw OspreyError.taskrivetUnavailable(
                "The Taskrivet Python core was not found. Set TASKRIVET_CORE to the folder that contains the taskrivet package. Looked in: "
                    + TaskrivetLocator.coreRootSearchPaths().map(\.path).joined(separator: ", ")
            )
        }
        return root
    }

    private func openStore() throws -> EvidenceStore {
        try OspreyPaths.ensureStateDirectory()
        return try EvidenceStore(url: OspreyPaths.evidenceDatabase())
    }

    private func sessionClient() throws -> TaskrivetSessionClient {
        let runtime = TaskrivetLocator.sessionRuntimeDirectory(database: database())
        let socket = TaskrivetLocator.sessionSocket(runtimeDirectory: runtime)
        let token = try SessionTokenReader.read(at: TaskrivetLocator.sessionToken(runtimeDirectory: runtime))
        return TaskrivetSessionClient(socketURL: socket, token: token)
    }

    private func print(_ text: String) {
        out.write(Data((text + "\n").utf8))
    }

    private func printJSON(_ object: Any) {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: options) {
            print(String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func printError(_ text: String) {
        err.write(Data(("osprey: " + text + "\n").utf8))
    }

    // MARK: - Commands

    private func runStatus(_ options: OptionSet) throws {
        let store = try openStore()
        let evidence = try store.evidenceCount()
        let pending = try store.proposals(state: .proposed)
        let applied = try store.proposals(state: .applied)

        var terminals: [TaskrivetTerminal] = []
        var serviceNote = "session service not reachable"
        if let client = try? sessionClient() {
            do {
                try client.connect()
                terminals = try client.list()
                serviceNote = "\(terminals.count) tab(s) owned by the session service"
                client.close()
            } catch {
                serviceNote = "session service not reachable: \(error)"
            }
        } else {
            serviceNote = "session service not reachable: no local token or socket"
        }

        let release = ReleaseManager()
        var buildNote = "no Taskrivet build found"
        if let report = try? release.verify(bundle: release.installedPath) {
            buildNote = "installed build \(report.version) (\(report.identifier))"
        }

        if options.flag("json") {
            printJSON([
                "evidence_records": evidence,
                "proposals_proposed": pending.count,
                "proposals_applied": applied.count,
                "terminals": terminals.map { ["id": $0.id, "title": $0.displayTitle, "state": $0.state, "task": $0.task ?? ""] },
                "service": serviceNote,
                "build": buildNote,
            ])
            return
        }

        print("OSPREY STATUS")
        print("  service   \(serviceNote)")
        print("  evidence  \(evidence) record(s) stored locally")
        print("  proposals \(pending.count) proposed, \(applied.count) applied")
        print("  build     \(buildNote)")
        if !pending.isEmpty {
            print("")
            print("  Pending proposals:")
            for proposal in pending {
                print("    \(proposal.id.prefix(8))  \(proposal.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))  \(proposal.terminalTitle)")
            }
            print("")
            print("  Nothing is written to the Taskrivet ledger until you approve a proposal.")
        }
    }

    private func runTerminals(_ options: OptionSet) throws {
        let client = try sessionClient()
        try client.connect()
        defer { client.close() }
        let terminals = try client.list()
        if options.flag("json") {
            printJSON(terminals.map { terminal in
                [
                    "id": terminal.id,
                    "title": terminal.displayTitle,
                    "cwd": terminal.cwd,
                    "state": terminal.state,
                    "task": terminal.task ?? "",
                    "ledger_session": terminal.session ?? "",
                    "kind": terminal.kind ?? "shell",
                ]
            })
            return
        }
        guard !terminals.isEmpty else {
            print("The Taskrivet session service owns no tabs right now.")
            return
        }
        print("TASKRIVET TABS")
        for terminal in terminals {
            let task = terminal.task ?? "unassigned"
            let session = terminal.session ?? "no ledger session"
            print("  \(terminal.id.prefix(8))  \(terminal.state.padding(toLength: 8, withPad: " ", startingAt: 0))  \(terminal.displayTitle)")
            print("             task: \(task)   ledger: \(session)")
            print("             folder: \(terminal.cwd)")
        }
    }

    private func runCapture(_ options: OptionSet) throws {
        let requested = options.repeated("terminal")
        let seconds = options.integer("seconds", default: 5)
        let dryRun = options.flag("dry-run")

        let client = try sessionClient()
        let store = dryRun ? nil : try openStore()
        var captureOptions = CaptureCoordinator.Options()
        captureOptions.seconds = seconds
        if !requested.isEmpty && !options.flag("all") {
            captureOptions.terminalIDs = Set(requested)
        }

        guard let store else {
            // Dry run: show the redaction preview without writing anything.
            try client.connect()
            defer { client.close() }
            let terminals = try client.list()
            let selected = requested.isEmpty ? terminals : terminals.filter { requested.contains($0.id) }
            var redactor = Redactor()
            for terminal in selected {
                let text = (terminal.chunks ?? []).map(\.data).joined()
                let clean = redactor.redact(text)
                print("── \(terminal.displayTitle) [\(terminal.id)]")
                print(clean.isEmpty ? "   (no buffered output)" : clean)
            }
            print("")
            print("Dry run: nothing was stored. \(redactor.replacements) secret-shaped value(s) would be redacted.")
            return
        }

        let coordinator = CaptureCoordinator(store: store, client: client, options: captureOptions)
        let summary = try coordinator.run()
        if options.flag("json") {
            printJSON([
                "tabs": summary.terminals.map(\.id),
                "records_stored": summary.recordsStored,
                "bytes": summary.bytesRedacted,
                "redactions": summary.redactions,
                "proposals": summary.proposals.map(\.id),
            ])
            return
        }
        print("CAPTURE")
        print("  tabs        \(summary.terminals.count)")
        print("  records     \(summary.recordsStored) stored locally")
        print("  bytes       \(summary.bytesRedacted)")
        print("  redactions  \(summary.redactions) secret-shaped value(s) removed")
        print("  proposals   \(summary.proposals.count) drafted")
        for proposal in summary.proposals {
            print("    \(proposal.id.prefix(8))  \(proposal.kind.rawValue)  \(proposal.terminalTitle)")
        }
        print("")
        print("Nothing was written to the Taskrivet ledger. Review the proposals, then approve one.")
    }

    private func runPropose(_ options: OptionSet) throws {
        let store = try openStore()
        let engine = ProposalEngine()
        let terminals = (try? sessionClient().list()) ?? []
        let requested = options.repeated("terminal")

        var drafted: [Proposal] = []
        var sources: [(TaskrivetTerminal, [EvidenceRecord])] = []
        if terminals.isEmpty {
            // Fall back to the terminals recorded in the evidence store.
            let records = try store.recentEvidence(limit: 2000)
            var grouped: [String: [EvidenceRecord]] = [:]
            for record in records { grouped[record.terminalID, default: []].append(record) }
            for (terminalID, evidence) in grouped where requested.isEmpty || requested.contains(terminalID) {
                let terminal = TaskrivetTerminal(id: terminalID, cwd: "unknown")
                sources.append((terminal, evidence))
            }
        } else {
            for terminal in terminals where requested.isEmpty || requested.contains(terminal.id) {
                let evidence = try store.evidence(forTerminal: terminal.id)
                guard !evidence.isEmpty else { continue }
                sources.append((terminal, evidence))
            }
        }

        for (terminal, evidence) in sources {
            if let proposal = engine.checkpointProposal(terminal: terminal, evidence: evidence) {
                try store.save(proposal)
                drafted.append(proposal)
            }
            if let failure = engine.failureProposal(terminal: terminal, evidence: evidence) {
                try store.save(failure)
                drafted.append(failure)
            }
        }

        if options.flag("json") {
            printJSON(drafted.map { ["id": $0.id, "kind": $0.kind.rawValue, "terminal": $0.terminalTitle, "summary": $0.summary] })
            return
        }
        print("DRAFTED \(drafted.count) PROPOSAL(S)")
        for proposal in drafted {
            print("  \(proposal.id)  \(proposal.kind.rawValue)")
            print("    \(proposal.summary)")
        }
        if drafted.isEmpty {
            print("  Nothing to draft. Run 'osprey capture' first so there is evidence to read.")
        }
    }

    private func runProposals(_ options: OptionSet) throws {
        let store = try openStore()
        let state: ProposalState?
        switch options.value("state") ?? "proposed" {
        case "all": state = nil
        case let raw: state = ProposalState(rawValue: raw)
        }
        if state == nil, options.value("state") != "all", options.value("state") != nil {
            throw OspreyError.invalidInput("Unknown proposal state. Use proposed, applied, failed, withdrawn, or all.")
        }
        let proposals = try store.proposals(state: state)
        if options.flag("json") {
            printJSON(proposals.map { proposal in
                [
                    "id": proposal.id,
                    "kind": proposal.kind.rawValue,
                    "state": proposal.state.rawValue,
                    "terminal": proposal.terminalTitle,
                    "session": proposal.session ?? "",
                    "summary": proposal.summary,
                    "created": proposal.createdAt.formatted(.iso8601),
                ]
            })
            return
        }
        guard !proposals.isEmpty else {
            print("No proposals are in that state.")
            return
        }
        for proposal in proposals {
            print("\(proposal.id)  \(proposal.state.rawValue)  \(proposal.kind.rawValue)  \(proposal.terminalTitle)")
            print("  \(proposal.summary)")
            if let note = proposal.note { print("  note: \(note)") }
        }
    }

    private func runShow(_ options: OptionSet) throws {
        guard let id = options.positional.first else {
            throw OspreyError.invalidInput("Give the proposal id: osprey show <proposal-id>")
        }
        let store = try openStore()
        guard let proposal = try store.proposal(id: id) else {
            throw OspreyError.invalidInput("No proposal with id \(id).")
        }
        printJSON([
            "id": proposal.id,
            "kind": proposal.kind.rawValue,
            "state": proposal.state.rawValue,
            "terminal_id": proposal.terminalID,
            "terminal_title": proposal.terminalTitle,
            "ledger_session": proposal.session ?? "",
            "task": proposal.task ?? "",
            "summary": proposal.summary,
            "evidence": proposal.evidence,
            "next": proposal.next,
            "category": proposal.category ?? "",
            "tokens": proposal.tokens,
            "created_at": proposal.createdAt.formatted(.iso8601),
            "note": proposal.note ?? "",
        ])
    }

    private func runApprove(_ options: OptionSet) throws {
        guard let id = options.positional.first else {
            throw OspreyError.invalidInput("Give the proposal id: osprey approve <proposal-id>")
        }
        let store = try openStore()
        guard let proposal = try store.proposal(id: id) else {
            throw OspreyError.invalidInput("No proposal with id \(id).")
        }
        guard proposal.state == .proposed else {
            throw OspreyError.invalidInput("Proposal \(id) is already \(proposal.state.rawValue).")
        }
        guard proposal.session != nil else {
            throw OspreyError.notApplicable(
                "This terminal is not linked to a Taskrivet ledger session, so there is no record to write. Open the terminal with a task assignment first."
            )
        }
        if !options.flag("yes") {
            print("About to write this record to the Taskrivet ledger:")
            print("  kind    \(proposal.kind.rawValue)")
            print("  session \(proposal.session ?? "")")
            print("  summary \(proposal.summary)")
            print("")
            print("Re-run with --yes to apply it, or --tokens N to state the cumulative reported token count.")
            return
        }

        let ledger = LedgerClient(database: database(), coreRoot: TaskrivetLocator.coreRoot())
        let result = try ledger.apply(proposal: proposal, tokens: options.value("tokens").flatMap(Int.init))
        try store.setProposalState(id: id, state: result.verified ? .applied : .failed, note: result.detail)
        print(result.detail)
        if !result.verified {
            printError("The write was not confirmed by a ledger readback. The proposal is marked failed.")
            exit(2)
        }
    }

    private func runWithdraw(_ options: OptionSet) throws {
        guard let id = options.positional.first else {
            throw OspreyError.invalidInput("Give the proposal id: osprey withdraw <proposal-id>")
        }
        let store = try openStore()
        guard try store.proposal(id: id) != nil else {
            throw OspreyError.invalidInput("No proposal with id \(id).")
        }
        let reason = options.value("reason") ?? "withdrawn by the operator"
        try store.setProposalState(id: id, state: .withdrawn, note: reason)
        print("Proposal \(id) withdrawn. Nothing was written to the Taskrivet ledger.")
    }

    private func runDoctor(_ options: OptionSet) throws {
        var lines: [[String: String]] = []
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            lines.append(["check": name, "status": ok ? "ok" : "attention", "detail": detail])
        }

        if let python = LedgerClient.findPython() {
            let version = LedgerClient.pythonVersion(python)
            check("python", true, "\(python) (\(version.0).\(version.1))")
        } else {
            check("python", false, "Python 3.11 or newer was not found.")
        }

        if let root = TaskrivetLocator.coreRoot() {
            check("taskrivet-core", true, root.path)
        } else {
            check("taskrivet-core", false, "Set TASKRIVET_CORE to the folder that contains the taskrivet package.")
        }

        let runtime = TaskrivetLocator.sessionRuntimeDirectory(database: database())
        let socket = TaskrivetLocator.sessionSocket(runtimeDirectory: runtime)
        check("session-socket", FileManager.default.fileExists(atPath: socket.path), socket.path)

        do {
            let token = try SessionTokenReader.read(at: TaskrivetLocator.sessionToken(runtimeDirectory: runtime))
            check("session-token", true, "read a \(token.count) character private token")
        } catch {
            check("session-token", false, "\(error)")
        }

        do {
            let store = try openStore()
            let count = try store.evidenceCount()
            check("evidence-store", true, "\(store.url.path) with \(count) record(s)")
        } catch {
            check("evidence-store", false, "\(error)")
        }

        let release = ReleaseManager()
        if let report = try? release.verify(bundle: release.installedPath) {
            check("taskrivet-build", report.isUsable, "\(report.version) at \(report.path)")
        } else {
            check("taskrivet-build", false, "no readable Taskrivet build in \(release.installedPath.path)")
        }

        if options.flag("json") {
            printJSON(lines)
            return
        }
        print("OSPREY DOCTOR")
        for line in lines {
            let mark = line["status"] == "ok" ? "✓" : "!"
            print("  \(mark) \(line["check"] ?? ""): \(line["detail"] ?? "")")
        }
    }

    private func runRedact(_ options: OptionSet) throws {
        let text = options.positional.joined(separator: " ")
        guard !text.isEmpty else {
            throw OspreyError.invalidInput("Give some text: osprey redact \"export KEY=abc123\"")
        }
        var redactor = Redactor()
        let clean = redactor.redact(text)
        print(clean)
        print("")
        print("\(redactor.replacements) secret-shaped value(s) redacted.")
    }

    private func runPrivacy(_ options: OptionSet) throws {
        guard options.positional.first == "purge" else {
            throw OspreyError.invalidInput("The only privacy command is 'osprey privacy purge'.")
        }
        let days = options.integer("older-than", default: 7)
        let store = try openStore()
        let cutoff = Date().addingTimeInterval(-TimeInterval(days * 86_400))
        let removed = try store.prune(olderThan: cutoff)
        print("Removed \(removed) evidence record(s) older than \(days) day(s).")
        print("Proposals are kept until they are applied or withdrawn.")
    }

    private func runRelease(_ options: OptionSet) throws {
        let release = ReleaseManager()
        switch options.positional.first {
        case "verify":
            guard let bundle = options.value("bundle") else {
                throw OspreyError.invalidInput("Give the bundle path: osprey release verify --bundle /path/to/Taskrivet.app")
            }
            let report = try release.verify(bundle: URL(fileURLWithPath: bundle))
            if options.flag("json") {
                printJSON([
                    "path": report.path,
                    "identifier": report.identifier,
                    "version": report.version,
                    "build": report.build,
                    "executable": report.executablePresent,
                    "core": report.corePresent,
                    "problems": report.problems,
                ])
            } else {
                print("BUNDLE \(report.path)")
                print("  identifier \(report.identifier)")
                print("  version    \(report.version) (\(report.build))")
                print("  executable \(report.executablePresent ? "present" : "missing")")
                print("  core       \(report.corePresent ? "present" : "missing")")
                for problem in report.problems { print("  problem    \(problem)") }
            }
            if !report.isUsable { exit(2) }
        case "install":
            guard let bundle = options.value("bundle") else {
                throw OspreyError.invalidInput("Give the bundle path: osprey release install --bundle /path/to/Taskrivet.app")
            }
            let outcome = try release.install(bundle: URL(fileURLWithPath: bundle), runSmokeTest: !options.flag("no-smoke-test"))
            try openStore().append(
                ReleaseReceipt(
                    action: outcome.rolledBack ? .rolledBack : .installed,
                    version: (try? release.verify(bundle: URL(fileURLWithPath: bundle)).version) ?? "unknown",
                    source: bundle,
                    backupPath: outcome.backupPath,
                    installedPath: outcome.installedPath,
                    smokeTest: outcome.smokeTestPassed ? "passed" : "not run",
                    detail: outcome.detail
                )
            )
            print(outcome.detail)
            if !outcome.smokeTestPassed { exit(2) }
        case "rollback":
            let backup = options.value("backup").map { URL(fileURLWithPath: $0) }
            let outcome = try release.rollback(backup: backup)
            print(outcome.detail)
        case "backups":
            let backups = release.listBackups()
            if backups.isEmpty {
                print("No Taskrivet backups were found.")
            } else {
                for backup in backups { print("  \(backup.path)") }
            }
        case "receipts":
            let receipts = try openStore().receipts()
            if receipts.isEmpty {
                print("No release receipts yet.")
            } else {
                for receipt in receipts {
                    print("  \(receipt.occurredAt.formatted(.iso8601))  \(receipt.action.rawValue)  \(receipt.version)")
                    print("    \(receipt.detail)")
                }
            }
        default:
            throw OspreyError.invalidInput("Use verify, install, rollback, backups, or receipts.")
        }
    }

    // MARK: - Help

    private func printVersion() {
        print("osprey 0.1.0")
    }

    private func printHelp() {
        print("""
        OSPREY 0.1.0 — local supervisor for the Taskrivet desktop app

        USAGE
          osprey <command> [options]

        WORK CAPTURE
          status                       Tabs, stored evidence, pending proposals, installed build
          terminals                    List the Taskrivet tabs the session service owns
          capture                      Read tab output, redact it, store it, draft records
                                     --terminal <id> (repeatable)  --all  --seconds <n>  --dry-run
          propose                      Draft proposals from stored evidence
          proposals                    List proposals   --state proposed|applied|failed|withdrawn|all
          show <proposal-id>           Show one proposal in full
          approve <proposal-id>        Write an approved record to the Taskrivet ledger
                                     --tokens <n>  --yes
          withdraw <proposal-id>       Drop a proposal   --reason <text>

        RELEASE SUPERVISION
          release verify --bundle <path>
          release install --bundle <path>   [--no-smoke-test]
          release rollback                 [--backup <path>]
          release backups
          release receipts

        HOUSEKEEPING
          doctor                       Check python, core, socket, token, store, build
          redact <text>                 Show what redaction does
          privacy purge                 [--older-than <days>]
          help                          This text
          version

        Osprey proposes. It never decides that work happened, and it never
        writes to the Taskrivet ledger without an explicit approval.
        """)
    }
}
