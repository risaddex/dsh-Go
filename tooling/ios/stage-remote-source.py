#!/usr/bin/env python3
"""Stage fork main for a remote-only iOS release, without building or signing."""

import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[2]
FORK_URL = re.compile(r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)risaddex/dsh-go(?:\.git)?/?", re.I)
EXCLUDED_ASSET_DIRS = {
    # Android's AppAuthGuest copies these scripts into its local engine.
    "assets/engine/auth/",
    "assets/engine/auth/siwc/",
    # Omit whole bundles, not only their scripts: their manifests name the scripts.
    "assets/skills/dsh-go-ui/",
    "assets/skills/dsh-go-plugin/",
    "assets/skills/pet-theme/",
}
LOOSE_SCRIPT_SUFFIXES = {".py", ".mjs", ".sh"}


def remote_pubspec(text, app):
    """Validate the repo's flat flutter.assets block before filtering it."""
    flutter = re.search(r"^flutter:\n(?:^[ \t#][^\n]*\n|^\n)*", text, re.M)
    if not flutter:
        raise ValueError("expected a flutter block")
    block = re.search(r"^  assets:[ \t]*\n((?:^ {4,}[^\n]*\n|^\n)*)", flutter[0], re.M)
    if not block:
        raise ValueError("expected a flutter.assets block")
    seen = set()
    kept = []
    for line in block[1].splitlines(keepends=True):
        if not line.strip() or line.lstrip().startswith("#"):
            kept.append(line)
            continue
        match = re.fullmatch(r"    - ([A-Za-z0-9_./-]+)(?:[ \t]+#.*)?\n", line)
        if not match:
            raise ValueError(f"unsupported flutter.assets entry: {line.strip()}")
        entry = match[1]
        if entry in seen:
            raise ValueError(f"duplicate flutter.assets entry: {entry}")
        seen.add(entry)
        if entry in EXCLUDED_ASSET_DIRS:
            continue
        asset = app / entry
        # Flutter directory declarations include direct files, not subdirectories.
        candidates = asset.iterdir() if entry.endswith("/") else (asset,)
        for candidate in candidates:
            if candidate.is_file() and candidate.suffix.lower() in LOOSE_SCRIPT_SUFFIXES:
                raise ValueError(f"unexpected loose script in retained flutter.assets: {candidate.relative_to(app)}")
        kept.append(line)
    if missing := EXCLUDED_ASSET_DIRS - seen:
        raise ValueError(f"expected asset directories missing: {', '.join(sorted(missing))}")
    start = flutter.start() + block.start(1)
    end = flutter.start() + block.end(1)
    return text[:start] + "".join(kept) + text[end:]


def git(*args):
    return subprocess.check_output(["git", "-C", str(REPO), *args], text=True).strip()


def stage(destination, expected_commit):
    if not FORK_URL.fullmatch(git("remote", "get-url", "origin")):
        raise ValueError("origin must be the risaddex/dsh-Go fork")
    main = git("rev-parse", "--verify", "refs/remotes/origin/main^{commit}")
    if expected_commit != main:
        raise ValueError("expected commit must match the fetched origin/main tip (use the full SHA)")
    if destination.exists() or destination.is_symlink():
        raise ValueError("staging destination must not already exist")

    with tempfile.TemporaryDirectory(prefix="dsh-go-stage-", dir=destination.parent) as scratch:
        staged = Path(scratch) / "source"
        staged.mkdir()
        # Committed tree only: no untracked engine, credentials, or generated configs.
        with subprocess.Popen(["git", "-C", str(REPO), "archive", "--format=tar", main], stdout=subprocess.PIPE) as archive:
            subprocess.run(["tar", "-xf", "-", "-C", str(staged)], stdin=archive.stdout, check=True)
            if archive.wait():
                raise ValueError("git archive failed")
        for relative in ("app/ios/Engine/.ready", "app/ios/PhoneSelfRunnerNative/PhoneSelfRunner.xcconfig"):
            if (staged / relative).exists():
                raise ValueError(f"unexpected native payload input in fork main: {relative}")
        pubspec = staged / "app/pubspec.yaml"
        pubspec.write_text(remote_pubspec(pubspec.read_text(encoding="utf-8"), staged / "app"), encoding="utf-8")
        staged.rename(destination)
    return main


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog="Fetch origin main first. Use only the staged app for the remote iOS build.")
    parser.add_argument("destination", type=Path, help="new directory under an existing parent (never an existing checkout)")
    parser.add_argument("--commit", required=True, help="full integrated commit SHA, must match fetched origin/main")
    args = parser.parse_args()
    # Resolve the parent, not the leaf: don't follow an existing destination symlink.
    destination = args.destination.parent.resolve() / args.destination.name
    try:
        commit = stage(destination, args.commit)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"Staged remote-only iOS source from {commit}: {destination}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
