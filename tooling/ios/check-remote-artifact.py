#!/usr/bin/env python3
"""Check a locally produced, signed DSH Go remote-only archive or IPA."""

import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

BUNDLE_ID = "com.danilo.dshgo"
TEAM = "7F3YZDJ6L8"
DECK_MARKERS = (b"deck.panel.read.v1", b"standaloneIssues")
ENGINE_FRAMEWORKS = {
    "NodeMobile.framework", "DshNodeHost.framework", "DshFlock.framework",
    "DshRequireBuiltin.framework", "DshGuest.framework", "DshGuestBridge.framework",
}
SCRIPT_SUFFIXES = {".py", ".mjs", ".sh"}


def check_launch_structure(app, aot):
    errors = []
    frameworks = app / "Frameworks"
    binaries = {aot}
    bundles = [app, *sorted(frameworks.glob("*.framework")), *sorted((app / "PlugIns").glob("*.appex"))]
    for bundle in bundles:
        if bundle.name in ENGINE_FRAMEWORKS:
            continue  # Already rejected by the remote-only check.
        try:
            with (bundle / "Info.plist").open("rb") as info_file:
                executable = plistlib.load(info_file).get("CFBundleExecutable")
        except FileNotFoundError:
            errors.append(f"missing bundle Info.plist: {bundle.relative_to(app)}")
            continue
        if not isinstance(executable, str) or not executable or Path(executable).name != executable:
            errors.append(f"missing or invalid CFBundleExecutable: {bundle.relative_to(app)}")
        else:
            binaries.add(bundle / executable)

    for binary in sorted(binaries):
        relative = binary.relative_to(app)
        if not binary.is_file():
            errors.append(f"missing bundle executable: {relative}")
            continue
        arch = subprocess.run(["/usr/bin/lipo", "-verify_arch", "arm64", str(binary)], capture_output=True)
        if arch.returncode:
            errors.append(f"expected an arm64 Mach-O: {relative}")
            continue
        if binary == aot:
            # Same snapshot export alternatives as the full-engine archive gate.
            symbols = subprocess.run(["/usr/bin/nm", "-arch", "arm64", "-gU", str(binary)], capture_output=True, text=True)
            exports = {line.rsplit(maxsplit=1)[-1].lstrip("_") for line in symbols.stdout.splitlines() if line.strip()}
            if symbols.returncode or not exports.intersection({"kDartSnapshotText", "kDartIsolateSnapshotInstructions"}):
                errors.append(f"no exported Dart snapshot symbols: {relative}")
        links = subprocess.run(["/usr/bin/otool", "-arch", "arm64", "-L", str(binary)], capture_output=True, text=True)
        if links.returncode:
            errors.append(f"cannot read Mach-O dependencies: {relative}")
            continue
        for line in links.stdout.splitlines():
            library = line.strip().split(" (compatibility version ", 1)[0]
            if not library.startswith("@rpath/"):
                continue
            dependency = library.removeprefix("@rpath/")
            # Like the default gate, allow Apple-provided Swift libraries and
            # check the app's Frameworks directory for bundled dependencies.
            if "/" not in dependency and dependency.startswith("libswift") and dependency.endswith(".dylib"):
                continue
            # An app extension can also carry its own Frameworks directory.
            containers = (frameworks, binary.parent / "Frameworks") if binary.parent.suffix == ".appex" else (frameworks,)
            if not any((container / dependency).is_file() for container in containers):
                errors.append(f"missing bundled dependency for {relative}: {library}")
    return errors


def check_app(app):
    errors = []
    with (app / "Info.plist").open("rb") as info_file:
        info = plistlib.load(info_file)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        errors.append(f"expected bundle identifier {BUNDLE_ID}")

    def raise_walk_error(error):
        raise error

    # Include symlink names in the scan, but don't follow directory symlinks.
    for root, dirs, files in os.walk(app, onerror=raise_walk_error):
        for name in sorted(files + dirs):
            path = (Path(root) / name).relative_to(app)
            if name in ENGINE_FRAMEWORKS or path == Path("dsh-runtime"):
                errors.append(f"embedded engine artifact in a remote-only build: {path}")
            if name in files and path.suffix.lower() in SCRIPT_SUFFIXES:
                errors.append(f"loose script (App Store 90035): {path}")

    binary = app / "Frameworks/App.framework/App"
    if not binary.is_file():
        errors.append("missing Dart AOT binary: Frameworks/App.framework/App")
    else:
        compiled = binary.read_bytes()
        for marker in DECK_MARKERS:
            if marker not in compiled:
                errors.append(f"missing compiled deck marker: {marker.decode('ascii')}")

    errors.extend(check_launch_structure(app, binary))

    # This verifies the nested signatures and the fork's team, not ASC acceptance.
    verified = subprocess.run([
        "/usr/bin/codesign", "--verify", "--deep", "--strict", "-R",
        f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM}"', str(app),
    ], check=False, capture_output=True, text=True)
    if verified.returncode:
        errors.append(f"code signature verification failed: {verified.stderr.strip()}")
    return errors


def check_artifact(artifact):
    if artifact.suffix == ".xcarchive" and artifact.is_dir():
        app = artifact / "Products/Applications/Runner.app"
        if not app.is_dir():
            raise ValueError("missing Products/Applications/Runner.app in archive")
        return check_app(app)
    if artifact.suffix == ".ipa" and artifact.is_file():
        # Use ditto for locally built IPAs so Unix metadata and framework symlinks
        # survive extraction; codesign verifies that extracted copy.
        with tempfile.TemporaryDirectory(prefix="dsh-go-ipa-") as unpacked:
            subprocess.run(["/usr/bin/ditto", "-x", "-k", str(artifact), unpacked], check=True)
            apps = [p for p in (Path(unpacked) / "Payload").glob("*.app") if p.is_dir()]
            if len(apps) != 1:
                raise ValueError("expected exactly one app in IPA Payload")
            return check_app(apps[0])
    raise ValueError("expected an existing .xcarchive directory or .ipa file")


def main():
    parser = argparse.ArgumentParser(
        usage="bash tooling/ios/check-archive.sh --remote-only ARTIFACT",
        description="Inspect a locally built signed remote-only .xcarchive or .ipa without building.",
    )
    parser.add_argument("artifact", type=Path)
    args = parser.parse_args()
    try:
        errors = check_artifact(args.artifact.resolve())
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as exc:
        errors = [str(exc)]
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        return 1
    print("Remote-only artifact passed: bundle ID, signature, arm64 launch structure, deck AOT markers, no engine or loose scripts.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
