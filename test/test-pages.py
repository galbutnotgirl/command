#!/usr/bin/env python3
"""Focused GitHub Pages validation, independent from unreleased app source."""

from __future__ import annotations

from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlparse
import sys


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
LATEST_RELEASE = "https://github.com/galbutnotgirl/command/releases/latest"


class Links(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.hrefs: list[str] = []
        self.ids: set[str] = set()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if values.get("id"):
            self.ids.add(values["id"] or "")
        if tag == "a" and values.get("href"):
            self.hrefs.append(values["href"] or "")


def main() -> int:
    failures: list[str] = []
    pages: dict[Path, Links] = {}

    for path in sorted(DOCS.glob("*.html")):
        text = path.read_text(encoding="utf-8")
        parser = Links()
        parser.feed(text)
        pages[path] = parser
        if not text.lstrip().lower().startswith("<!doctype html>"):
            failures.append(f"{path.name}: missing doctype")
        if text.count("<title>") != 1:
            failures.append(f"{path.name}: missing unique title")
        if 'name="viewport"' not in text:
            failures.append(f"{path.name}: missing viewport metadata")

    for path, parser in pages.items():
        for href in parser.hrefs:
            parsed = urlparse(href)
            if parsed.scheme or href.startswith(("mailto:", "javascript:")):
                continue
            target_name = unquote(parsed.path)
            target = path if not target_name else (path.parent / target_name)
            if not target.exists():
                failures.append(f"{path.name}: broken link {href}")
                continue
            if parsed.fragment and target.suffix == ".html":
                target_parser = pages.get(target)
                if target_parser and parsed.fragment not in target_parser.ids:
                    failures.append(f"{path.name}: missing anchor {href}")

    home = (DOCS / "index.html").read_text(encoding="utf-8")
    install = (DOCS / "install.html").read_text(encoding="utf-8")
    required_home = [
        "Stop copy-pasting into Claude.",
        "Claude · Current conversation",
        LATEST_RELEASE,
        "install.html",
        "guide.html",
    ]
    required_install = [
        LATEST_RELEASE,
        "Control-click",
        "Open Anyway",
        "Privacy &amp; Security",
        "xattr -dr com.apple.quarantine ~/Applications/Command.app",
    ]
    for value in required_home:
        if value not in home:
            failures.append(f"index.html: missing {value}")
    for value in required_install:
        if value not in install:
            failures.append(f"install.html: missing {value}")

    if failures:
        print("\n".join(f"FAIL: {failure}" for failure in failures))
        return 1
    print(f"pages ok: {len(pages)} HTML files, current release link and install recovery verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
