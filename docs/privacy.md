# Privacy

This document states what Osprey stores, what it never reads, how long it keeps things, and how to remove them.

## The promise

Osprey is local-first. That is a property of the code, not a policy statement:

- there is no networking code in Osprey;
- there is no telemetry, no analytics, no update check, and no crash reporter;
- the only data store is a SQLite file on this machine;
- the only external processes Osprey starts are the Python interpreter and the Taskrivet Python core, both local.

## Where things live

| Path | What it holds | Mode |
| --- | --- | --- |
| `~/.osprey/` | The state directory | 0700 |
| `~/.osprey/evidence.sqlite` | Evidence, proposals, receipts, small settings | Created by SQLite |
| `~/.osprey/proposals/` | Reserved for proposal files | 0700 |
| `~/.osprey/receipts/` | Reserved for receipt files | 0700 |

`OSPREY_HOME` moves the state directory. The `~/.taskrivet/app-backups/` folder holds copies of the installed Taskrivet application. That folder belongs to Taskrivet, not to Osprey, though Osprey writes to it when it installs a release.

## The tables

| Table | What a row holds |
| --- | --- |
| `evidence` | A terminal identifier, a capture time, the redacted text, its byte count, and the number of redactions applied. |
| `proposals` | A proposal identifier, its state, its creation and application times, and the proposal itself as JSON. |
| `receipts` | A release action: when it happened, what it was, and the receipt as JSON. |
| `meta` | Small key/value settings. |

A proposal holds a summary, an evidence note, a next step, the terminal identifier and title, the task and session identifiers, a token count of zero, and a note saying what the proposal is not.

## What is never read

Osprey does not read:

- chat transcripts or messages;
- credentials, keychains, or provider settings;
- browser data, files, or mail;
- the Taskrivet ledger database directly, including its task records, context packets and event trail;
- anything outside the state directory, the Taskrivet locations named below, and the bundle being installed.

The full list of locations Osprey touches:

| Location | Access |
| --- | --- |
| `~/.osprey/` | Read and write |
| `~/.taskrivet/ledger.sqlite` | Named on the Taskrivet command line. Never opened by Osprey. |
| `~/.taskrivet/sessions-<hash>/sessions.sock` | Read, read-only |
| `~/.taskrivet/sessions-<hash>/token` | Read once per connection |
| `~/.taskrivet/app-backups/` | Read and write |
| `~/Applications/Taskrivet.app` | Read and write, during a release |
| The bundle given to `release verify` or `release install` | Read |
| A temporary directory for the smoke test | Read and write, removed afterwards |

## What redaction removes

Twelve rules run over every captured chunk before it is stored. The full table is in [capture-and-redaction.md](capture-and-redaction.md). In summary: private key blocks, GitHub, OpenAI, Anthropic, AWS and Google API keys, Slack tokens, JSON web tokens, bearer tokens, authorization headers, assigned secrets, and credentials embedded in URLs.

A match becomes `[<rule-name> REDACTED]`. The marker names the rule and never contains the secret or its length.

### What redaction does not remove

Redaction matches shapes, not meanings. These things can survive it:

- a secret with an unusual prefix, or none at all;
- a password typed at a prompt with no label;
- a credential inside a larger encoded blob;
- a personal name, an email address, or an internal hostname;
- a file path, including the working directory, which is quoted in the evidence note.

Redaction lowers the risk. It does not remove it. The evidence store holds sensitive material.

## What a capture can still reveal

Even with redaction applied, a stored evidence record can contain:

- the working directory of the tab, as an absolute path;
- the text of command lines, including file names and arguments;
- compiler errors, stack traces and log lines;
- names of people, hostnames, and project identifiers.

None of this leaves the machine. All of it stays until you remove it.

## Retention

Evidence records are kept until you remove them. There is no timer, no automatic prune, and no size cap on the database as a whole. Each individual capture is bounded, but the store grows with use.

| Command | Effect |
| --- | --- |
| `osprey privacy purge --older-than DAYS` | Delete stored evidence older than the given number of days. The default is 7 days. |

The proposals and receipts tables are records of decisions. A proposal is kept until it is applied or withdrawn. Remove the rest by removing the state directory.

## Removing everything

```sh
# Remove all Osprey state: evidence, proposals, receipts, settings.
rm -rf ~/.osprey
```

Or, if `OSPREY_HOME` points elsewhere, remove that directory instead.

The Taskrivet ledger is a separate thing. Osprey never writes to it without an approval, and it does not delete from it. To remove what Osprey wrote to the ledger, use the Taskrivet command-line tool.

The application backups are separate again:

```sh
rm -rf ~/.taskrivet/app-backups/<timestamp>
```

## The token file

The Taskrivet session token is a secret. Osprey handles it as follows:

- it checks that the file is a regular file;
- it checks that the group and other permission bits are clear, and refuses to read the file otherwise;
- it reads the token into memory for the life of the connection;
- it never writes the token to disk, never logs it, and never puts it in an evidence record.

The token is not stored in the Osprey state directory.

## Threat model

Osprey is built for the case where the machine and the account are yours, and the things you do not want are: data leaving the machine, and a secret ending up in a file that gets committed or shared.

It is not built for:

- a hostile process running as your user, which can read `~/.osprey` directly;
- a compromised Taskrivet, which could send misleading output;
- an operator who approves a proposal they have not read;
- a secret with a shape the rules do not recognise.

The evidence store is in your home directory. If you share your machine, other accounts cannot read it while the directory permissions hold, but you are the one who decides whether to capture a sensitive tab at all.

## What Osprey never does

- It never sends data over a network.
- It never checks for updates.
- It never uploads a diagnostic bundle.
- It never writes a crash report.
- It never asks for permission to read something at runtime, because there is nothing to ask about beyond the files listed above.
- It never writes to the Taskrivet ledger without `osprey approve`.
