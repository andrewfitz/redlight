#!/usr/bin/env python3
"""Render one changelog release for GitHub and Sparkle, and verify its feed link."""
from __future__ import annotations

import argparse
import html
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?\Z")
SECTION_PATTERN = re.compile(r"^##\s+(?:\[([0-9]+\.[0-9]+(?:\.[0-9]+)?)\]|([0-9]+\.[0-9]+(?:\.[0-9]+)?))(?:\s+-\s+.*)?\s*$")
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def release_markdown(changelog: str, version: str) -> str:
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError("Release version must be numeric X.Y or X.Y.Z.")
    sections: list[list[str]] = []
    current: list[str] | None = None
    fence: str | None = None
    for line in changelog.splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if marker:
            if fence is None:
                fence = marker.group(1)[0]
            elif marker.group(1)[0] == fence:
                fence = None
            if current is not None:
                current.append(line)
            continue
        if fence is None and re.match(r"^##\s", line):
            match = SECTION_PATTERN.fullmatch(line)
            current = [] if match and (match.group(1) or match.group(2)) == version else None
            if current is not None:
                sections.append(current)
        elif current is not None:
            current.append(line)
    if len(sections) != 1:
        raise ValueError(f"CHANGELOG.md must contain exactly one ## section for {version}; found {len(sections)}.")
    body = "\n".join(sections[0]).strip()
    if not body:
        raise ValueError(f"The changelog section for {version} is empty.")
    return f"# Redlight {version}\n\n{body}\n"


def inline_html(text: str) -> str:
    pieces = re.split(r"(`[^`\n]+`)", text)
    return "".join(f"<code>{html.escape(piece[1:-1])}</code>" if piece.startswith("`") and piece.endswith("`")
                   else html.escape(piece) for piece in pieces)


def markdown_html(markdown: str) -> str:
    blocks: list[str] = []
    paragraph: list[str] = []
    list_kind: str | None = None
    code: list[str] | None = None
    fence: str | None = None

    def end_paragraph() -> None:
        if paragraph:
            blocks.append(f"<p>{inline_html(' '.join(paragraph))}</p>")
            paragraph.clear()

    def end_list() -> None:
        nonlocal list_kind
        if list_kind:
            blocks.append(f"</{list_kind}>")
            list_kind = None

    for line in markdown.splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if code is not None:
            if marker and marker.group(1)[0] == fence:
                blocks.append("<pre><code>" + html.escape("\n".join(code)) + "</code></pre>")
                code = None
                fence = None
            else:
                code.append(line)
            continue
        if marker:
            end_paragraph()
            end_list()
            code = []
            fence = marker.group(1)[0]
            continue
        heading = re.match(r"^(#{1,6})\s+(.+)$", line)
        item = re.match(r"^\s*(?:([-*+])\s+|([0-9]+)[.)]\s+)(.+)$", line)
        if not line.strip():
            end_paragraph()
            end_list()
        elif heading:
            end_paragraph()
            end_list()
            level = len(heading.group(1))
            blocks.append(f"<h{level}>{inline_html(heading.group(2))}</h{level}>")
        elif item:
            end_paragraph()
            kind = "ul" if item.group(1) else "ol"
            if kind != list_kind:
                end_list()
                blocks.append(f"<{kind}>")
                list_kind = kind
            blocks.append(f"<li>{inline_html(item.group(3))}</li>")
        else:
            end_list()
            paragraph.append(line.strip())
    if code is not None:
        raise ValueError("Release notes contain an unterminated code fence.")
    end_paragraph()
    end_list()
    # A full HTML document makes Sparkle link this sidecar instead of embedding it.
    return ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            "<meta name=\"color-scheme\" content=\"light dark\">\n"
            "<title>Redlight release notes</title>\n"
            "<style>body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.5;"
            "margin:24px}main{max-width:640px;margin:auto}li{margin:8px 0}"
            "code{font-size:.9em}pre{white-space:pre-wrap}</style>\n</head>\n<body>\n<main>\n"
            + "\n".join(blocks) + "\n</main>\n</body>\n</html>\n")


def verify_appcast(path: pathlib.Path, dmg_url: str, notes_url: str) -> None:
    root = ET.parse(path).getroot()
    items = [item for item in root.findall("./channel/item")
             if any(enclosure.get("url") == dmg_url for enclosure in item.findall("enclosure"))]
    if len(items) != 1:
        raise ValueError("Appcast must contain exactly one item for the release DMG.")
    links = items[0].findall(f"{{{SPARKLE_NAMESPACE}}}releaseNotesLink")
    if len(links) != 1 or (links[0].text or "").strip() != notes_url:
        raise ValueError("Appcast does not link to the hosted HTML release notes.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(required=True, dest="command")
    render = commands.add_parser("render")
    render.add_argument("--changelog", required=True, type=pathlib.Path)
    render.add_argument("--version", required=True)
    render.add_argument("--markdown", required=True, type=pathlib.Path)
    render.add_argument("--html", required=True, type=pathlib.Path)
    verify = commands.add_parser("verify-appcast")
    verify.add_argument("--appcast", required=True, type=pathlib.Path)
    verify.add_argument("--dmg-url", required=True)
    verify.add_argument("--notes-url", required=True)
    args = parser.parse_args()
    try:
        if args.command == "render":
            markdown = release_markdown(args.changelog.read_text(), args.version)
            html_document = markdown_html(markdown)
            args.markdown.write_text(markdown)
            args.html.write_text(html_document)
        else:
            verify_appcast(args.appcast, args.dmg_url, args.notes_url)
    except (OSError, ValueError, ET.ParseError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
