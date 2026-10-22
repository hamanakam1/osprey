#!/usr/bin/env python3
"""Check the public content of this repository.

This repository is public, so everything in it can be read by anyone, forever.
This script looks for three kinds of thing that should not be here:

1. credential-shaped text,
2. absolute home directory paths,
3. links to places other than an allowlist.

By default it checks the documentation and the repository scaffolding. Pass
``--all`` to include the source tree as well.

Run it from the repository root:

    python3 scripts/public_content_guard.py
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# --------------------------------------------------------------------------
# What to look at
# --------------------------------------------------------------------------

SKIP_DIRECTORIES = {
    ".git",
    ".build",
    ".swiftpm",
    "dist",
    "node_modules",
    "__pycache__",
}


def is_skipped(part: str) -> bool:
    """Build and tooling directories, whatever they are called."""
    return part in SKIP_DIRECTORIES or part.startswith(".build")

TEXT_SUFFIXES = {".md", ".txt", ".yml", ".yaml", ".sh", ".py", ".json", ".swift"}

# The guard itself contains the patterns it looks for.
SELF = Path(__file__).resolve()

# --------------------------------------------------------------------------
# What to look for
# --------------------------------------------------------------------------

CREDENTIAL_PATTERNS = [
    ("private key block", re.compile(r"-----BEGIN[ A-Z]*PRIVATE KEY-----")),
    ("github token", re.compile(r"gh[pousr]_[A-Za-z0-9]{16,255}")),
    ("anthropic key", re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")),
    ("openai key", re.compile(r"sk-[A-Za-z0-9_-]{20,}")),
    ("aws access key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("google api key", re.compile(r"AIza[0-9A-Za-z_-]{35}")),
    ("slack token", re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}")),
    ("json web token", re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
]

HOME_PATH_PATTERNS = [
    ("macOS home path", re.compile(r"/Users/[^/\s\"'`]+")),
    ("Linux home path", re.compile(r"/home/[^/\s\"'`]+")),
]

URL_PATTERN = re.compile(r"https?://[^\s)\]\"'>]+")

ALLOWED_HOSTS = {
    "github.com",
    "raw.githubusercontent.com",
    "gist.github.com",
    "img.shields.io",
    "swift.org",
    "developer.apple.com",
    "www.python.org",
    "python.org",
    "keepachangelog.com",
    "semver.org",
    "contributor-covenant.org",
    "www.contributor-covenant.org",
    "git-scm.com",
    "www.swiftpackageindex.com",
    "localhost",
    "127.0.0.1",
}


# --------------------------------------------------------------------------
# Collecting files
# --------------------------------------------------------------------------


def is_scanned(path: Path, root: Path, include_source: bool) -> bool:
    """Decide whether a file is part of the check."""
    if path.resolve() == SELF:
        return False
    if path.suffix.lower() not in TEXT_SUFFIXES:
        return False
    relative = path.relative_to(root)
    parts = relative.parts
    if not parts:
        return False
    top = parts[0]
    if include_source:
        return True
    # Default scope: documentation, the repository scaffolding, and the
    # scripts that check them.
    if top in {"docs", ".github", "scripts"}:
        return True
    if top in {"Sources", "Tests"}:
        return False
    return len(parts) == 1


def collect(root: Path, include_source: bool) -> list[Path]:
    found: list[Path] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if any(is_skipped(part) for part in path.relative_to(root).parts):
            continue
        if is_scanned(path, root, include_source):
            found.append(path)
    return found


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------


def host_of(url: str) -> str:
    remainder = url.split("://", 1)[-1]
    host = remainder.split("/", 1)[0].split("?", 1)[0].split("#", 1)[0]
    return host.lower().split("@")[-1].split(":")[0]


def check_file(path: Path, root: Path) -> list[str]:
    problems: list[str] = []
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return problems
    relative = path.relative_to(root)

    for number, line in enumerate(text.splitlines(), start=1):
        for name, pattern in CREDENTIAL_PATTERNS:
            if pattern.search(line):
                problems.append(f"{relative}:{number}: credential-shaped text ({name})")
        for name, pattern in HOME_PATH_PATTERNS:
            if pattern.search(line):
                problems.append(f"{relative}:{number}: absolute home path ({name})")
        for url in URL_PATTERN.findall(line):
            host = host_of(url)
            if host and host not in ALLOWED_HOSTS:
                problems.append(f"{relative}:{number}: link to {host}")
    return problems


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--all",
        action="store_true",
        help="also check the source tree",
    )
    parser.add_argument(
        "--root",
        default=".",
        help="repository root (default: the current directory)",
    )
    arguments = parser.parse_args()

    root = Path(arguments.root).resolve()
    if not root.is_dir():
        print(f"public_content_guard: {root} is not a directory", file=sys.stderr)
        return 2

    files = collect(root, arguments.all)
    problems: list[str] = []
    for path in files:
        problems.extend(check_file(path, root))

    if problems:
        print("public_content_guard: problems found", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(
            "\nThis repository is public. Replace the values above with generic\n"
            "placeholders, such as ~/Applications/Taskrivet.app, /path/to/Taskrivet.app,\n"
            "<terminal-id> or session-001.",
            file=sys.stderr,
        )
        return 1

    scope = "documentation and scaffolding" if not arguments.all else "the whole repository"
    print(f"public_content_guard: checked {len(files)} files ({scope}); no problems found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
