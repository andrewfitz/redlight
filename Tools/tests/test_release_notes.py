import base64
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

TOOLS = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_notes", TOOLS / "release-notes.py")
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)
SIGNATURE = base64.b64encode(bytes(64)).decode("ascii")
ENCLOSURE = f'<enclosure url="DMG" length="7" sparkle:edSignature="{SIGNATURE}"/>'


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
        rendered = notes.markdown_html('# Title <script>\n\nFirst & second\nline.\n\n- Use `<img src=x>`\n'
                                       '- **Deepest by `<time>`** and `**literal**`\n- "quotes"\n\n'
                                       '1. One\n2. Two\n\n```swift\n<script>&\n```\n')
        for fragment in ("<!DOCTYPE html>", "<body>", "<h1>Title &lt;script&gt;</h1>",
                         "<p>First &amp; second line.</p>", "<ul>", "<ol>",
                         "<code>&lt;img src=x&gt;</code>", "&quot;quotes&quot;",
                         "<strong>Deepest by <code>&lt;time&gt;</code></strong> and <code>**literal**</code>",
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

    def test_shorter_or_labelled_fences_inside_example_remain_literal(self):
        example = "```\n## 1.2\n````swift\n## 1.1"
        changelog = f"## 2.0\n````markdown\n{example}\n`````\nCurrent.\n## 1.0\nOld."
        selected = notes.release_markdown(changelog, "2.0")
        self.assertIn("Current.", selected)
        self.assertNotIn("Old.", selected)
        self.assertIn(f"<pre><code>{example}</code></pre>", notes.markdown_html(selected))

    def test_feed_requires_matching_item_and_hosted_notes_link(self):
        with tempfile.TemporaryDirectory() as temporary:
            feed = pathlib.Path(temporary) / "appcast.xml"
            xml = '<rss xmlns:sparkle="' + notes.SPARKLE_NAMESPACE + '"><channel><item>' + ENCLOSURE + '<sparkle:releaseNotesLink>HTML</sparkle:releaseNotesLink><sparkle:fullReleaseNotesLink>HISTORY</sparkle:fullReleaseNotesLink></item></channel></rss>'
            feed.write_text(xml)
            notes.verify_appcast(feed, "DMG", "HTML", "HISTORY")
            for dmg, html in (("other", "HTML"), ("DMG", "other")):
                with self.assertRaises(ValueError):
                    notes.verify_appcast(feed, dmg, html, "HISTORY")
            feed.write_text(xml.replace("<sparkle:releaseNotesLink>HTML</sparkle:releaseNotesLink>", ""))
            with self.assertRaises(ValueError):
                notes.verify_appcast(feed, "DMG", "HTML", "HISTORY")

    def test_old_feed_missing_wrong_or_duplicate_history_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            feed = pathlib.Path(temporary) / "appcast.xml"
            for history in ("", "<sparkle:fullReleaseNotesLink>HTML</sparkle:fullReleaseNotesLink>",
                            "<sparkle:fullReleaseNotesLink>HISTORY</sparkle:fullReleaseNotesLink>" * 2):
                feed.write_text('<rss xmlns:sparkle="' + notes.SPARKLE_NAMESPACE + '"><channel><item>' + ENCLOSURE + '<sparkle:releaseNotesLink>HTML</sparkle:releaseNotesLink>' + history + '</item></channel></rss>')
                with self.assertRaisesRegex(ValueError, "Version History"):
                    notes.verify_appcast(feed, "DMG", "HTML", "HISTORY")

    def test_feed_verification_preserves_enclosure_signature_and_release_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            feed = pathlib.Path(temporary) / "appcast.xml"
            version_elements = '<sparkle:version>47</sparkle:version><sparkle:shortVersionString>1.3.1</sparkle:shortVersionString>'
            links = '<sparkle:releaseNotesLink>HTML</sparkle:releaseNotesLink><sparkle:fullReleaseNotesLink>HISTORY</sparkle:fullReleaseNotesLink>'
            xml = f'<rss xmlns:sparkle="{notes.SPARKLE_NAMESPACE}"><channel><item>{version_elements}{ENCLOSURE}{links}</item></channel></rss>'
            feed.write_text(xml)
            dmg = feed.parent / "fixture.dmg"
            dmg.write_bytes(b"fixture")
            before = feed.read_bytes()
            notes.verify_appcast(feed, "DMG", "HTML", "HISTORY", dmg, "1.3.1")
            self.assertEqual(feed.read_bytes(), before)
            tree = ET.parse(feed)
            self.assertEqual(tree.find("./channel/item/enclosure").get("{" + notes.SPARKLE_NAMESPACE + "}edSignature"), SIGNATURE)
            self.assertEqual(tree.find("./channel/item/{" + notes.SPARKLE_NAMESPACE + "}version").text, "47")
            for broken, reason in ((xml.replace(SIGNATURE, ""), "signature"),
                                   (xml.replace('length="7"', 'length="8"'), "length"),
                                   (xml.replace("1.3.1", "1.3"), "version")):
                feed.write_text(broken)
                with self.assertRaisesRegex(ValueError, reason):
                    notes.verify_appcast(feed, "DMG", "HTML", "HISTORY", dmg, "1.3.1")

    def pipeline(self, missing_notes=False, wrong_link=False, wrong_history=False,
                 dirty=False, wrong_tag=False, wrong_build=False):
        with tempfile.TemporaryDirectory(prefix="release notes fixture ") as temporary:
            base = pathlib.Path(temporary)
            root = base / "repository with spaces"
            (root / "Tools").mkdir(parents=True)
            for name in ("release.sh", "release-notes.py", "build-version.py", "app-intents-metadata.py"):
                shutil.copy2(TOOLS / name, root / "Tools" / name)
            (root / "VERSION").write_text("1.3.1\n")
            (root / "CHANGELOG.md").write_text("## " + ("1.3" if missing_notes else "1.3.1") + "\n\n- Fixed `window` & updates.\n")
            capture = base / "captured"
            capture.mkdir()
            (root / "build.sh").write_text('''#!/usr/bin/env python3
import json, os, pathlib
env = os.environ
capture = pathlib.Path(env['RELEASE_TEST_CAPTURE'])
workspace = pathlib.Path(env['REDLIGHT_BUILD_WORKSPACE'])
assert pathlib.Path(__file__).parent.parent.parent == workspace / '.build'
(capture / 'built').write_text('built')
snapshot = pathlib.Path(env['REDLIGHT_BUILD_SNAPSHOT_DIR'])
snapshot.mkdir()
dmg = f"Redlight-{env['VERSION']}.dmg"
(snapshot / dmg).write_text('fixture')
# Simulate a different build having already replaced the shared output.
(pathlib.Path(env['REDLIGHT_BUILD_OUTPUT_DIR']) / dmg).write_text('different build')
tool = pathlib.Path(env['RELEASE_TEST_GENERATOR'])
(snapshot / '.redlight-build-info.json').write_text(json.dumps({
    'schemaVersion': 1, 'buildNumber': 47, 'invocationDirectory': str(tool.parent), 'sparkleAppcastTool': str(tool)
}))
''')
            (root / "build.sh").chmod(0o755)
            binaries = base / "bin"
            binaries.mkdir()
            generator = binaries / "generator"
            generator.write_text('''#!/usr/bin/env python3
import base64
import os
import pathlib
import sys
import xml.etree.ElementTree as ET

args = sys.argv[1:]
prefix = args[args.index('--release-notes-url-prefix') + 1]
assert prefix == args[args.index('--download-url-prefix') + 1]
history = args[args.index('--full-release-notes-url') + 1]
assert history == 'https://github.com/andrewfitz/redlight/releases'
stage = pathlib.Path(args[-1])
dmg = next(stage.glob('*.dmg'))
html = stage / (dmg.stem + '.html')
assert '<!DOCTYPE html>' in html.read_text() and '<body>' in html.read_text()

root = ET.Element('rss')
channel = ET.SubElement(root, 'channel')
item = ET.SubElement(channel, 'item')
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
ET.SubElement(item, sparkle + 'version').text = '46' if os.environ.get('WRONG_BUILD_NUMBER') else '47'
ET.SubElement(item, sparkle + 'shortVersionString').text = dmg.stem.removeprefix('Redlight-')
signature = base64.b64encode(bytes(64)).decode('ascii')
ET.SubElement(item, 'enclosure', url=prefix + dmg.name, length=str(dmg.stat().st_size),
              attrib={sparkle + 'edSignature': signature})
notes_name = 'wrong.html' if os.environ.get('WRONG_NOTES_LINK') else html.name
history_url = prefix + html.name if os.environ.get('WRONG_HISTORY_LINK') else history
ET.SubElement(item, sparkle + 'releaseNotesLink').text = prefix + notes_name
ET.SubElement(item, sparkle + 'fullReleaseNotesLink').text = history_url
ET.ElementTree(root).write(args[args.index('-o') + 1])
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
 if arg.endswith(('.html','.xml','.dmg')): shutil.copy2(arg,capture/pathlib.Path(arg).name)
''')
            gh.chmod(0o755)
            real_git = shutil.which("git")
            git_fixture = [real_git, "-C", str(root)]
            subprocess.run([*git_fixture, "init", "-q"], check=True)
            subprocess.run([*git_fixture, "add", "."], check=True)
            subprocess.run([*git_fixture, "-c", "user.name=ReleaseTest", "-c", "user.email=release-test@example.invalid",
                            "-c", "commit.gpgsign=false", "commit", "-qm", "Fixture"], check=True)
            target = subprocess.check_output([*git_fixture, "rev-parse", "HEAD"], text=True).strip()
            if dirty:
                (root / "CHANGELOG.md").write_text("## 1.3.1\n\nUncommitted notes.\n")
                (root / "VERSION").write_text("9.9\n")
                (root / "build.sh").write_text("#!/bin/bash\nexit 93\n")
            git = binaries / "git"
            git.write_text('''#!/bin/bash
case "$3" in
    ls-remote)
        if [[ -n "${WRONG_TAG:-}" ]]; then
            printf '%s\\trefs/tags/v1.3.1\\nother-commit\\trefs/tags/v1.3.1^{}\\n' "$RELEASE_TEST_TARGET"
        fi ;;
    *) exec "$RELEASE_TEST_GIT" "$@" ;;
esac
''')
            git.chmod(0o755)
            environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                               REDLIGHT_BUILD_OUTPUT_DIR="relative output", RELEASE_TEST_CAPTURE=str(capture),
                               RELEASE_TEST_GENERATOR=str(generator), RELEASE_TEST_GIT=real_git,
                               RELEASE_TEST_TARGET=target, PYTHONDONTWRITEBYTECODE="1")
            environment.pop("VERSION", None)
            if wrong_link:
                environment["WRONG_NOTES_LINK"] = "1"
            if wrong_history:
                environment["WRONG_HISTORY_LINK"] = "1"
            if wrong_build:
                environment['WRONG_BUILD_NUMBER'] = '1'
            if wrong_tag:
                environment["WRONG_TAG"] = "1"
            result = subprocess.run(["bash", str(root / "Tools/release.sh")], cwd=base, env=environment,
                                    capture_output=True, text=True)
            (capture / "target.txt").write_text(target)
            return result, {path.name: path.read_text() for path in capture.iterdir()}

    def test_shell_pipeline_uses_current_changelog_and_html_asset_with_relative_output(self):
        result, captured = self.pipeline()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Redlight-1.3.1.html", captured)
        self.assertIn("Fixed `window` & updates.", captured["notes.md"])
        self.assertIn("https://github.com/andrewfitz/redlight/releases/download/v1.3.1/Redlight-1.3.1.html", captured["appcast.xml"])
        self.assertIn("https://github.com/andrewfitz/redlight/releases</", captured["appcast.xml"])
        self.assertIn(captured["target.txt"], json.loads(captured["gh.json"]))
        self.assertEqual(captured["Redlight-1.3.1.dmg"], "fixture")

    def test_missing_notes_stop_before_build_and_wrong_feed_stops_before_publish(self):
        result, captured = self.pipeline(missing_notes=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("built", captured)
        result, captured = self.pipeline(wrong_link=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("built", captured)
        self.assertNotIn("gh.json", captured)

    def test_wrong_sparkle_build_number_stops_before_publish(self):
        result, captured = self.pipeline(wrong_build=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build number", result.stderr)
        self.assertNotIn("gh.json", captured)

    def test_history_download_link_stops_shell_before_publish(self):
        result, captured = self.pipeline(wrong_history=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Version History", result.stderr)
        self.assertIn("built", captured)
        self.assertNotIn("gh.json", captured)

    def test_release_builds_committed_source_and_rejects_mismatched_annotated_tag(self):
        result, captured = self.pipeline(dirty=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Fixed `window` & updates.", captured["notes.md"])
        self.assertEqual(captured["Redlight-1.3.1.dmg"], "fixture")
        result, captured = self.pipeline(wrong_tag=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("other-commit", result.stderr)
        self.assertIn("built", captured)
        self.assertNotIn("gh.json", captured)


if __name__ == "__main__":
    unittest.main()
