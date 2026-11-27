"""Test the staged iOS pubspec transformation without Flutter or signing."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("stage_remote_source", HERE / "stage-remote-source.py")
stager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stager)


class StageRemoteSourceTest(unittest.TestCase):
    def setUp(self):
        self.app = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.excluded = "".join(f"    - {path}\n" for path in sorted(stager.EXCLUDED_ASSET_DIRS))
        self.prefix = "name: sample\nflutter:\n  assets:\n"
        self.suffix = "    - assets/keep/\n\n  uses-material-design: true\n"
        self.pubspec = self.prefix + self.excluded + self.suffix
        (self.app / "assets/keep").mkdir(parents=True)

    def test_omits_bundle_entries_without_touching_files(self):
        script = self.app / "assets/skills/dsh-go-ui/check.mjs"
        script.parent.mkdir(parents=True)
        script.write_text("// Script fixture\n", encoding="utf-8")
        self.assertEqual(stager.remote_pubspec(self.pubspec, self.app), self.prefix + self.suffix)
        self.assertEqual(script.read_text(encoding="utf-8"), "// Script fixture\n")

    def test_refuses_new_script_in_retained_directory(self):
        (self.app / "assets/keep/unexpected.sh").touch()
        with self.assertRaisesRegex(ValueError, "unexpected loose script.*unexpected.sh"):
            stager.remote_pubspec(self.pubspec, self.app)

    def test_rejects_changed_asset_block_instead_of_guessing(self):
        changed = self.pubspec.replace("    - assets/keep/", "    - path: assets/keep/")
        with self.assertRaisesRegex(ValueError, "unsupported flutter.assets entry"):
            stager.remote_pubspec(changed, self.app)


if __name__ == "__main__":
    unittest.main()
