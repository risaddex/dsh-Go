"""Fixtures for the remote-only artifact gate; no Flutter/Xcode build or signing."""

import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("check_remote_artifact", HERE / "check-remote-artifact.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class RemoteArtifactTest(unittest.TestCase):
    def setUp(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.archive = root / "An archive.xcarchive"
        self.app = self.archive / "Products/Applications/Runner.app"
        self.aot = self.app / "Frameworks/App.framework/App"
        self.aot.parent.mkdir(parents=True)
        self.aot.write_bytes(b"\x00deck.panel.read.v1\x00standaloneIssues\x00")
        self.runner = self.app / "Runner"
        self.runner.touch()
        self.write_bundle_info(self.app, "Runner", CFBundleIdentifier="com.danilo.dshgo")
        self.write_bundle_info(self.aot.parent, "App")
        self.non_arm64 = set()
        self.exports = "000000000000abcd T _kDartIsolateSnapshotInstructions\n"
        self.dependencies = {}
        self.signature_error = ""

        def run(command, **kwargs):
            tool = Path(command[0]).name
            name = Path(command[-1]).name
            if tool == "codesign":
                return subprocess.CompletedProcess(command, bool(self.signature_error), "", self.signature_error)
            if tool == "lipo":
                return subprocess.CompletedProcess(command, name in self.non_arm64)
            if tool == "nm":
                return subprocess.CompletedProcess(command, 0, self.exports, "")
            if tool == "otool":
                links = "".join(f"\t{dep} (compatibility version 1.0.0, current version 1.0.0)\n"
                                for dep in self.dependencies.get(name, ()))
                return subprocess.CompletedProcess(command, 0, f"{command[-1]}:\n{links}", "")
            return self.real_run(command, **kwargs)

        self.real_run = subprocess.run
        self.run_command = self.enterContext(patch.object(checker.subprocess, "run", side_effect=run))

    @staticmethod
    def write_bundle_info(bundle, executable, **entries):
        with (bundle / "Info.plist").open("wb") as plist:
            plistlib.dump({"CFBundleExecutable": executable, **entries}, plist, fmt=plistlib.FMT_BINARY)

    def test_accepts_valid_archive(self):
        self.assertEqual(checker.check_artifact(self.archive), [])
        command = self.run_command.call_args.args[0]
        self.assertEqual(command[:5], ["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R"])
        self.assertIn('certificate leaf[subject.OU] = "7F3YZDJ6L8"', command[5])
        self.assertEqual(command[-1], str(self.app))

    def test_reports_each_forbidden_loose_script(self):
        assets = self.aot.parent / "flutter_assets"
        assets.mkdir()
        for name in ("validate pack.py", "script.mjs", "startup.sh", "example.sh.txt"):
            (assets / name).touch()
        errors = checker.check_artifact(self.archive)
        self.assertEqual(len(errors), 3)
        for name in ("validate pack.py", "script.mjs", "startup.sh"):
            self.assertIn(f"loose script (App Store 90035): Frameworks/App.framework/flutter_assets/{name}", errors)

    def test_requires_both_markers_in_aot_not_assets(self):
        (self.app / "asset.txt").write_bytes(b"deck.panel.read.v1 standaloneIssues")
        for marker, other in ((b"deck.panel.read.v1", b"standaloneIssues"), (b"standaloneIssues", b"deck.panel.read.v1")):
            with self.subTest(marker=marker):
                self.aot.write_bytes(other)
                self.assertEqual(checker.check_artifact(self.archive), [
                    f"missing compiled deck marker: {marker.decode()}",
                ])

    def test_requires_arm64_runner_and_aot(self):
        self.non_arm64.update(("Runner", "App"))
        self.assertCountEqual(checker.check_artifact(self.archive), [
            "expected an arm64 Mach-O: Runner",
            "expected an arm64 Mach-O: Frameworks/App.framework/App",
        ])

    def test_requires_defined_aot_snapshot_export(self):
        self.exports = "000000000000abcd T _not_kDartSnapshotText\n"
        self.assertEqual(checker.check_artifact(self.archive), [
            "no exported Dart snapshot symbols: Frameworks/App.framework/App",
        ])

    def test_checks_bundled_dependencies_from_extensions_as_well_as_runner(self):
        extension = self.app / "PlugIns/Widget.appex"
        extension.mkdir(parents=True)
        self.write_bundle_info(extension, "Widget")
        (extension / "Widget").touch()
        self.dependencies["Runner"] = ("@rpath/App.framework/App", "/usr/lib/libSystem.B.dylib")
        self.dependencies["Widget"] = ("@rpath/libswiftCore.dylib", "@rpath/Missing.framework/Missing")
        self.assertEqual(checker.check_artifact(self.archive), [
            "missing bundled dependency for PlugIns/Widget.appex/Widget: @rpath/Missing.framework/Missing",
        ])

    def test_rejects_embedded_engine(self):
        (self.app / "Frameworks/NodeMobile.framework").mkdir()
        (self.app / "dsh-runtime").mkdir()
        self.assertCountEqual(checker.check_artifact(self.archive), [
            "embedded engine artifact in a remote-only build: Frameworks/NodeMobile.framework",
            "embedded engine artifact in a remote-only build: dsh-runtime",
        ])

    def test_rejects_invalid_signature(self):
        self.signature_error = "code is not signed at all"
        self.assertEqual(checker.check_artifact(self.archive), [
            "code signature verification failed: code is not signed at all",
        ])

    @unittest.skipUnless(Path("/usr/bin/codesign").is_file(), "signature verification requires macOS")
    def test_shell_entry_rejects_unsigned_archive(self):
        result = self.real_run([
            "bash", str(HERE / "check-archive.sh"), "--remote-only", str(self.archive),
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("code signature verification failed:", result.stderr)
        self.assertNotIn("passed", result.stdout)

    @unittest.skipUnless(Path("/usr/bin/ditto").is_file(), "IPA extraction requires macOS ditto")
    def test_ipa_layout_is_checked_without_writing_to_input(self):
        ipa = self.archive.with_name("An exported app.ipa")
        with zipfile.ZipFile(ipa, "w") as archive:
            # Flutter export can use the product name instead of Runner.app.
            for file in (self.runner, self.aot, self.aot.parent / "Info.plist", self.app / "Info.plist"):
                archive.write(file, Path("Payload/DSH Go.app") / file.relative_to(self.app))
        before = ipa.read_bytes()
        self.assertEqual(checker.check_artifact(ipa), [])
        self.assertEqual(ipa.read_bytes(), before)
        signature_path = Path(self.run_command.call_args.args[0][-1])
        self.assertEqual(signature_path.name, "DSH Go.app")
        self.assertFalse(signature_path.exists(), "temporary extraction must be cleaned up")


if __name__ == "__main__":
    unittest.main()
