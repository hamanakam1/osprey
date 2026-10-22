import OspreyCore
import SwiftUI

/// The panel shown when the Osprey menu-bar item is opened.
struct OspreyMenuView: View {
    @EnvironmentObject private var model: OspreyBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let status = model.statusMessage {
                messageRow(status, isFailure: true)
            }
            Divider()
            proposals
            if !model.detachedActions.isEmpty {
                Divider()
                recentActions
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 380)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Osprey").font(.headline)
                Text("Taskrivet supervisor").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.pendingCount) pending")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.pendingCount > 0 ? .primary : .secondary)
            }
            HStack(spacing: 10) {
                Text("Evidence: \(model.evidenceCount)").font(.caption).foregroundStyle(.secondary)
                Text("Taskrivet: \(model.bundleVersion)").font(.caption).foregroundStyle(.secondary)
            }
            if let note = model.bundleNote {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var proposals: some View {
        if model.pending.isEmpty {
            Text("No proposals are waiting for review.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.pending) { proposal in
                    proposalRow(proposal)
                }
            }
        }
    }

    private func proposalRow(_ proposal: Proposal) -> some View {
        let style = kindStyle(for: proposal.kind)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: style.symbol).foregroundStyle(style.tint)
                Text(proposal.terminalTitle.isEmpty ? "Untitled terminal" : proposal.terminalTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(proposal.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
            Text(oneLine(proposal.summary)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 8) {
                Button("Approve") { model.approve(proposal) }
                    .disabled(!proposal.isApplicable || model.isBusy(proposal.id))
                Button("Withdraw") { model.withdraw(proposal) }
                    .disabled(model.isBusy(proposal.id))
                if model.isBusy(proposal.id) { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.borderless)
            if !proposal.isApplicable {
                Text("No Taskrivet ledger session is linked to this terminal, so there is no record to write.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let action = model.action(for: proposal.id) {
                messageRow(action.message, isFailure: action.isFailure)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var recentActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent actions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(model.detachedActions.prefix(5)) { action in
                messageRow(action.message, isFailure: action.isFailure)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderless)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless)
        }
    }

    // MARK: - Small helpers

    private func messageRow(_ text: String, isFailure: Bool) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: isFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isFailure ? Color.red : Color.green)
            Text(text).font(.caption2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func kindStyle(for kind: ProposalKind) -> (symbol: String, tint: Color) {
        switch kind {
        case .checkpoint: return ("checkmark.seal.fill", .green)
        case .failure: return ("exclamationmark.triangle.fill", .orange)
        }
    }

    private func oneLine(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= 140 ? flat : String(flat.prefix(139)) + "…"
    }
}
