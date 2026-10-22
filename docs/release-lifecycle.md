# Release lifecycle

Osprey can verify, install and roll back the Taskrivet desktop application on this Mac. The rule is the same one the rest of Osprey follows: prepare, check, then act, and be able to undo.

## The commands

```sh
osprey release verify --bundle /path/to/Taskrivet.app
osprey release install --bundle /path/to/Taskrivet.app
osprey release install --bundle /path/to/Taskrivet.app --no-smoke-test
osprey release rollback
osprey release rollback --backup /path/to/a/backup/Taskrivet.app
osprey release backups
osprey release receipts
```

## The bundle layout

Osprey expects a standard macOS application bundle:

```text
Taskrivet.app/
  Contents/
    Info.plist
    MacOS/
      Taskrivet            <- the executable named by CFBundleExecutable
    Resources/
      core/
        taskrivet/         <- the packaged Python core
```

## Step 1: verify

`osprey release verify --bundle <path>` reads `Contents/Info.plist` and checks the bundle.

| Check | Where | What it means when it fails |
| --- | --- | --- |
| The bundle exists | `Contents/Info.plist` | The path is not an application bundle at all. |
| Bundle identifier | `CFBundleIdentifier` | The identifier is missing or empty. |
| Short version string | `CFBundleShortVersionString` | The version is missing or empty. |
| Build number | `CFBundleVersion` | Read, but reported as `unknown` rather than a problem. |
| Executable | `Contents/MacOS/<CFBundleExecutable>` | The executable is missing or is not executable. The default name is `Taskrivet` when the key is absent. |
| Packaged core | `Contents/Resources/core/taskrivet` | The Python core is not in the bundle. |

A bundle with any problems is not usable, and `osprey release install` refuses it before touching the installed application.

The report also shows the identifier, the version and the build, which is what `osprey status` uses to describe the installed build.

## Step 2: back up

When an app is already installed at `~/Applications/Taskrivet.app`, `osprey release install` copies it first:

```text
~/.taskrivet/app-backups/<yyyyMMdd-HHmmss>/Taskrivet.app
```

The timestamp is local time, in a fixed format, so backups sort correctly by name. If nothing is installed, there is nothing to back up and the install continues.

A copy is made rather than a move, so the installed application stays usable until the new one is in place.

## Step 3: install

The new bundle is copied to a staging directory beside the installed path:

```text
~/Applications/.osprey-staging-<uuid>/
```

Then the installed application is removed and the staging directory is moved into its place.

Using a staging directory means the copy happens somewhere else first. A failure part-way through the copy does not leave a partly written `Taskrivet.app` in place.

If the copy or the move fails, Osprey removes the staging directory, restores the backup, and reports the failure.

## Step 4: smoke test

After the install, Osprey runs the packaged Python core to prove the build actually works.

```text
<python> -m taskrivet --db <temporary directory>/smoke.sqlite status
```

with `PYTHONPATH` set to the bundle's `Contents/Resources/core`, and the working directory set to that same folder.

Details that matter:

- **The database is throwaway.** It is a new SQLite file in a fresh temporary directory. The real ledger at `~/.taskrivet/ledger.sqlite` is never opened.
- **The temporary directory is removed** when the check finishes, pass or fail.
- **The check is a real run.** It imports the packaged core and asks it for a ledger status. A bundle whose core cannot start fails here.
- **A missing or too-old Python** fails the check with a clear message.

## Step 5: roll back on failure

If the smoke test fails:

1. The newly installed bundle is removed.
2. The backup is moved back into `~/Applications/Taskrivet.app`.
3. The outcome reports that the previous build was restored.

If there was no backup, because no app was installed before, the failed bundle is still removed. The machine is left without an application rather than with a broken one.

### `--no-smoke-test`

`osprey release install --no-smoke-test` installs without running the check.

This is the only way to install a build that Osprey cannot verify. There is then no automatic rollback on failure, because nothing failed a check. The outcome says plainly that the install happened without a smoke test.

Use it when you know why the check would not run on this machine, such as a Python environment Osprey cannot see. Do not use it to skip a check you have not understood.

## Step 6: rollback on request

`osprey release rollback` restores a previous build.

| Command | Effect |
| --- | --- |
| `osprey release rollback` | Restore the most recent backup. |
| `osprey release rollback --backup <path>` | Restore that specific backup. |

The current application is moved aside to a temporary directory first, the backup is copied into place, and the temporary directory is removed. If the copy fails, the current application is moved back.

`osprey release backups` lists the backups that can be restored, newest first.

## Receipts

A receipt records a release action. The install path writes one; the receipt format has room for `verified`, `installed`, `rolledBack` and `failed`.

| Field | Meaning |
| --- | --- |
| `id` | The receipt identifier. |
| `action` | `verified`, `installed`, `rolledBack` or `failed`. |
| `occurredAt` | When it happened. |
| `version` | The bundle version. |
| `source` | Where the bundle came from. |
| `backupPath` | The backup that was taken or restored. |
| `installedPath` | Where the application was installed. |
| `smokeTest` | The result of the smoke test, if it ran. |
| `detail` | A sentence describing what happened. |

`osprey release receipts` prints them, newest first. They are kept locally in the same SQLite database as everything else.

## A full session

```sh
# Check the bundle before touching anything.
$ osprey release verify --bundle /path/to/Taskrivet.app
Bundle:      /path/to/Taskrivet.app
Identifier:  <bundle identifier>
Version:     1.2.0 (build 42)
Executable:  present
Python core: present
Usable:      yes

# Install it. The current build is backed up first.
$ osprey release install --bundle /path/to/Taskrivet.app
Backed up the installed build to ~/.taskrivet/app-backups/20260101-101500/Taskrivet.app
Installed to ~/Applications/Taskrivet.app
Smoke test:  the packaged core answered a ledger status read
Result:      installed

# Check the receipts.
$ osprey release receipts
2026-01-01 10:15:02  installed  1.2.0 (42)  /path/to/Taskrivet.app

# Something is wrong. Put the old build back.
$ osprey release rollback
Restored ~/Applications/Taskrivet.app from
~/.taskrivet/app-backups/20260101-101500/Taskrivet.app
```

## Recovery runbook

**The install failed and the app is gone.**

Check the backups:

```sh
osprey release backups
```

Restore the newest one:

```sh
osprey release rollback
```

**The smoke test fails on every build.**

The check runs the packaged Python core against a throwaway database. A failure usually means the bundle is missing its core, or that the core cannot start on this machine. Run the check by hand to see the full error:

```sh
PYTHONPATH=/path/to/Taskrivet.app/Contents/Resources/core \
  python3 -m taskrivet --db /tmp/osprey-check.sqlite status
```

**The install path is wrong.**

The default is `~/Applications/Taskrivet.app`. If Taskrivet is installed elsewhere, install it into the default location or move it afterwards. The release manager resolves the path from the home directory, and does not read a configuration file.

**A backup is taking too much space.**

Each backup is a full copy of the application bundle. Removing an old backup folder by hand is safe; nothing else refers to it except the receipts.

```sh
rm -rf ~/.taskrivet/app-backups/<timestamp>
```

## What Osprey does not do

- It does not sign, notarise, or staple the application.
- It does not build the bundle. It verifies what somebody else built.
- It does not distribute the application anywhere.
- It does not upload a receipt, a crash report, or a diagnostic bundle.
- It does not install anything outside `~/Applications/Taskrivet.app` and `~/.taskrivet/app-backups/`.
