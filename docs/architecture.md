# Architecture

This document describes how Osprey is put together, what each part owns, and what happens when something goes wrong.

## The shape of the thing

Osprey has two jobs and one rule.

The two jobs:

1. **Work capture.** Follow the terminal output of selected Taskrivet tabs, redact it, store it locally, and draft checkpoint and failure records from it.
2. **Release supervision.** Check a built Taskrivet app bundle, smoke test it, back up the installed app, install the new build, and roll back when the check fails.

The rule: **observe, propose, and let a human decide.** Every path that changes something outside Osprey's own state directory begins with a command a person typed.

## Layers

```
    osprey (CLI)              OspreyBar (menu bar)
         |                            |
         +------------+---------------+
                      |
                  OspreyCore
                      |
    ------------------+-------------------
    |                  |                   |
 Taskrivet        EvidenceStore        Taskrivet
 session          (SQLite on disk)    ledger CLI
 service                                |
                                   Taskrivet
                                    ledger
```

`OspreyCore` is a library. It contains all the behaviour: path resolution, redaction, the session client, the store, the proposal engine, the ledger client, and the release manager. Neither executable contains logic of its own beyond argument parsing and printing. That means the command line and the menu bar cannot disagree about what a proposal is, because both build it with the same code.

## Components

### `Models.swift`

Plain value types. No behaviour beyond a couple of computed properties.

| Type | What it is |
| --- | --- |
| `TerminalChunk` | One buffered chunk of terminal output: a sequence number and the text. |
| `TaskrivetTerminal` | A tab as reported by the session service. Decoding ignores fields Osprey does not know. |
| `EvidenceRecord` | One captured, already-redacted chunk of output, with its size and redaction count. |
| `ProposalKind` | `checkpoint` or `failure`. |
| `ProposalState` | `proposed`, `applied`, `failed` or `withdrawn`. Osprey never moves a proposal forward by itself. |
| `Proposal` | A reviewable draft of a ledger record, plus its lifecycle state. |
| `ReleaseReceipt` | A record of one release action. |
| `TerminalDigest` | A countable summary of one terminal's captured output. |

`Proposal.isApplicable` is true only when the proposal carries a ledger session identifier. A terminal opened without a task assignment has none, and such a proposal can be shown but not applied.

`TaskrivetTerminal.displayTitle` prefers the tab title, then the task identifier, then the shell name. It is what a person would recognise.

### `Redaction.swift`

Three jobs:

1. `stripANSI` removes CSI and OSC escape sequences. It runs first, so that the redaction rules never match text hidden inside escape sequences.
2. `redact` applies the twelve secret-shaped rules in order, replacing each match with `[<rule-name> REDACTED]`, and counts the replacements.
3. `commandCandidates` and `failureCandidates` are heuristics used to draft a summary. They look for lines that start like a known command, and lines that contain a known failure marker.

The heuristics are explicitly not a verified command log. They exist to give the operator something to read when reviewing a proposal.

### `Paths.swift`

Every path Osprey uses is resolved from an explicit input with a documented fallback. A missing path is reported, not invented.

| Location | Default | Override |
| --- | --- | --- |
| State directory | `~/.osprey`, created with mode 0700 | `OSPREY_HOME` |
| Evidence database | `<state>/evidence.sqlite` | — |
| Proposals directory | `<state>/proposals` | — |
| Receipts directory | `<state>/receipts` | — |
| Ledger database | `~/.taskrivet/ledger.sqlite` | `TASKRIVET_DB` |
| Python core | searched, see below | `TASKRIVET_CORE` |

The Python core is searched in this order: `TASKRIVET_CORE`, `~/Projects/taskrivet`, `~/Projects/Taskrivet`, `~/.taskrivet/core`, `/Applications/Taskrivet.app/Contents/Resources/core`, `~/Applications/Taskrivet.app/Contents/Resources/core`. A candidate counts only when it contains a `taskrivet` package directory. The search paths are reported in the error message when nothing is found.

The Taskrivet session runtime directory is derived from the ledger database path: the resolved path is hashed with SHA-256, and the first twelve hex characters are used in the directory name, `~/.taskrivet/sessions-<hash>`. Taskrivet derives the same name the same way, so Osprey finds the live socket without being told where it is. A small self-contained SHA-256 implementation lives in this file so that Osprey does not need a cryptography dependency.

### `EvidenceStore.swift`

The local SQLite database. One file, four tables.

| Table | Columns | Purpose |
| --- | --- | --- |
| `evidence` | `id`, `terminal_id`, `captured_at`, `text`, `bytes`, `redactions` | Captured output, already redacted. |
| `proposals` | `id`, `state`, `created_at`, `applied_at`, `json` | Drafts and their lifecycle state. The proposal itself is stored as JSON. |
| `receipts` | `id`, `occurred_at`, `action`, `json` | Release receipts, stored as JSON. |
| `meta` | `key`, `value` | Small key/value settings. |

Indexes exist on `(terminal_id, captured_at)` for evidence, `(state, created_at)` for proposals and `(occurred_at)` for receipts.

The database is opened read-write and create, with the full-mutex flag so concurrent access from the CLI and the menu-bar app is safe. Empty evidence is not stored: `append` ignores an empty text.

`prune(olderThan:)` deletes evidence older than a given date and returns how many rows went. Nothing calls it on a timer.

The error type `OspreyError` carries the five failure classes the operator can act on: `storeFailure`, `taskrivetUnavailable`, `notApplicable`, `invalidInput`, `releaseFailure`.

### `TaskrivetSessionClient.swift`

A read-only client for the Taskrivet local session service.

- The transport is an `AF_UNIX` `SOCK_STREAM` socket.
- The protocol is one JSON object per line in each direction.
- The first message must be `hello` with the token and the protocol version. The service destroys the connection otherwise.
- Osprey then sends `list`. That is the only other request it makes.

The service supports `create`, `write`, `resize`, `stop` and `remove`. Osprey implements none of them. The client cannot type into a terminal, because the code that would do it does not exist.

Requests carry an identifier and are matched to responses by that identifier. A request that is not answered within ten seconds fails with a protocol error rather than hanging.

The service pushes two events:

- `terminal:data` with a tab identifier, a sequence number and the text.
- `terminal:exit` with a tab identifier and an exit code.

A background thread reads the socket into a buffer and splits it on newlines. A lock protects the shared buffer, the pending request table and the socket descriptor.

`SessionTokenReader` reads the token file. It refuses to read a file that is not a regular file, and it refuses to read a file whose group or other permission bits are set. A world-readable secret is not read on your behalf.

### `ProposalEngine.swift`

Turns stored evidence into drafts. It never writes to the ledger.

The checkpoint draft quotes up to three command-shaped lines and notes the first failure-shaped line if one is present. The summary is capped at 240 characters and the evidence note at 400.

The evidence note is written so that it cannot be mistaken for a measurement. It names the terminal, the byte and line counts, the number of redactions, the capture window, and then states that the reported token usage is not measured by Osprey. Every checkpoint draft carries a note saying it is not verified progress and not a claim that the task is complete. Every failure draft carries a note saying a recorded failure is not a diagnosis.

Both drafts set `tokens` to zero. The token count in a ledger record is a number the operator carries forward, not something Osprey derives.

### `LedgerClient.swift`

Reads and writes the Taskrivet ledger by running the Taskrivet command-line tool.

The command is built as an explicit argument vector. There is no shell, so nothing in a summary or an evidence string can be interpreted as a command.

```text
<python> -m taskrivet --db <ledger path> <subcommand> [options]
```

`PYTHONPATH` is set to the core root and the working directory is the core root, so the packaged core is importable without installing it.

Python is found by looking at `/opt/homebrew/bin/python3`, `/usr/local/bin/python3` and `/usr/bin/python3`, and taking the first whose version is 3.11 or newer.

Reads use `status`, and the sessions are read out of the status payload. Writes use:

- `checkpoint <session> --summary <text> --evidence <text> --next <text> --tokens <count>`
- `fail <session> --category <category> --summary <text>`

After a write, the client reads the session back from the ledger and compares. A checkpoint write is confirmed when the readback reports the same token count. A failure write is confirmed when the readback reports the status `failed`. The result of that comparison is reported as verified or not, and it is written into the proposal.

The token count is cumulative and cannot decrease, so Osprey carries the session's current count forward unless the operator states a new one. The new count is the larger of the two.

### `ReleaseManager.swift`

Verifies, installs and rolls back the Taskrivet desktop build.

- `verify` reads `Contents/Info.plist` and reports the identifier, the short version string, the build number, whether the executable is present, whether the packaged Python core is present, and a list of problems. A bundle with problems is not usable.
- `smokeTest` runs the packaged core against a throwaway database in a temporary directory and asks for a ledger status. It returns the stderr text when the run fails.
- `install` verifies the bundle, backs up the installed app, stages the new bundle beside the installed path, moves it into place, and then smoke tests the installed copy. A failed smoke test removes the new bundle and moves the backup back.
- `rollback` restores a backup, defaulting to the most recent one.
- `listBackups` returns the backups that can be restored, newest first.

The rollback-on-failure path exists because a half-installed application is worse than an old one.

### `CaptureCoordinator.swift`

Runs one capture.

1. Connect to the session service and authenticate.
2. List the tabs and select the ones to follow.
3. Take the buffered tail of each selected tab.
4. Listen for live output for the requested number of seconds.
5. Redact and store every chunk.
6. Read the evidence back and draft a checkpoint, and a failure when the output contains failure text.

The coordinator writes to the evidence store and nowhere else. It has no ledger client, so it cannot write to the ledger even if it wanted to.

### `Sources/osprey/`

The command line. It has two files of its own: an option parser and the command dispatcher.

The option parser reads `--key value`, `--key=value`, and `--flag`. It has no third-party dependency, because the package has none. Repeated options, such as `--terminal`, are collected in order.

The dispatcher maps a command name to a handler. Each handler parses its arguments, calls into `OspreyCore`, and prints the result. Two behaviours are worth knowing:

- `osprey approve` without `--yes` prints the record it would write and stops. Applying a draft is a separate, explicit act.
- The reporting commands accept `--json` and print machine-readable output instead of text.

Errors are reported on standard error with the `osprey:` prefix, and the exit status is non-zero. A write that the ledger did not confirm exits with status 2, so a script can tell it apart from an ordinary failure.

## What crosses a boundary

| Boundary | What crosses | Direction | Mechanism | Notes |
| --- | --- | --- | --- | --- |
| Taskrivet session service | Terminal output, tab snapshots | In | Unix stream socket, mode 0600 | One JSON object per line. Read-only: `hello` and `list` only. |
| Session token file | The token string | In | Regular file read | Group and other permission bits must be clear. |
| Osprey evidence store | Redacted text, proposals, receipts | In and out | SQLite file | Written only after redaction. |
| Taskrivet ledger | A checkpoint or failure record | Out | Subprocess with an explicit argument vector | Only after `osprey approve --yes`. Verified by readback. |
| Taskrivet app bundle | The installed application | Into the machine | File copy, file move | A backup is taken first. |
| Python interpreter and core | The Taskrivet Python package | Into the machine | Subprocess | Used for the ledger and the smoke test. |
| The network | Nothing | Not crossed | — | No networking code exists. |

## Concurrency

- The session client runs one reader thread per connection. It appends to a shared buffer under a lock.
- The capture coordinator keeps per-terminal buffers under its own lock.
- The evidence store opens SQLite with the full-mutex flag, so the CLI and the menu-bar app can both have it open.
- The release manager is used by one command at a time. It performs no background work.

## Failure model

The rule is that a failure leaves the machine in a state a person can reason about.

| Failure | What Osprey does |
| --- | --- |
| The session service is unreachable | The capture stops with a clear message. Nothing is stored. |
| The token is rejected | The connection is closed. Nothing is stored. |
| No tabs match the selection | The capture stops with a message. Nothing is stored. |
| The Python core is missing | The ledger write does not happen. The proposal stays in `proposed` state. |
| The ledger write fails | The command stops with the error. The proposal stays in `proposed` state, so the write can be retried. |
| The readback does not confirm the write | The proposal is marked `failed` with the detail text, and the command exits with a non-zero status. |
| The bundle does not verify | The install does not start. |
| The copy or move during install fails | The staged copy is removed and the backup is moved back. |
| The smoke test fails | The new bundle is removed and the backup is moved back. The outcome reports `rolledBack`. |

In every case, the ledger and the installed application are left in a known state, and the failure is reported in words rather than by exit code alone.

## Where to add things

- New redaction rules belong in `Redaction.swift`, with a test in `Tests/OspreyCoreTests/`.
- New proposal kinds belong in `Models.swift` and `ProposalEngine.swift`, and need a matching ledger write in `LedgerClient.swift`.
- New release checks belong in `ReleaseManager.verify`, and the problems list is what the operator sees.
- New commands belong in `Sources/osprey/`, and their behaviour belongs in `OspreyCore`.
- New menu-bar views belong in `Sources/OspreyBar/`, and their behaviour belongs in `OspreyCore`.
