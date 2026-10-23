# Taskrivet integration

Osprey touches Taskrivet in two places: the local session service, which it reads from, and the ledger command-line tool, which it writes to after an approval. This document describes both interfaces, exactly as the code uses them.

Osprey does not claim compatibility with any AI provider, agent, or terminal user interface. The only thing it speaks to is Taskrivet's own local service and Taskrivet's own command-line tool.

## The session service

### Where it lives

Taskrivet derives a runtime directory from the ledger database path:

```text
~/.taskrivet/sessions-<first 12 hex characters of sha256(resolved database path)>/
```

The resolved path is the absolute, symlink-resolved, standardised path of the ledger database. Osprey reproduces the same derivation, with the same hash, so it finds the live socket without being told where it is.

Inside that directory:

| File | Purpose |
| --- | --- |
| `sessions.sock` | The Unix stream socket. Mode 0600. |
| `token` | The shared secret. A regular file whose group and other permission bits must be clear. |

The directory itself is mode 0700 and owned by the account that runs Taskrivet.

Osprey resolves the database path the same way for both purposes. `TASKRIVET_DB` changes it, and therefore changes the socket Osprey looks for. If you set `TASKRIVET_DB` for Osprey, set it to the same value Taskrivet uses, or the two will look in different places.

### The line protocol

One JSON object per line, in both directions, terminated by a newline. The maximum frame the service accepts is 32 MiB.

The first message on a connection must be the handshake:

```json
{"id": 1, "op": "hello", "token": "<token from the token file>", "version": 1}
```

The service accepts the connection only if the operation is `hello`, the token matches, and the version is 1. Otherwise it destroys the connection. A connection that has not authenticated within three seconds is destroyed.

The reply carries the request identifier:

```json
{"id": 1, "result": {"version": 1, "pid": 1234}}
```

A failure carries an error string:

```json
{"id": 2, "error": "Unknown terminal; no command was replayed"}
```

### Requests Osprey sends

| Request | Purpose |
| --- | --- |
| `hello` | Authenticate. Sent once, immediately after connecting. |
| `list` | List the tabs the service owns. Sent once per capture. |

That is the whole list. The service also implements `create`, `write`, `resize`, `stop` and `remove`. Osprey does not implement them, and there is no code path that could send them. Osprey cannot type into a terminal, resize one, stop one, or close one.

### Events the service pushes

```json
{"event": "terminal:data", "payload": {"id": "<terminal-id>", "seq": 12, "data": "..."}}
{"event": "terminal:exit", "payload": {"id": "<terminal-id>", "exitCode": 0}}
```

`terminal:data` carries the text since the last chunk. `terminal:exit` says the process finished. Osprey records the exit and continues; it does not close or clean anything up, because the tabs belong to Taskrivet.

### The tab snapshot

```json
{
  "id": "<terminal-id>",
  "cwd": "/path/to/project",
  "task": "<task-id>",
  "session": "<session-id>",
  "shell": "/bin/zsh",
  "state": "running",
  "exitCode": null,
  "chunks": [{"seq": 1, "data": "..."}],
  "pid": 4242,
  "title": "build-check",
  "kind": "opencode",
  "ref": "<opaque reference>"
}
```

Osprey decodes the fields it knows and ignores the rest. `task`, `session`, `title` and `kind` may be absent or null.

The `chunks` array is the bounded tail the service keeps so that a reconnecting client sees recent output. Osprey reads it at the start of a capture so that a proposal can be drafted even when nothing new arrives during the follow window.

### Reading the token

Osprey checks the token file before reading it:

- it must be a regular file;
- its group and other permission bits must all be clear.

If either check fails, Osprey refuses and says so. It will not read a secret that other accounts on the machine could read.

### Timeouts

A request that is not answered within ten seconds fails with a protocol error rather than hanging. The capture window itself is separate: it is the `--seconds` value, default 5.

## The ledger

### Reading

Osprey reads the ledger by running the Taskrivet command-line tool:

```text
<python> -m taskrivet --db <ledger path> status
```

The status payload contains a `sessions` array. Osprey reads the session identifier, the task identifier, the token count and the status from it. The same read is the one the desktop inspector uses.

Osprey does not open the ledger database itself. It has no SQLite connection to the Taskrivet ledger, so the only way it can write is through the same interface every other Taskrivet client uses.

### Writing

A write happens only after an explicit approval: `osprey approve <id> --yes` or the menu bar's Approve action.

```text
<python> -m taskrivet --db <ledger path> checkpoint <session> \
    --summary <text> --evidence <text> --next <text> --tokens <count>

<python> -m taskrivet --db <ledger path> fail <session> \
    --category <category> --summary <text>
```

The argument vector is built directly. There is no shell, so a summary or an evidence string cannot become a command. The subprocess runs with `PYTHONPATH` set to the core root and with that directory as the working directory, so the packaged core imports without being installed.

### Verifying the write

After the command exits successfully, Osprey reads the session back from the ledger and compares:

| Proposal | Confirmed when |
| --- | --- |
| Checkpoint | The readback reports the same token count that was written. |
| Failure | The readback reports the status `failed`. |

The result is reported as verified or not. Both the command line and the menu bar mark a verified proposal `applied`. When readback does not confirm the write, they mark the proposal `failed`, leave its applied time unset, and retain the verification detail in its note. The menu displays a failure message. A failed verification does not mean the ledger write was undone; inspect the ledger before approving again. Osprey does not retry, and it does not write twice.

Saving that outcome must update an existing local proposal. If the proposal
was removed before or during the state update, Osprey does not recreate it.
The command line and menu bar report that no local outcome was recorded,
without claiming that the proposal was applied or marked failed. SQLite
update failures also surface as storage errors. The ledger may already
contain the record; inspect it before retrying.

Every ledger command, including status reads, must exit with status zero
before Osprey uses its output. A nonzero exit raises a command error even
when stdout contains valid JSON or the session's previous state already
matches the expected token count or failure status. The error identifies the
operation and exit status without including proposal text or raw subprocess
output. Osprey does not retry automatically. A failed command may have changed
the ledger before exiting; inspect its state before approving again.

### Token counts

The token count in a ledger checkpoint is cumulative for the session and cannot decrease. The ledger rejects a lower count.

Osprey does not measure usage. It carries the session's current count forward, unless the operator states a new one with `osprey approve --tokens N`. The number written is the larger of the two values.

Every proposal says this in its own evidence text: reported token usage is not measured by Osprey.

### Finding the Python core

The core is the folder that contains the `taskrivet` Python package. Osprey searches, in order:

1. `TASKRIVET_CORE`, if it is set and contains a `taskrivet` package;
2. `~/Projects/taskrivet`;
3. `~/Projects/Taskrivet`;
4. `~/.taskrivet/core`;
5. `/Applications/Taskrivet.app/Contents/Resources/core`;
6. `~/Applications/Taskrivet.app/Contents/Resources/core`.

When nothing matches, the error lists every path that was tried.

### Finding Python

Osprey looks for an interpreter at:

1. `/opt/homebrew/bin/python3`;
2. `/usr/local/bin/python3`;
3. `/usr/bin/python3`.

It takes the first whose version is 3.11 or newer. The ledger and the release smoke test both need one. When none is found, the error says so.

## Environment variables

| Variable | Used by | Default |
| --- | --- | --- |
| `OSPREY_HOME` | Osprey state directory | `~/.osprey` |
| `TASKRIVET_DB` | Ledger path, and therefore the runtime directory and socket | `~/.taskrivet/ledger.sqlite` |
| `TASKRIVET_CORE` | Python core root | searched, see above |

## What Osprey does not read

- It does not open the Taskrivet ledger database.
- It does not read the Taskrivet task files, the context packets, or the event trail beyond the status read.
- It does not read anything about the agent that a tab is running, beyond the tab's own `kind` and `ref` fields.
- It does not read provider settings, credentials, or configuration.
- It does not read chat transcripts or messages. Terminal output is output, and it is only what the tab printed.

## Failure behaviour

| Situation | Result |
| --- | --- |
| The socket does not exist | The capture stops with the socket path and the reason. Nothing is stored. |
| The socket path is too long for a local socket | The connection is refused with a clear message. |
| The service closes the connection | Pending requests fail with a connection-lost error. |
| The service answers with an error | The error string is reported. |
| The service does not answer within ten seconds | A protocol error is raised. |
| The token file is not a regular file | The token is not read. |
| The token file has loose permissions | The token is not read. |
| The token is empty | The token is not read. |
| The core is missing | The ledger write does not happen. |
| Python is missing | The ledger write does not happen. |
| A ledger command exits nonzero | Osprey reports the operation and exit status and stops. Its output is not treated as a successful read or confirmed write. |
| The terminal has no ledger session | The proposal cannot be applied, and says why. |
