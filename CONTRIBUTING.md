# Contributing to Osprey

Thank you for wanting to help. This document describes how to propose a change, what a change has to include, and what this project will not accept.

Read [README.md](README.md) first, especially "What it does not do". Most disagreements about a proposed change are settled by that section.

## The rule the project follows

Osprey observes and proposes. A person decides.

Everything else follows from it:

- Osprey does not act on its own, and a change that lets it act without a command will be declined.
- Osprey does not measure token usage, verify progress, complete tasks, or diagnose failures, and it will not start.
- Osprey has no network code, and a change that adds one will be declined.
- Osprey does not read transcripts, messages, credentials, or provider settings, and a change that adds one will be declined.
- Osprey does not claim compatibility with any AI provider or terminal user interface that the code does not actually exercise.

If you want to build something that does those things, that is a different tool. This one will not grow into it.

## Getting set up

Requirements: macOS 14 or later, and a Swift 6.0 or later toolchain. The package has no dependencies.

```sh
git clone https://github.com/hamanakam1/osprey.git
cd osprey
swift build
swift test
```

Or run everything at once, including the public content guard:

```sh
./scripts/verify.sh
```

To experiment without touching your real state:

```sh
OSPREY_HOME="$(mktemp -d)" .build/debug/osprey status
```

## Proposing a change

1. Open an issue first for anything larger than a bug fix. Say what problem you are trying to solve, not only what you want to build. A design that fits the rule above is much easier to agree on than a patch.
2. Fork the repository and work on a branch with a clear name.
3. Keep the change focused. A pull request that fixes one thing is easier to review than one that fixes three.
4. Open a pull request and fill in the template.

## What a change has to include

- **A test.** Any change in behaviour needs a test that fails without the change. A test that passes either way is not a test.
- **Documentation.** New behaviour belongs in `README.md` or the matching file under `docs/`. A change to what Osprey refuses to do belongs in "What it does not do" as well.
- **A changelog entry.** Under `Unreleased` in `CHANGELOG.md`.
- **A clean public diff.** See below.

## Public content

This repository is public. Assume everything in it is readable by anyone, forever, including in forks, archives and caches.

Never commit:

- terminal transcripts, captured output, session logs, or screenshots of real data;
- credentials, API keys, tokens, private keys, or the contents of `~/.osprey/`;
- internal deployment names, hostnames, account names, or private infrastructure details;
- real ticket data, task identifiers, session identifiers, or ledger contents;
- absolute paths that belong to a specific person or machine.

Use synthetic examples and generic placeholders:

| Instead of | Write |
| --- | --- |
| an absolute path to a person's project folder | `/path/to/project` |
| `~/Applications/Taskrivet.app` | keep it, it is already generic |
| a real session identifier | `<session-id>` or `session-001` |
| a real task identifier | `task-001` |
| a captured terminal line | a short invented line with the same shape |

The `scripts/public_content_guard.py` script checks the documentation and the repository scaffolding for credential-shaped text and for absolute home directory paths. Run it before you push:

```sh
python3 scripts/public_content_guard.py
```

It does not check the source tree, so read your own diff.

## Code style

- Match the surrounding code. The style is plain Swift, no comments that restate the code, and a doc comment on a type or a function that explains why it exists rather than what it does.
- Keep the core library free of behaviour that belongs in a user interface. The command line and the menu bar share `OspreyCore`, and that is what keeps them consistent.
- Keep the core library free of dependencies. The standard library and the system SQLite are enough.
- Use British-neutral plain English in code comments, documentation and commit messages. Short sentences.
- No emoji.

## Tests

```sh
swift test
```

Core tests live in `Tests/OspreyCoreTests/`, and menu-bar behaviour tests live in `Tests/OspreyBarTests/`. They must not need a running Taskrivet, a network, or a real ledger. Where a test needs a filesystem, use a temporary directory, and set `OSPREY_HOME` where the state directory is involved. Menu-bar tests exercise the approval result handler with a temporary evidence store without launching the app or loading the operator's state.

If you change the redaction rules, test each rule and test that the order of the rules still matters. If you change the release manager, test the failure paths, not only the happy path. The whole point of the release manager is what happens when something goes wrong.

## Commit messages

A short summary in the imperative, then a paragraph explaining why if the reason is not obvious.

```text
Reject a token file with group permission bits set

SessionTokenReader already refused any file with the group or other bits
set, but only after the file had been opened. Read the attributes first so
that a file we will not use is never opened at all.
```

## Licence

By contributing you agree that your contribution is licensed under the MIT licence, the same as the rest of the project. See [LICENSE](LICENSE).

## Reporting a problem

A bug is an issue. Use the `bug report` template, and remember not to paste private material.

If you think you have found a security problem, do not open a public issue. Follow [SECURITY.md](SECURITY.md).

## Behaviour towards other people

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
