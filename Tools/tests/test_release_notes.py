import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

TOOLS = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_notes", TOOLS / "release-notes.py")
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


class ReleaseNotesTests(unittest.TestCase):
    def test_selects_exact_version_and_stops_at_next_section(self):
        text = "# Changes\n\n## [1.3.1] - 2026-10-07\n\n- Fixed window.\n\n### Updates\nNotes.\n\n## 1.3\nOld.\n"
        selected = notes.release_markdown(text, "1.3.1")
        self.assertIn("# Redlight 1.3.1", selected)
        self.assertIn("### Updates\nNotes.", selected)
        self.assertNotIn("Old.", selected)
        self.assertIn("Old.", notes.release_markdown(text, "1.3"))

    def test_missing_duplicate_empty_and_invalid_versions_fail(self):
        for text, version in (("## 1.3\nOlder", "1.3.1"), ("## 1.3.1\n", "1.3.1"),
                              ("## 1.3.1\nOne\n## 1.3.1\nTwo", "1.3.1"),
                              ("## 1.3.1\nNotes", "../1.3.1")):
            with self.assertRaises(ValueError):
                notes.release_markdown(text, version)

    def test_markup_is_escaped_and_supported_blocks_are_semantic(self):
        rendered = notes.markdown_html('# Title <script>\n\nFirst & second\nline.\n\n- Use `<img src=x>`\n- "quotes"\n\n1. One\n2. Two\n\n```swift\n<script>&\n```\n')
        for fragment in ("<!DOCTYPE html>", "<body>", "<h1>Title &lt;script&gt;</h1>",
                         "<p>First &amp; second line.</p>", "<ul>", "<ol>",
                         "<code>&lt;img src=x&gt;</code>", "&quot;quotes&quot;",
                         "<pre><code>&lt;script&gt;&amp;</code></pre>"):
            self.assertIn(fragment, rendered)
        self.assertNotIn("<script>", rendered)
        self.assertNotIn("<img", rendered)

    def test_fenced_version_heading_does_not_split_release(self):
        selected = notes.release_markdown("## 1.3.1\n```\n## 1.2\n```\nCurrent.\n## 1.3\nOld.", "1.3.1")
        self.assertIn("Current.", selected)
        self.assertNotIn("Old.", selected)
        with self.assertRaises(ValueError):
            notes.markdown_html("# Title\n```\nunfinished")

    def test_feed_requires_matching_item_and_hosted_notes_link(self):
        with tempfile.TemporaryDirectory() as temporary:
            feed = pathlib.Path(temporary) / "appcast.xml"
            xml = '<rss xmlns:sparkle="' + notes.SPARKLE_NAMESPACE + '"><channel><item><enclosure url="DMG"/><sparkle:releaseNotesLink>HTML</sparkle:releaseNotesLink></item></channel></rss>'
            feed.write_text(xml)
            notes.verify_appcast(feed, "DMG", "HTML")
            for dmg, html in (("other", "HTML"), ("DMG", "other")):
                with self.assertRaises(ValueError):
                    notes.verify_appcast(feed, dmg, html)
            feed.write_text(xml.replace("<sparkle:releaseNotesLink>HTML</sparkle:releaseNotesLink>", ""))
            with self.assertRaises(ValueError):
                notes.verify_appcast(feed, "DMG", "HTML")

    def pipeline(self, missing_notes=False, wrong_link=False):
        with tempfile.TemporaryDirectory(prefix="release notes fixture ") as temporary:
            base = pathlib.Path(temporary)
            root = base / "repository with spaces"
            (root / "Tools").mkdir(parents=True)
            for name in ("release.sh", "release-notes.py", "build-version.py"):
                shutil.copy2(TOOLS / name, root / "Tools" / name)
            (root / "VERSION").write_text("1.3.1\n")
            (root / "CHANGELOG.md").write_text("## " + ("1.3" if missing_notes else "1.3.1") + "\n\n- Fixed `window` & updates.\n")
            capture = base / "captured"
            capture.mkdir()
            (root / "build.sh").write_text('#!/bin/bash\nset -eu\necho built > "$RELEASE_TEST_CAPTURE/built"\nprintf fixture > "$REDLIGHT_BUILD_OUTPUT_DIR/Redlight-$VERSION.dmg"\n')
            (root / "build.sh").chmod(0o755)
            (root / "Tools/app-intents-metadata.py").write_text('import os\nprint(os.environ["RELEASE_TEST_GENERATOR"])\n')
            binaries = base / "bin"
            binaries.mkdir()
            generator = binaries / "generator"
            generator.write_text('''#!/usr/bin/env python3
import os,pathlib,sys,xml.etree.ElementTree as ET
args=sys.argv[1:]
prefix=args[args.index('--release-notes-url-prefix')+1]
assert prefix==args[args.index('--download-url-prefix')+1]
stage=pathlib.Path(args[-1]); dmg=next(stage.glob('*.dmg')); html=stage/(dmg.stem+'.html')
assert '<!DOCTYPE html>' in html.read_text() and '<body>' in html.read_text()
root=ET.Element('rss'); channel=ET.SubElement(root,'channel'); item=ET.SubElement(channel,'item')
ET.SubElement(item,'enclosure',url=prefix+dmg.name)
ET.SubElement(item,'{http://www.andymatuschak.org/xml-namespaces/sparkle}releaseNotesLink').text=prefix+('wrong.html' if os.environ.get('WRONG_NOTES_LINK') else html.name)
ET.ElementTree(root).write(args[args.index('-o')+1])
''')
            generator.chmod(0o755)
            gh = binaries / "gh"
            gh.write_text('''#!/usr/bin/env python3
import json,os,pathlib,shutil,sys
args=sys.argv[1:]; capture=pathlib.Path(os.environ['RELEASE_TEST_CAPTURE'])
(capture/'gh.json').write_text(json.dumps(args))
assert '--generate-notes' not in args
shutil.copy2(args[args.index('--notes-file')+1],capture/'notes.md')
for arg in args:
 if arg.endswith(('.html','.xml')): shutil.copy2(arg,capture/pathlib.Path(arg).name)
''')
            gh.chmod(0o755)
            git = binaries / "git"
            git.write_text('#!/bin/bash\necho abc123\n')
            git.chmod(0o755)
            environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                               REDLIGHT_BUILD_OUTPUT_DIR="relative output", RELEASE_TEST_CAPTURE=str(capture),
                               RELEASE_TEST_GENERATOR=str(generator), PYTHONDONTWRITEBYTECODE="1")
            environment.pop("VERSION", None)
            if wrong_link:
                environment["WRONG_NOTES_LINK"] = "1"
            result = subprocess.run(["bash", str(root / "Tools/release.sh")], cwd=base, env=environment,
                                    capture_output=True, text=True)
            return result, {path.name: path.read_text() for path in capture.iterdir()}

    def test_shell_pipeline_uses_current_changelog_and_html_asset_with_relative_output(self):
        result, captured = self.pipeline()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Redlight-1.3.1.html", captured)
        self.assertIn("Fixed `window` & updates.", captured["notes.md"])
        self.assertIn("https://github.com/andrewfitz/redlight/releases/download/v1.3.1/Redlight-1.3.1.html", captured["appcast.xml"])
        self.assertIn("abc123", json.loads(captured["gh.json"]))

    def test_missing_notes_stop_before_build_and_wrong_feed_stops_before_publish(self):
        result, captured = self.pipeline(missing_notes=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("built", captured)
        result, captured = self.pipeline(wrong_link=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("built", captured)
        self.assertNotIn("gh.json", captured)


if __name__ == "__main__":
    unittest.main()
