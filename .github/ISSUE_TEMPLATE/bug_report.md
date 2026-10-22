---
name: Bug report
about: Something in Osprey does not behave as documented
title: ""
labels: bug
assignees: ""
---

## What happened

<!-- A short description of the failure. -->

## What was expected

<!-- What the documentation says should happen, and where it says so. Link the doc and the section. -->

## Environment

| | |
| --- | --- |
| macOS version | <!-- `sw_vers` --> |
| Swift version | <!-- `swift --version` --> |
| Osprey version | <!-- `osprey status`, or the commit you built --> |
| Taskrivet version | <!-- The Taskrivet desktop build you are using, if any --> |

## Output of `osprey doctor`

<!--
Paste the output here. It contains no terminal output and no credentials.
If it does, remove the relevant lines before pasting.
-->

```text

```

## Steps to reproduce

1.
2.
3.

## Additional context

<!--
Anything else that helps: the exact command, the exact output, the exact error text.
-->

## What we must not receive

Please do not paste:

- terminal transcripts, or raw output from a captured tab;
- credentials, API keys, tokens, or parts of a private key;
- the contents of your Taskrivet ledger, or real ticket data;
- the contents of `~/.osprey/evidence.sqlite`;
- screenshots or logs that contain any of the above.

Synthetic examples are welcome and are easier to act on. If a transcript is needed to show the problem, describe the shape of it instead, for example "a line that looks like `sk-` followed by 30 characters".
