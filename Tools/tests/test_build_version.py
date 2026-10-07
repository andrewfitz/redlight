import concurrent.futures
import importlib.util
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HELPER = pathlib.Path(__file__).resolve().parents[1] / "build-version.py"
spec = importlib.util.spec_from_file_location("build_version", HELPER)
version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version)


class BuildVersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.state = self.root / "state/build.json"

    def tearDown(self):
        self.temporary.cleanup()

    def repository(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=VersionTest",
                        "-c", "user.email=version-test@example.invalid", "commit", "-q",
                        "--allow-empty", "-m", "Fixture"], check=True)

    def app(self, name, build):
        app = self.root / name
        info = app / "Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"CFBundleVersion": build}))
        return app

    def test_numeric_release_tag_selection_and_fallback(self):
        self.assertEqual(version.release_version(self.root), "1.0")
        self.repository()
        for tag in ("v1.2", "v1.10", "v1.10.1", "v2.0-beta", "other3.0"):
            subprocess.run(["git", "-C", str(self.root), "tag", tag], check=True)
        self.assertEqual(version.release_version(self.root), "1.10.1")
        self.assertEqual(version.tracked_commit_count(self.root), 1)
        self.assertEqual(version.release_version(self.root, "1.3"), "1.3")
        with self.assertRaises(ValueError):
            version.release_version(self.root, "1.3-beta")

    def test_persistent_increment_and_override(self):
        self.assertEqual(version.next_build_number(self.state, seed=12), 13)
        self.assertEqual(version.next_build_number(self.state), 14)
        self.assertEqual(version.next_build_number(self.state, override="50"), 50)
        self.assertEqual(version.next_build_number(self.state), 51)
        for override in ("50", "51", "0", "-1", "1.2", "abc"):
            with self.assertRaises(ValueError):
                version.next_build_number(self.state, override=override)
        self.assertEqual(json.loads(self.state.read_text())["lastBuildNumber"], 51)

    def test_current_release_file_takes_precedence_over_published_tag(self):
        self.repository()
        subprocess.run(["git", "-C", str(self.root), "tag", "v1.2"], check=True)
        (self.root / "VERSION").write_text("1.3\n")
        self.assertEqual(version.release_version(self.root), "1.3")
        self.assertEqual(version.release_version(self.root, "1.4"), "1.4")

    def test_invalid_current_release_file_does_not_fall_back(self):
        (self.root / "VERSION").write_text("1.3-beta\n")
        with self.assertRaises(ValueError):
            version.release_version(self.root)

    def test_existing_bundle_seed_survives_deleted_counter(self):
        app = self.app("Redlight.app", "117.9.2")
        self.assertEqual(version.app_build_seed(app), 117)
        self.assertEqual(version.next_build_number(self.state, version.app_build_seed(app)), 118)
        self.state.unlink()
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "118"}))
        self.assertEqual(version.next_build_number(self.state, version.app_build_seed(app)), 119)
        self.assertEqual(version.app_build_seed(self.app("Invalid.app", "development")), 0)
        self.assertEqual(version.app_build_seed(self.root / "Absent.app"), 0)
        with self.assertRaises(ValueError):
            version.next_build_number(self.root / "new-state.json", seed=200, override="200")

    def test_corrupt_counter_does_not_reset_or_publish(self):
        self.state.parent.mkdir()
        self.state.write_text("not json")
        with self.assertRaises(ValueError):
            version.next_build_number(self.state, seed=50)
        self.assertEqual(self.state.read_text(), "not json")

    def test_atomic_replace_failure_preserves_prior_state(self):
        self.assertEqual(version.next_build_number(self.state, seed=20), 21)
        before = self.state.read_bytes()
        with patch.object(version.os, "replace", side_effect=OSError("fixture failure")):
            with self.assertRaises(OSError):
                version.next_build_number(self.state)
        self.assertEqual(self.state.read_bytes(), before)
        self.assertEqual(list(self.state.parent.glob(".build.json.*")), [])

    def test_separate_processes_reserve_unique_monotonic_numbers(self):
        self.repository()
        app = self.app("InstalledFixture.app", "70")
        def reserve(_):
            return int(subprocess.check_output([
                sys.executable, str(HELPER), "next", "--root", str(self.root),
                "--state", str(self.state), "--seed-app", str(app),
            ], text=True))
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            builds = list(executor.map(reserve, range(12)))
        self.assertEqual(sorted(builds), list(range(71, 83)))
        self.assertEqual(json.loads(self.state.read_text())["lastBuildNumber"], 82)


if __name__ == "__main__":
    unittest.main()
