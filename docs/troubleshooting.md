# Troubleshooting

Start with `osprey doctor`. It checks the Python interpreter, the Taskrivet core, the session socket, the token file permissions, and the evidence store, and it names what it looked for.

```sh
osprey doctor
```

## Capture problems

### `The Taskrivet session service is not reachable at <path>: <reason>`

The socket does not exist, or nothing is listening on it.

- Start the Taskrivet desktop app. The session service runs inside it.
- If Taskrivet is running but you still get this, the two processes are looking at different ledger databases. Taskrivet derives the socket location from the ledger path, so a difference in `TASKRIVET_DB` means a different socket. Set the same value for both, or unset it for both.
- The socket path is also in the message. Check that the directory exists:

  ```sh
  ls -la ~/.taskrivet/sessions-*/
  ```

### `The session token file is readable by other users. Refusing to read it.`

The token file permissions are too wide. Osprey will not read a secret that other accounts on the machine could read.

```sh
chmod 600 ~/.taskrivet/sessions-*/token
```

### `The session token is not a regular file.`

The token path points at something other than a file, usually a symbolic link or a directory. Remove it and restart Taskrivet, which writes a fresh token.

### `The session token file is empty.`

Same remedy. Restart Taskrivet.

### `The session service rejected the local token.`

The token on disk does not match the one the running service is using. This happens when the service was restarted and the token was regenerated, or when the token file was edited by hand. Restart Taskrivet so that it writes a fresh token.

### `No Taskrivet tabs matched the selection, so nothing was captured.`

The terminal identifier is wrong, or the tab has exited.

```sh
osprey terminals
```

Use an identifier from that list. Note that the listing shortens the identifier for readability, while `--terminal` needs the whole value. Use `osprey terminals --json` to get it.

With no `--terminal`, Osprey follows every tab whose state is `running`, so an exited tab is skipped.

### The capture returns nothing but the terminal is busy

The capture window is short. The default is five seconds. Give it longer:

```sh
osprey capture --terminal <id> --seconds 30
```

Osprey also reads the tail the service keeps before it starts listening, so a tab that produced output before the capture still contributes.

### The proposal is empty or vague

The summary is built by matching text, not by understanding the output. If the output has no recognisable command lines, the summary says so. If it has no failure-shaped lines, no failure draft is produced. This is the intended behaviour, not a fault.

## Proposal and approval problems

### `osprey approve` prints the record and does nothing

That is what it does without `--yes`. The command shows the record it would write and stops, so that applying a draft is a separate, explicit act. Run it again with `--yes` when you are satisfied.

### `osprey propose` says there is nothing to draft

The command reads the evidence already stored. Capture first:

```sh
osprey capture --all --seconds 10
osprey propose
```

When the session service is unreachable, `osprey propose` falls back to the terminals recorded in the evidence store, so it still works after Taskrivet has quit.

### `This terminal is not linked to a Taskrivet ledger session, so there is no record to write.`

The tab was opened without a task assignment, so there is no ledger session for the record to belong to. Assign the tab to a task in Taskrivet, then capture again.

The proposal itself is still stored and can be read with `osprey show <id>`.

### `The Taskrivet Python core was not found. Set TASKRIVET_CORE to the folder that contains the taskrivet package. Looked in: ...`

The error lists every path that was tried. Either put the core where Osprey looks, or name it:

```sh
export TASKRIVET_CORE=/path/to/the/folder/that/contains/taskrivet
```

The named folder must contain a `taskrivet` package directory.

### `Python 3.11 or newer is required to write to the Taskrivet ledger.`

Osprey looks for an interpreter at `/opt/homebrew/bin/python3`, `/usr/local/bin/python3` and `/usr/bin/python3`, and takes the first that is 3.11 or newer.

- Check what you have: `python3 --version`.
- If your interpreter lives somewhere else, put a symlink to it at one of those paths, or make the default `python3` on your machine be 3.11 or newer.
- The system Python at `/usr/bin/python3` is often too old.

### The approval reports that the write was not verified

The ledger accepted the command, but the readback did not show what Osprey expected. For a checkpoint, the readback token count did not match the count that was written. For a failure, the session status was not `failed`.

Check the ledger directly with the Taskrivet command-line tool:

```sh
python3 -m taskrivet --db ~/.taskrivet/ledger.sqlite status
```

The proposal is still recorded, with the outcome and the detail text.

### The approval fails with a token count error

The ledger requires the token count to be cumulative and to never decrease. Osprey carries the session's current count forward unless you state a new one with `--tokens N`, and writes the larger of the two. If you pass a smaller number, the ledger rejects it. Use `--tokens N` with the new cumulative total, not the increment.

## Release problems

### `The bundle is not usable: ...`

The reported problems name what is missing. The expected layout is in [release-lifecycle.md](release-lifecycle.md). In short:

- `Contents/Info.plist` with `CFBundleIdentifier` and `CFBundleShortVersionString`;
- `Contents/MacOS/<CFBundleExecutable>` present and executable;
- `Contents/Resources/core/taskrivet` present.

### The smoke test fails

The check runs the packaged Python core against a throwaway database. Run it by hand to see the full error:

```sh
PYTHONPATH=/path/to/Taskrivet.app/Contents/Resources/core \
  python3 -m taskrivet --db /tmp/osprey-check.sqlite status
```

Common causes:

- Python 3.11 or newer is not available to Osprey;
- the bundle's core is missing or incomplete;
- the core imports something that is not in the bundle.

### The install succeeded but the app will not start

The smoke test checks that the packaged core runs. It does not check the whole application.

- Look at the receipts: `osprey release receipts`.
- Roll back: `osprey release rollback`.
- Check the backups: `osprey release backups`.

### `No Taskrivet backup was found in <path>.`

There is nothing to roll back to. A backup is created the first time an install runs over an existing application. Install once, or pass `--backup <path>` to a backup you already have.

### The installed application is not where I expect

The default install path is `~/Applications/Taskrivet.app`. Osprey does not read a configuration file for this. If Taskrivet lives somewhere else, install it to the default path, or move it afterwards.

## Store problems

### The evidence store will not open

The state directory or the database file is not writable.

```sh
ls -ld ~/.osprey ~/.osprey/evidence.sqlite
```

The state directory should be owned by you with mode 0700.

### The store is empty after a capture

Check the capture output. A capture that matched no tabs stores nothing, and a capture with `--dry-run` always stores nothing.

### I want the store gone

```sh
rm -rf ~/.osprey
```

See [privacy.md](privacy.md) for what that removes and what it does not.

## Reporting a problem

Open an issue with the `bug report` template. Include the output of:

```sh
osprey doctor
sw_vers
swift --version
```

Do not paste terminal transcripts, credentials, or anything from your Taskrivet ledger. Synthetic examples are fine and are much more useful.
