# Security policy

## Supported versions

Osprey is pre-release. There is no stable release yet, and there is no long-term support branch.

| Version | Supported |
| --- | --- |
| `main` (unreleased) | Yes |
| Any tagged release | No |

Fixes land on `main`. When a release is published, this table will be updated.

## Reporting a vulnerability

Use GitHub's private reporting for this repository:

1. Open the repository's **Security** tab on GitHub.
2. Choose **Report a vulnerability**.
3. Describe the issue.

That opens a private advisory that only the maintainers can see. Please do not open a public issue for a vulnerability.

Useful things to include:

- what an attacker can do, and what they need in order to do it;
- the version or commit you tested;
- the steps to reproduce;
- the output of `osprey doctor`, with any local detail removed.

Please do not include real credentials, private terminal transcripts, or ledger contents. A synthetic reproduction is better than a real one.

### What to expect

- An acknowledgement, usually within a few days.
- An assessment, and a decision about whether the report is accepted.
- A fix, and a release or a commit that contains it.
- Credit, if you want it, in the release notes or the advisory.

### What we ask of reporters

- Give the maintainers a reasonable amount of time to release a fix before disclosing publicly.
- Avoid accessing data that is not yours, even in a proof of concept.
- Avoid causing lasting disruption to other people's machines or work.

## What Osprey will not do

These are properties of the code, and they are the reason a vulnerability report about data leaving the machine is unlikely to be accepted:

- **No network code.** Osprey contains no HTTP client, no socket other than the local Unix socket to the Taskrivet session service, and no update check.
- **No telemetry.** Nothing is measured and sent. There is no usage counter, no crash reporter, and no diagnostic upload.
- **No analytics.** There is no third-party service in the build, because there are no dependencies.
- **No credential storage.** The Taskrivet session token is read from a file that must not be readable by other accounts, is held in memory for the life of the connection, and is never written to the Osprey state directory.
- **No unattended writes.** The only write to the Taskrivet ledger happens after a person runs `osprey approve`.

## Privacy guarantees

The full statement is in [docs/privacy.md](docs/privacy.md). In short:

- Everything Osprey stores is in one SQLite file, `~/.osprey/evidence.sqlite`, inside a directory created with mode 0700.
- Captured terminal output is redacted before it is stored, using the rules described in [docs/capture-and-redaction.md](docs/capture-and-redaction.md).
- Osprey does not read transcripts, messages, credentials, or provider settings.
- Osprey does not open the Taskrivet ledger database. It writes to the ledger only through the Taskrivet command-line tool, and only after an approval.
- Redaction matches shapes, not meanings. A secret in an unusual shape can survive. The evidence store holds sensitive material.

## Reporting a privacy problem

If you believe Osprey is sending data somewhere, is storing something it should not, or is reading a file it should not, treat it as a security issue and report it privately, as above. A specific reproduction is more useful than a general concern.

## Non-vulnerabilities

These are design decisions, not bugs, and are usually better raised as an issue:

- Osprey proposes and does not act on its own.
- Osprey does not measure token usage.
- Osprey does not verify progress or diagnose failures.
- Osprey does not read transcripts, credentials or provider settings, by design.
- Redaction does not catch every secret. It matches known shapes, and the rules are listed in the documentation.
- A local process running as your own user can read `~/.osprey`.
