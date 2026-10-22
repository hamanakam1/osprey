# Roadmap

This document says what is planned and what will not be built. It is a statement of intent, not a schedule. Nothing here is committed to a date.

## Near term

### Capture

- **Better summaries.** The current summary is built by matching text. Recognising a shell prompt, a test result line, and a build result would make the drafts more useful.
- **Longer captures with a stop condition.** Following a tab until it goes quiet, rather than for a fixed number of seconds.
- **Per-terminal retention.** Choosing how long each terminal's evidence is kept, instead of one global rule.
- **A capture report.** A short summary of what was captured, what was redacted, and what was drafted, written to a file as well as printed.
- **Filtering the evidence used for a draft.** Right now every stored record for a terminal is read back. Being able to narrow it to a time window would help.

### Proposals

- **Editing a proposal before approval.** Let the operator correct the summary and the next step in the draft, rather than accepting or rejecting it as it stands.
- **Grouping drafts.** When one tab produces both a checkpoint and a failure draft, show them together.
- **Showing the evidence a draft was built from.** The draft cites counts; showing the lines it matched would make review faster.
- **A single approval that covers a whole capture.** Approving a checkpoint and its matching failure separately is deliberate today. A way to approve both, once the operator has read both, would be useful.

### Release supervision

- **Verifying more of the bundle.** The checksum of the packaged core, and a check that the packaged core is the same version as the source tree.
- **Keeping a backup index.** A small file recording what each backup contains, so a rollback can say what it is restoring.
- **Pruning old backups.** Keeping the last few and removing the rest, on request.
- **A dry run for installs.** Showing what would be backed up and where the new build would go, without touching anything.

### Interface

- **A first release.** A tagged version, a changelog entry, and a stated support window.
- **Shell completion** for the command surface.
- **Machine-readable output everywhere.** The reporting commands accept `--json`. The remaining commands, in particular `show` and `release receipts`, should offer it too.

## Deliberately not planned

These are not backlog items. They are positions, and a pull request that adds one will be declined.

- **Autonomous operation.** No scheduled captures, no unattended approvals, no daemon mode. A human runs the commands.
- **Token measurement.** Osprey does not read a provider's usage, does not estimate it, and does not infer it. The token count in a ledger record stays a number the operator carries.
- **Progress verification.** Osprey does not decide whether a task is going well, half done, or finished.
- **Failure diagnosis.** A failure record is a record. Finding the cause is a different job.
- **Provider or TUI integration.** Osprey does not talk to any AI provider, and does not claim compatibility with any terminal user interface beyond the Taskrivet session service it reads from.
- **Network features.** No telemetry, no analytics, no update checks, no remote sync. Adding a network dependency would change what this project is.
- **Reading more of Taskrivet.** Osprey does not read the ledger database, the context packets, or the event trail. It uses the same public command-line interface the desktop app uses.
- **Reading transcripts, messages, credentials, or provider settings.** These are out of scope by design, not by oversight.
- **A plugin or extension system.** The surface is small on purpose. Adding a plugin point means adding a trust boundary.
- **Multi-machine or shared operation.** Osprey is for one account on one Mac.

## Open questions

- How long should evidence be kept by default, if at all? The current answer is: as long as you want it, until you purge it.
- Should the smoke test be able to do more than a ledger status read? A wider check is a better check, but it also touches more of the bundle.
- Should a proposal be able to record more than one next step? The ledger format is the limit, not Osprey.
