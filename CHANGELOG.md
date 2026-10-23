# Changelog

All notable changes to this project are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Refuse to report an approval outcome when its proposal is missing from the
  local store. State updates no longer recreate proposals removed during an
  update, and SQLite update errors are reported instead of treated as missing
  records. The command line and menu bar explain that the ledger write may
  still have happened.
- Apply terminal selection to live output as well as buffered tails. Capture
  now ignores events from unselected or newly opened tabs before accumulating
  their text, keeping that output out of the evidence store and drafts.
- Reject ledger commands that exit nonzero before using their output. A
  failed checkpoint or failure record can no longer appear verified because
  the session's previous token count or status already matches the request.
- Treat an unverified menu-bar approval as failed, matching the command line.
  Keep the verification detail in the proposal note, leave its applied time
  unset, and show a failure message instead of success.

## [0.1.0] - 2026-10-22

This is the first public state of Osprey. The entries describe what exists today, not a sequence of past releases.

### Work capture

- A read-only client for the Taskrivet local session service. It authenticates with the shared token over a private Unix socket, lists the tabs the service owns, and follows their output. It sends `hello` and `list` and nothing else, so it cannot write to, resize, stop, or close a terminal.
- A token reader that refuses to read a token file that is not a regular file, or whose group and other permission bits are set.
- ANSI escape sequence stripping, applied to every captured chunk before anything else looks at it.
- Twelve redaction rules for secret-shaped text: private key blocks, GitHub, OpenAI, Anthropic, AWS and Google API keys, Slack tokens, JSON web tokens, bearer tokens, authorization headers, assigned secrets, and credentials embedded in URLs. A match becomes a marker that names the rule and contains neither the secret nor its length. The number of replacements is recorded with each capture.
- A local SQLite evidence store under `~/.osprey/`, holding evidence, proposals and receipts.
- A capture coordinator that reads the bounded output tail a tab keeps, follows live output for a bounded number of seconds, caps what it keeps per tab, redacts, stores, and then drafts proposals from the stored evidence.
- A proposal engine that drafts checkpoint and failure records from captured output, and that states in the record itself what it did not measure.
- A ledger client that writes an approved proposal through the Taskrivet command-line tool using an explicit argument vector, never a shell, and then reads the session back to confirm the write.
- A `osprey capture` command with `--terminal`, `--all`, `--seconds` and `--dry-run`, a `osprey propose` command, and the `osprey proposals`, `osprey show`, `osprey approve` and `osprey withdraw` commands.

### Release supervision

- Bundle verification that reads `Info.plist` and checks the bundle identifier, the short version string, the executable, and the packaged Python core.
- A smoke test that runs the packaged core against a throwaway database in a temporary directory, so the real ledger is never touched.
- An installer that backs up the installed application to `~/.taskrivet/app-backups/<timestamp>/`, stages the new bundle beside the install path, and moves it into place.
- Automatic rollback when the smoke test fails, so a failed install does not leave a broken application behind.
- `osprey release rollback`, which restores the most recent backup or a backup named with `--backup`.
- Release receipts recording a release action, with the version, the source, the backup path, the install path, the smoke-test result and a description of what happened.

### Command line

- The full command surface: `status`, `terminals`, `capture`, `propose`, `proposals`, `show`, `approve`, `withdraw`, `doctor`, `redact`, `privacy purge`, `release verify`, `release install`, `release rollback`, `release backups`, `release receipts`, `help` and `version`.
- `osprey approve` prints the record it would write and stops unless `--yes` is given, so that applying a draft is a separate, explicit act.
- Machine-readable output on the reporting commands: `status`, `terminals`, `capture`, `propose`, `proposals`, `doctor` and `release verify` accept `--json`.
- `osprey doctor` checks the Python interpreter, the Taskrivet core, the session socket, the token file permissions, the evidence store, and the installed Taskrivet build.

### Menu-bar companion

- `OspreyBar`, a SwiftUI menu-bar application that shows the same local state as the command line: how many proposals are waiting, how much evidence is stored, and which Taskrivet build is installed. A proposal can be approved or withdrawn from the menu, one click at a time.

### Documentation

- `README.md`, with the architecture, both lifecycles, the command reference, the privacy model, and a glossary.
- `docs/architecture.md`, `docs/capture-and-redaction.md`, `docs/taskrivet-integration.md`, `docs/release-lifecycle.md`, `docs/privacy.md` and `docs/troubleshooting.md`.
- `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` and `SECURITY.md`.
- A public content guard that checks the documentation and the repository scaffolding for credential-shaped text and for absolute home directory paths.

### Build

- A Swift package needing a Swift 6.0 toolchain and targeting macOS 14 and later, with no third-party dependencies. The standard library and the system SQLite are enough.
- Continuous integration on the macOS 15 image, running the build, the tests and the public content guard.
