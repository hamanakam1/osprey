# Osprey

```text
                    .---.
                   /     \
                  |  >o   |
                   \  __/
                    \ | /
        ____________\/____________
       /                           \
      (   wings folded back along   )
       \        the body            /
        \_________________________/
          \       |        /
           \______|_______/
               splash
   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

[![CI](https://github.com/hamanakam1/osprey/actions/workflows/ci.yml/badge.svg)](https://github.com/hamanakam1/osprey/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-blue)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/swift-6.0-orange)](https://swift.org)
[![local-first](https://img.shields.io/badge/local--first-no%20telemetry-2ea44f)](docs/privacy.md)

**Observe. Propose. A person decides.**

Osprey is a local-first supervisor for the [Taskrivet](https://github.com/hamanakam1/taskrivet) desktop app. It has two jobs. The first is work capture: Osprey follows the terminal tabs you select, strips ANSI escape sequences, removes secret-shaped text, stores the result in a local SQLite file, and drafts checkpoint and failure records from it. The second is release supervision: Osprey checks a built Taskrivet app bundle, runs its packaged Python core against a throwaway database, backs up the app you have installed, installs the new build, and rolls back if the check fails. Neither job acts on its own. Osprey proposes; the ledger and you decide.

Osprey is a Swift package for macOS 14 and later. It needs a Swift 6.0 toolchain, and it compiles its targets in the Swift 5 language mode. It uses the standard library and the system SQLite. It has no third-party dependencies. It makes no network requests, because it contains no networking code.

Status: pre-release. The command surface and the on-disk format may still change.

## Contents

- [What it does](#what-it-does)
- [What it does not do](#what-it-does-not-do)
- [Architecture](#architecture)
- [The capture lifecycle](#the-capture-lifecycle)
- [The release lifecycle](#the-release-lifecycle)
- [Quick start](#quick-start)
- [Command reference](#command-reference)
- [Privacy and retention](#privacy-and-retention)
- [Development and verification](#development-and-verification)
- [Troubleshooting](#troubleshooting)
- [Glossary](#glossary)
- [Further documents](#further-documents)

## What it does

**Work capture**

- Connects to the Taskrivet local session service over a private Unix socket, read-only.
- Authenticates with the same 0600 token file the desktop app uses.
- Lists the tabs the service owns, and follows the ones you select.
- Strips ANSI escape sequences and replaces secret-shaped text before anything is stored.
- Stores redacted output in a local SQLite file under `~/.osprey/`.
- Drafts two kinds of proposal from that output: a checkpoint record and a failure record.
- Writes a proposal to the Taskrivet ledger only when you run `osprey approve <id> --yes`, and verifies the write by reading the session back from the ledger.

**Release supervision**

- Checks a built `Taskrivet.app` bundle: `Info.plist`, the executable, and the packaged Python core.
- Runs a smoke test against the packaged core using a throwaway database in a temporary directory.
- Backs up the installed app into `~/.taskrivet/app-backups/<timestamp>/`.
- Installs the new build over `~/Applications/Taskrivet.app`.
- Restores the previous build automatically when the smoke test fails.
- Restores a previous build on request with `osprey release rollback`.
- Writes a receipt into the local store when a build is installed.

**Menu-bar companion**

`OspreyBar` is a small SwiftUI menu-bar app. It shows how many proposals are waiting, how much evidence is stored, and which Taskrivet build is installed. You can approve or withdraw a proposal from the menu. Nothing happens on its own.

An approval is marked `applied` only when the ledger readback confirms the write. If the readback does not match, the menu shows a failure and records the proposal as `failed`, with the verification detail in its note and no applied time. Inspect the ledger before approving again; the write may have happened even when verification failed.

If the proposal is missing when its local outcome is saved, approval reports a storage failure instead of claiming that it was applied or marked failed. State updates do not recreate removed proposals. The ledger write may already have happened, so inspect the ledger before retrying.

## What it does not do

This list is deliberate. Most of these are things a supervisor tool is expected to do, and Osprey does not do them.

- **It does not execute anything.** Osprey never sends `write`, `resize`, `stop` or `remove` to the session service. It cannot type into your terminals.
- **It does not measure token usage.** The token count in a ledger record is a number you carry forward. Osprey never reads a provider's billing and never estimates usage. Its own evidence text says so on every proposal.
- **It does not verify progress.** It cannot tell whether a task is going well, half done, or already finished.
- **It does not complete tasks and does not diagnose failures.** A recorded failure is a record, not a cause.
- **It does not grant execution authority.** Every write path starts with a human command. There is no unattended mode.
- **It does not talk to any AI provider.** There is no model client, no provider integration, and no claim of compatibility with any provider or TUI.
- **It does not send anything over a network.** There is no HTTP client, no telemetry, no analytics, no update check.
- **It does not read your transcripts, messages, credentials or provider settings.** It reads terminal output from the tabs you select, and it reads the ledger through the Taskrivet command-line tool.
- **It does not own the ledger.** Tasks, sessions, checkpoints and the ledger database belong to Taskrivet.
- **It does not run on a schedule.** Nothing happens while you are not looking.

## Architecture

### Components

| Component | File | Responsibility |
| --- | --- | --- |
| Models | `Sources/OspreyCore/Models.swift` | Value types: terminal snapshots, evidence records, proposals, receipts, digests. |
| Redaction | `Sources/OspreyCore/Redaction.swift` | ANSI stripping, secret-shaped text replacement, command and failure heuristics. |
| Paths | `Sources/OspreyCore/Paths.swift` | Where Osprey and Taskrivet keep their files. Environment overrides. |
| Evidence store | `Sources/OspreyCore/EvidenceStore.swift` | The local SQLite database of evidence, proposals and receipts. |
| Session client | `Sources/OspreyCore/TaskrivetSessionClient.swift` | Read-only client for the Taskrivet session socket, plus the token reader. |
| Proposal engine | `Sources/OspreyCore/ProposalEngine.swift` | Turns stored evidence into checkpoint and failure drafts. |
| Ledger client | `Sources/OspreyCore/LedgerClient.swift` | Runs the Taskrivet command-line tool and verifies writes by reading back. |
| Release manager | `Sources/OspreyCore/ReleaseManager.swift` | Bundle checks, smoke test, backup, install, rollback. |
| Capture coordinator | `Sources/OspreyCore/CaptureCoordinator.swift` | Runs a capture: connect, follow, redact, store, draft. |
| Command line | `Sources/osprey/` | The `osprey` executable. Argument parsing and output only. |
| Menu bar | `Sources/OspreyBar/` | The `OspreyBar` menu-bar companion. |

The core library owns all behaviour. The command-line tool and the menu-bar app are thin shells over it, so both see the same state and the same rules.

### What crosses a boundary

| Boundary | What crosses | Direction | Mechanism |
| --- | --- | --- | --- |
| Taskrivet session service | Terminal output chunks, tab snapshots | Into Osprey | Unix stream socket, 0600, one JSON object per line |
| Session token file | The local token string | Into Osprey | Read from a regular file whose group and other permission bits are clear |
| Osprey evidence store | Redacted terminal text, proposals, receipts | Into and out of Osprey | SQLite file at `~/.osprey/evidence.sqlite` |
| Taskrivet ledger | A checkpoint or failure record | Out of Osprey | `python -m taskrivet` subprocess with an explicit argument vector, never a shell |
| Taskrivet app bundle | The installed application | Into the machine | File copy and move, with a backup taken first |
| Python interpreter | The Taskrivet Python core | Into the machine | Subprocess, version 3.11 or newer |
| The network | Nothing | Not crossed | No networking code exists in Osprey |

Read back the ledger state through the Taskrivet command-line tool. Osprey does not open the Taskrivet database itself, so it cannot write to it except through the same interface the desktop app uses.

## The capture lifecycle

1. **Connect.** Osprey opens the Unix socket in the Taskrivet session runtime directory and sends a `hello` message carrying the token. The service destroys the connection if the token or the protocol version is wrong.
2. **List.** Osprey sends `list` and receives one snapshot per tab: identifier, working directory, task, session, shell, state, exit code, process identifier, title, kind, and a bounded output tail.
3. **Select.** Without `--terminal`, Osprey follows every tab whose state is `running`. With `--terminal <id>`, it follows exactly the tabs you name.
4. **Read the tail.** The service keeps a bounded tail per tab for reconnecting clients. Osprey takes it first, so a proposal can be drafted even when nothing new arrives.
5. **Follow.** For `--seconds N` (default 5), Osprey listens for `terminal:data` events from the selected tabs and keeps the most recent 256,000 bytes per tab. The selection is fixed from the initial list; events from other or newly opened tabs are ignored.
6. **Redact.** Every chunk goes through ANSI stripping, then the redaction rules. Redaction happens before the write, not after.
7. **Store.** The redacted text goes into the SQLite evidence store. One row per chunk.
8. **Draft.** Osprey reads the stored evidence back and produces a checkpoint draft. When the output contains failure text, it produces a failure draft as well.
9. **Wait.** Nothing reaches the Taskrivet ledger until you run `osprey approve <id> --yes`.

## The release lifecycle

1. **Verify.** `osprey release verify --bundle /path/to/Taskrivet.app` reads `Contents/Info.plist` and checks the bundle identifier, the short version string, that `Contents/MacOS/<executable>` exists and is executable, and that `Contents/Resources/core/taskrivet` exists.
2. **Back up.** `osprey release install` copies the installed `~/Applications/Taskrivet.app` to `~/.taskrivet/app-backups/<yyyyMMdd-HHmmss>/Taskrivet.app`.
3. **Install.** The new bundle is copied to a staging directory beside the installed path, then moved into place.
4. **Smoke test.** Osprey runs the packaged Python core with `PYTHONPATH` pointing at the bundle's `Contents/Resources/core`, against a throwaway database in a temporary directory, and asks it for a ledger status. The real ledger is never touched.
5. **Roll back.** If the smoke test fails, the new bundle is removed and the backup is moved back into place. A failed install does not leave a broken application behind.
6. **Record.** The install writes a receipt into the local store.

`osprey release rollback` restores the newest backup. Pass `--backup <path>` to restore a specific one. `osprey release backups` lists what is available.

## Quick start

You need macOS 14 or later, a Swift 6.0 or later toolchain, and, for the capture and approval paths, a running Taskrivet desktop app with at least one open terminal tab.

```sh
git clone https://github.com/hamanakam1/osprey.git
cd osprey
swift build
swift test
.build/debug/osprey doctor
```

`osprey doctor` checks the Python interpreter, the Taskrivet core, the session socket, the token file permissions, the evidence store, and the installed Taskrivet build. It is the first thing to run when something does not work.

Then capture, draft, and approve:

```sh
# List the tabs the session service owns.
.build/debug/osprey terminals

# Follow one tab for ten seconds. Nothing is written to the ledger.
.build/debug/osprey capture --terminal <terminal-id> --seconds 10

# Draft proposals from the stored evidence.
.build/debug/osprey propose --terminal <terminal-id>

# Read the drafts.
.build/debug/osprey proposals --state proposed
.build/debug/osprey show <proposal-id>

# See what approving would write.
.build/debug/osprey approve <proposal-id>

# Apply it. The write is verified by reading the session back.
.build/debug/osprey approve <proposal-id> --yes
```

`osprey approve` does nothing until you pass `--yes`. Without it, it prints the record and stops. That is deliberate: the proposal is a draft, and applying it is a separate, explicit act.

To install a release:

```sh
.build/debug/osprey release verify --bundle /path/to/Taskrivet.app
.build/debug/osprey release install --bundle /path/to/Taskrivet.app
.build/debug/osprey release receipts
```

## Command reference

| Command | What it does |
| --- | --- |
| `osprey status` | Summary: Taskrivet tabs, stored evidence count, pending proposals, installed build. |
| `osprey terminals` | List the Taskrivet tabs the session service owns. |
| `osprey capture [--terminal ID]... [--all] [--seconds N] [--dry-run]` | Follow the selected tabs, redact the output, store it, and draft proposals. `--dry-run` prints the redacted buffered output and writes nothing. |
| `osprey propose [--terminal ID]` | Draft proposals from the evidence already stored. |
| `osprey proposals [--state S]` | List proposals. `S` is one of `proposed`, `applied`, `failed`, `withdrawn`, `all`. The default is `proposed`. |
| `osprey show <proposal-id>` | Show one proposal in full, as JSON. |
| `osprey approve <proposal-id> [--tokens N] [--yes]` | Write an approved proposal to the Taskrivet ledger, then read the session back to confirm it. Without `--yes` it prints what it would write and stops. |
| `osprey withdraw <proposal-id> [--reason R]` | Mark a proposal withdrawn, with a reason. |
| `osprey doctor` | Check Python, the Taskrivet core, the session socket, the token permissions, the store, and the installed build. |
| `osprey redact [text...]` | Show what the redaction rules do to a string. |
| `osprey privacy purge [--older-than DAYS]` | Delete stored evidence older than `DAYS`. The default is 7 days. |
| `osprey release verify --bundle PATH` | Check a built app bundle and report what is wrong with it. |
| `osprey release install --bundle PATH [--no-smoke-test]` | Back up the installed app, install the new bundle, smoke test it, and roll back on failure. |
| `osprey release rollback [--backup PATH]` | Restore a previous build. |
| `osprey release backups` | List the backups that can be restored. |
| `osprey release receipts` | List the release receipts. |
| `osprey help` | Print the command list. |
| `osprey version` | Print the version. |

Two notes on the surface.

`--terminal` takes the **full** terminal identifier. `osprey terminals` prints a shortened one for readability, so use `osprey terminals --json` when you need the whole value.

The reporting commands accept `--json` and print machine-readable output instead of text: `status`, `terminals`, `capture`, `propose`, `proposals`, `doctor` and `release verify`.

Configuration is environment variables only. There is no configuration file.

| Variable | Effect |
| --- | --- |
| `OSPREY_HOME` | Where Osprey keeps its state. Defaults to `~/.osprey`. |
| `TASKRIVET_DB` | The Taskrivet ledger database. Defaults to `~/.taskrivet/ledger.sqlite`. |
| `TASKRIVET_CORE` | The folder that contains the `taskrivet` Python package. Without it, Osprey searches the usual local places. |

## Privacy and retention

Osprey is local-first, and that is a property of the code, not a promise.

**Storage.** One SQLite file, `~/.osprey/evidence.sqlite`, in a state directory created with mode 0700. It holds captured terminal text, proposals, and release receipts. Nothing is copied anywhere else.

**Redaction.** Every captured chunk is passed through ANSI stripping and then through twelve rules before it is stored:

| Rule | Matches |
| --- | --- |
| `private-key` | A PEM private key block, from `BEGIN` to `END`. |
| `github-token` | `ghp_`, `gho_`, `ghu_`, `ghs_` or `ghr_` followed by 16 or more characters. |
| `openai-key` | `sk-` followed by 20 or more characters. |
| `anthropic-key` | `sk-ant-` followed by 20 or more characters. |
| `aws-access-key` | `AKIA` followed by 16 upper-case letters or digits. |
| `google-api-key` | `AIza` followed by 35 characters. |
| `slack-token` | `xoxb-`, `xoxa-`, `xoxp-`, `xoxr-` or `xoxs-` followed by 10 or more characters. |
| `jwt` | Three dot-separated base64url segments. |
| `bearer-token` | `Bearer` followed by 16 or more characters. |
| `authorization-header` | `Authorization:` and the rest of the line. |
| `assigned-secret` | `api_key`, `apikey`, `api-key`, `secret`, `passwd`, `password` or `token` followed by `:` or `=` and a value. |
| `basic-auth-url` | A URL of the form `scheme://user:password@host`. |

A match becomes `[<rule-name> REDACTED]`. The marker names the rule. It never contains the secret and never contains the length of the secret. The number of replacements is recorded with each evidence record, so you can see that something was removed.

Redaction matches shapes, not meaning. A secret in an unusual shape can survive. Treat the store as sensitive.

**Never read.** Osprey does not read transcripts, chat messages, credentials, provider settings, browser data, or any file outside the state directory and the Taskrivet locations named above. It reads the ledger through the Taskrivet command-line tool, never by opening the database.

**Retention.** Evidence records are kept until you remove them. Nothing is deleted on a timer. `osprey privacy purge --older-than DAYS` deletes stored evidence older than the given age. To remove everything Osprey holds, delete the state directory:

```sh
rm -rf ~/.osprey
```

Details, including the limits on how much is captured, are in [docs/privacy.md](docs/privacy.md).

## Development and verification

Requirements: macOS 14 or later, and a Swift 6.0 or later toolchain. The package has no dependencies, so there is nothing to resolve.

```sh
swift build          # build the library, the CLI and the menu-bar app
swift test           # run the test suite
swift build -c release
```

If your machine has only the Command Line Tools, `swift test` cannot find the
Swift Testing macro plugin on its own. `scripts/test.sh` points at it for you:

```sh
./scripts/test.sh
```

To try the CLI without touching your real state, point it at a scratch directory:

```sh
OSPREY_HOME="$(mktemp -d)" .build/debug/osprey status
```

`scripts/verify.sh` runs the build, the tests and the public content guard in one go:

```sh
./scripts/verify.sh
```

The public content guard checks that the documentation and the repository scaffolding contain no credential-shaped text, no absolute home directory paths, and no links to places other than the allowlist. It runs in CI.

Core tests live in `Tests/OspreyCoreTests/`, menu-bar behaviour tests in `Tests/OspreyBarTests/`, and command-line behaviour tests in `Tests/OspreyCLITests/`. A change in behaviour needs a test that fails without the change.

## Troubleshooting

`osprey doctor` is the fastest way to find out what is missing.

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| `The Taskrivet session service is not reachable` | The desktop app is not running, or it is using a different ledger database. | Start Taskrivet. If it uses a custom ledger, set `TASKRIVET_DB`. |
| `The session token file is readable by other users` | The token file permissions are too wide. | `chmod 600 ~/.taskrivet/sessions-*/token`. |
| `The session service rejected the local token` | The token file does not match the running service. | Restart Taskrivet so it writes a fresh token. |
| `The Taskrivet Python core was not found` | The core is not in one of the searched folders. | Set `TASKRIVET_CORE` to the folder that contains the `taskrivet` package. |
| `Python 3.11 or newer is required` | No interpreter of that version was found. | Install Python 3.11 or later, or make it visible on the default paths. |
| `This terminal is not linked to a Taskrivet ledger session` | The tab was opened without a task assignment. | Assign the tab to a task in Taskrivet, then capture again. |
| `The bundle is not usable` | The path is not an app bundle, or a required part is missing. | Check the reported problems against the bundle layout in [docs/release-lifecycle.md](docs/release-lifecycle.md). |
| `No Taskrivet backup was found` | There is nothing to roll back to. | Install a build once so a backup exists, or pass `--backup <path>`. |
| The evidence store will not open | The state directory or the database is not writable. | Check the permissions on `~/.osprey`. |

Longer explanations are in [docs/troubleshooting.md](docs/troubleshooting.md).

## Glossary

**Approval.** The act of running `osprey approve <id>`. Until it happens, a proposal is a local draft.

**Bundle.** A macOS application directory with a `Contents` folder, an `Info.plist`, and an executable. Taskrivet ships as `Taskrivet.app`.

**Checkpoint.** A ledger record describing work in progress: a summary, the evidence behind it, the next step, and a cumulative reported token count.

**Evidence.** One captured, already-redacted chunk of terminal output, stored in the local database.

**Evidence store.** The SQLite database at `~/.osprey/evidence.sqlite`, holding evidence, proposals and receipts.

**Failure record.** A ledger record noting that the captured output contained failure text. It is not a diagnosis.

**Ledger.** The Taskrivet coordination database. It holds tasks, sessions, checkpoints and failures. It belongs to Taskrivet.

**Proposal.** A local draft of a checkpoint or a failure record, built from evidence and awaiting approval.

**Receipt.** A record of one release action: verified, installed, rolled back, or failed.

**Redaction.** Replacing secret-shaped text with a marker before anything is written to disk.

**Runtime directory.** The Taskrivet directory that holds the session socket and the token. Its name is derived from a hash of the ledger database path.

**Session service.** The local Taskrivet service that owns the terminal tabs and lets clients follow their output over a private Unix socket.

**State directory.** `~/.osprey`, or the directory named by `OSPREY_HOME`. It holds the evidence store.

**Tab.** One embedded terminal in Taskrivet. Osprey can follow a tab and read its output. It cannot type into it.

## Further documents

- [docs/architecture.md](docs/architecture.md) — components, data model, boundaries, failure model.
- [docs/capture-and-redaction.md](docs/capture-and-redaction.md) — the capture pipeline, the limits, and the redaction rules.
- [docs/taskrivet-integration.md](docs/taskrivet-integration.md) — the session socket protocol and the ledger interface.
- [docs/release-lifecycle.md](docs/release-lifecycle.md) — bundle checks, smoke test, install, rollback.
- [docs/privacy.md](docs/privacy.md) — what is stored, what is never read, and how to remove it.
- [docs/troubleshooting.md](docs/troubleshooting.md) — symptoms, causes, and fixes.
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to propose a change.
- [SECURITY.md](SECURITY.md) — how to report a vulnerability.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — how to behave towards other people.
- [CHANGELOG.md](CHANGELOG.md) — what has changed.
- [ROADMAP.md](ROADMAP.md) — what is planned, and what will not be built.
