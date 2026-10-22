# Pull request

Thank you for taking the time. Please fill in the sections below.

## What this changes

<!-- One or two sentences. What a reader will notice after merging. -->

## Why

<!-- The problem being solved. Link the issue, if there is one. -->

## How to check it

<!--
The exact commands to run, and what a reviewer should see.
If the change is visible in the command line, show the before and the after.
-->

## Checklist

- [ ] The change is described above, and the description is understandable without reading the diff.
- [ ] Behaviour changes come with a test that fails without the change.
- [ ] The test suite passes: `swift test`.
- [ ] The build passes: `swift build`.
- [ ] New behaviour is documented in `README.md` or the matching file under `docs/`.
- [ ] `CHANGELOG.md` has an entry under `Unreleased`.
- [ ] Public content contains no private transcripts, no credentials, no internal deployment names, and no real ticket data.
- [ ] Any path that appears in the public content is a generic placeholder, such as `~/Applications/Taskrivet.app` or `/path/to/Taskrivet.app`.
- [ ] Every example is synthetic. No output is copied from a real terminal, ledger, or ticket.
- [ ] `python3 scripts/public_content_guard.py` passes.

## Public content

This repository is public. Before you submit, check the diff for:

| Never include | Instead |
| --- | --- |
| Terminal transcripts, captured output, or session logs | A synthetic example with the same shape |
| Credentials, API keys, tokens, private keys | A description of the shape, such as `sk-` followed by 30 characters |
| Internal deployment names, hostnames, or account names | A generic name, or `example` |
| Real ticket data, task identifiers, or session identifiers | `task-001`, `session-001`, `<terminal-id>` |
| Absolute paths belonging to a person or a specific machine | `~/Applications/Taskrivet.app`, `/path/to/Taskrivet.app` |
| Screenshots of real data | Nothing, or a synthetic mock-up |

The public content guard checks the documentation and the repository scaffolding for credential-shaped text and for absolute home directory paths. It does not check the source tree, so read your own diff.

## Rules for behaviour

- A change in behaviour needs a test. Not a test that passes either way, and not a test that only checks the implementation shape.
- A change in what Osprey refuses to do needs a line in `README.md` under "What it does not do", and in the relevant document under `docs/`.
- A change to the on-disk format needs a migration, or a note in `CHANGELOG.md` saying that existing state must be deleted.
- A change that adds a dependency needs its own discussion in an issue first. The package currently has none, and that is deliberate.
- Keep the rule intact: Osprey observes and proposes. A human decides. A change that lets Osprey act without a command is not a small change.
