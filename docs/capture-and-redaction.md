# Capture and redaction

This document describes what Osprey does when it captures terminal output, how much it keeps, and what the redaction rules remove.

## The pipeline

```text
  Taskrivet tab output
          |
          |  bounded tail, then live chunks
          v
     ANSI stripping
          |
          v
    secret-shaped rules
          |
          v
    local evidence store   <-- nothing is written before this point
          |
          v
   checkpoint and failure drafts
          |
          v
   waiting for osprey approve
```

The order matters. ANSI stripping runs first so that secret text hidden inside escape sequences cannot hide from the rules. The rules run before the write, so a secret is not stored and then forgotten.

## Step by step

### 1. Connect

Osprey opens the Unix socket at `~/.taskrivet/sessions-<hash>/sessions.sock` and sends a `hello` message:

```json
{"id": 1, "op": "hello", "token": "<the local token>", "version": 1}
```

The token comes from the `token` file in the same directory. The service destroys the connection if the token is wrong or the protocol version is not 1.

### 2. List

Osprey sends `{"id": 2, "op": "list"}` and receives one snapshot per tab. The fields Osprey reads are:

| Field | Use |
| --- | --- |
| `id` | The terminal identifier used by `--terminal`. |
| `cwd` | The working directory, quoted in the evidence note. |
| `task` | The Taskrivet task identifier, when the tab is assigned to one. |
| `session` | The Taskrivet ledger session identifier. Without it, a proposal cannot be applied. |
| `shell` | Used for the display title when there is no title and no task. |
| `state` | `running` tabs are the default selection. |
| `exitCode` | Recorded on the tab snapshot. |
| `pid` | Recorded on the tab snapshot. |
| `title` | Used for the display title. |
| `kind` | For example `opencode` for an agent tab. |
| `ref` | An opaque reference from the desktop app. |
| `chunks` | The bounded output tail the service keeps for reconnecting clients. |

Unknown fields are ignored, so a newer Taskrivet build does not break an older Osprey.

### 3. Select

| Invocation | Selection |
| --- | --- |
| `osprey capture` | Every tab whose state is `running`. |
| `osprey capture --all` | The same default, stated explicitly. |
| `osprey capture --terminal <id> --terminal <id2>` | Exactly the named tabs, running or not. |
| `osprey capture --dry-run` | The same selection, but nothing is written. |

`--terminal` takes the full terminal identifier. `osprey terminals` prints a shortened one for readability, so use `osprey terminals --json` when you need the whole value.

A dry run does not follow live output. It reads the buffered tail of each selected tab, redacts it, prints it, and reports how many values would have been redacted. Nothing is stored, and no proposal is drafted.

If the selection matches nothing, the capture stops with a message and stores nothing.

### 4. Read the tail

The service keeps a bounded tail per tab so that a reconnecting client sees recent output. Osprey reads that tail first. Without it, a tab that had already finished would produce nothing to draft from.

The tail is truncated to the capture size limit.

### 5. Follow live output

For `--seconds N` (default 5), Osprey listens for `terminal:data` events and accumulates them per tab. The accumulated text for one tab is capped at the capture size limit, and when the cap is reached the oldest text is dropped, because the most recent output is the most useful output.

`terminal:exit` events end a tab. Osprey records them but does not act on them.

### 6. Redact

Every chunk is redacted on its own. See the rules below.

### 7. Store

The redacted text is written to the evidence table, one row per chunk, with the terminal identifier, the capture time, the byte count and the redaction count.

### 8. Draft

Osprey reads the evidence for each selected tab back out of the store, limited to the record limit, and builds:

- a **checkpoint** draft, when there is any captured output;
- a **failure** draft, when the output contains failure-shaped text.

Both drafts are stored in the proposals table with the state `proposed`. Neither reaches the ledger.

### 9. Wait

The draft sits in the store until a person approves it.

## Limits

| Limit | Value | Where it comes from |
| --- | --- | --- |
| Live text kept per tab | 256,000 bytes | Capture coordinator option |
| Buffered tail kept per tab | 256,000 bytes | Capture coordinator option |
| Evidence records read per tab when drafting | 400 | Capture coordinator option |
| Capture duration | 5 seconds by default | Capture coordinator option |
| Summary length | 240 characters | Proposal engine option |
| Evidence note length | 400 characters | Proposal engine option |
| Commands quoted in a summary | 3 | Proposal engine option |
| Command-shaped lines collected | 40 | Redactor heuristic |
| Failure-shaped lines collected | 20 | Redactor heuristic |
| Command-shaped line length | 3 to 240 characters | Redactor heuristic |
| Failure-shaped line length | 8 to 240 characters | Redactor heuristic |

The numbers are options on the core types, so a caller can change them. The values above are the defaults.

## ANSI stripping

Terminal output carries colour, cursor movement and title sequences. The stripper removes:

- OSC sequences, from `ESC ]` up to a bell or `ESC \`;
- CSI sequences, from `ESC [` through the final byte;
- other two-character escape sequences.

What remains is plain text. This makes the stored evidence readable, and it removes a way for secret text to hide.

## Redaction rules

The rules run in the order below, each on the output of the previous one. A match is replaced by `[<rule-name> REDACTED]`.

| Order | Rule | Matches |
| --- | --- | --- |
| 1 | `private-key` | A PEM private key block, from the `BEGIN` line to the `END` line. |
| 2 | `github-token` | `ghp_`, `gho_`, `ghu_`, `ghs_` or `ghr_` followed by 16 to 255 letters or digits. |
| 3 | `openai-key` | `sk-` followed by 20 or more letters, digits, underscores or hyphens. |
| 4 | `anthropic-key` | `sk-ant-` followed by 20 or more letters, digits, underscores or hyphens. |
| 5 | `aws-access-key` | `AKIA` followed by 16 upper-case letters or digits. |
| 6 | `google-api-key` | `AIza` followed by 35 letters, digits, underscores or hyphens. |
| 7 | `slack-token` | `xoxb-`, `xoxa-`, `xoxp-`, `xoxr-` or `xoxs-` followed by 10 or more letters, digits or hyphens. |
| 8 | `jwt` | Three dot-separated base64url segments, each at least 10 characters. |
| 9 | `bearer-token` | `Bearer` followed by whitespace and 16 or more token characters. |
| 10 | `authorization-header` | `Authorization:` and everything to the end of the line. |
| 11 | `assigned-secret` | `api_key`, `apikey`, `api-key`, `secret`, `passwd`, `password` or `token` followed by `:` or `=` and a value of 6 or more characters. |
| 12 | `basic-auth-url` | A URL of the form `scheme://user:password@host`. The user and password parts are removed and the rest of the URL is kept. |

### What a replacement looks like

```text
before: export GH_TOKEN=ghp_<40 lower-case letters>
after:  export GH_TOKEN=[github-token REDACTED]
```

The marker names the rule. It never contains the secret, and it never contains the length of the secret, because a length is a hint.

The number of replacements is stored with the evidence record. A capture that removed something tells you so, without telling you what.

### Ordering matters

`openai-key` runs before `anthropic-key`. An Anthropic key starts with `sk-ant-`, which also matches the shorter `sk-` rule. Because the OpenAI rule runs first, an Anthropic key is reported as `anthropic-key` rather than as a generic `openai-key`.

### The limits of shape matching

These rules match shapes, not meanings.

- A secret in an unusual shape is not matched. A base64 blob with no key prefix, a password typed at a prompt, or a URL-encoded credential can pass through.
- A rule that is too broad will remove text that was not a secret. `assigned-secret` matches any line that mentions `token` followed by a colon and a value, which includes some harmless configuration output.
- `authorization-header` removes the rest of the line, which may include useful context.

Redaction lowers the risk. It does not remove it. Treat the evidence store as sensitive material.

## Heuristics for the summary

The proposal engine needs a short human-readable summary. It gets one from two heuristics.

### Command-shaped lines

A line is treated as command-shaped when it is 3 to 240 characters long, does not start with `$ `, and starts with one of a fixed list of command heads: `git`, `npm`, `pnpm`, `yarn`, `python3`, `python`, `make`, `cargo`, `swift`, `go`, `docker`, `kubectl`, `psql`, `sqlite3`, `pytest`, `npm test`, `cd`, `ls`, `rg`, `grep`.

Consecutive duplicates are collapsed, and at most 40 are collected.

### Failure-shaped lines

A line is treated as failure-shaped when it is 8 to 240 characters long and contains one of: `error:`, `Error:`, `fatal:`, `FAILED`, `Traceback (most recent call last)`, `panic:`, `command not found`, `Permission denied`, `exit code 1`.

Consecutive duplicates are collapsed, and at most 20 are collected.

### What this is not

This is text matching, not command parsing. It does not know whether a line was typed by a person or printed by a tool. It does not know whether the command succeeded. It is used to give you something to read, so that you can decide whether the draft is worth approving.

## Worked example

A synthetic capture of one tab. The tab was opened in a project directory with a task assignment and a ledger session.

```text
$ swift build
Build complete! (3.42s)
$ swift test
Executed 12 tests, with 0 failures
error: no such module 'TaskrivetCore'
```

The redacted and stored evidence for that tab looks like this:

```text
Build complete! (3.42s)
Executed 12 tests, with 0 failures
error: no such module 'TaskrivetCore'
```

The draft built from it:

```text
kind:     checkpoint
terminal: <terminal-id> (build-check)
session:  <session-id>
summary:  Terminal output shows: swift build; swift test. Failure text present: error: no such module 'TaskrivetCore'
evidence: Osprey capture: terminal <terminal-id> (build-check) in /path/to/project;
          132 bytes across 3 lines; 0 redaction(s) applied; captured
          2026-01-01T00:00:00Z to 2026-01-01T00:00:00Z. Redacted capture retained
          locally by Osprey. Reported token usage is not measured by Osprey.
next:    Operator to confirm the next step for this task.
tokens:  0
note:    Drafted from terminal output. Not verified progress, and not a claim that
         the task is complete.
```

And the failure draft, built from the same evidence:

```text
kind:     failure
summary:  Captured terminal output reported: error: no such module 'TaskrivetCore'
category: terminal_output
note:     Drafted from terminal output. A recorded failure is not a diagnosis.
```

Neither draft has been applied. Running `osprey approve <proposal-id>` writes one of them to the ledger and reads the session back to confirm.

## Testing the redaction

`osprey redact [text...]` shows what the rules do to a string. It is the quickest way to check a pattern you are unsure about.

```sh
$ osprey redact 'export TOKEN=ghp_<40 lower-case letters>'
export TOKEN=[github-token REDACTED]
```

Use it before you capture anything you are unsure about. It uses the same code path as a capture, so what it shows is what will be stored.
