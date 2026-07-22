#!/usr/bin/env python3
"""Export and apply app-facing strings for review.

Usage:
  python3 tools/string_review.py export
  python3 tools/string_review.py apply

`export` writes docs/STRING_REVIEW.md with one editable replacement block per
string. `apply` reads non-empty replacement blocks and rewrites matching source
literals.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import pathlib
import re
import sys
from typing import Iterable

ROOT = pathlib.Path(__file__).resolve().parents[1]
REVIEW_PATH = ROOT / "outputs" / "STRING_REVIEW.md"

SOURCE_GLOBS = [
    "agent/*.swift",
    "agent/Sources/**/*.swift",
    "helper/*.swift",
    "*.sh",
    "*.py",
]

EXCLUDE_PARTS = {
    ".build",
    "Tests",
    "test",
    "dist",
    "Command.app",
    "docs",
    "vendor",
}

MIN_TEXT_LEN = 2
SKIP_TEXT = {
    "%@",
    "%d",
    "%s",
    "-",
    "--",
    "—",
    " ",
    "\n",
}


@dataclasses.dataclass(frozen=True)
class StringEntry:
    id: str
    path: pathlib.Path
    line: int
    kind: str
    quote: str
    literal: str
    text: str
    sha: str

    @property
    def relpath(self) -> str:
        return self.path.relative_to(ROOT).as_posix()


def wanted_source(path: pathlib.Path) -> bool:
    rel = path.relative_to(ROOT)
    if any(part in EXCLUDE_PARTS for part in rel.parts):
        return False
    if path.name in {"Package.swift"}:
        return False
    return True


def source_paths() -> list[pathlib.Path]:
    paths: list[pathlib.Path] = []
    for glob in SOURCE_GLOBS:
        paths.extend(ROOT.glob(glob))
    return sorted({p for p in paths if p.is_file() and wanted_source(p)})


def sha_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]


def decode_escaped(value: str) -> str | None:
    try:
        return json.loads(f'"{value}"')
    except json.JSONDecodeError:
        return None


def encode_escaped(text: str) -> str:
    return json.dumps(text, ensure_ascii=False)[1:-1]


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def is_reviewable(text: str) -> bool:
    stripped = text.strip()
    if len(stripped) < MIN_TEXT_LEN:
        return False
    if stripped in SKIP_TEXT:
        return False
    if re.fullmatch(r"[A-Za-z0-9_.\-/]+", stripped) and "/" in stripped:
        return False
    if re.fullmatch(r"[A-Z0-9_]+", stripped):
        return False
    if re.fullmatch(r"[a-z][A-Za-z0-9_.-]*", stripped):
        return False
    if "_" in stripped and re.fullmatch(r"[A-Za-z0-9_.-]+", stripped):
        return False
    if "." in stripped and re.fullmatch(r"[A-Za-z0-9_.:/@-]+", stripped):
        return False
    if "/" in stripped and re.fullmatch(r"[A-Za-z0-9_.:/@~$-]+", stripped):
        return False
    if re.fullmatch(r"[.#]?[A-Za-z0-9_-]+", stripped) and len(stripped) < 16:
        return False
    return any(ch.isalpha() for ch in stripped)


def scan_simple_literals(source: str, suffix: str) -> Iterable[tuple[int, str, str, str]]:
    """Yield offset, quote, literal source, decoded text for simple literals."""
    if suffix == ".swift":
        pattern = re.compile(r'(?<!#)"((?:\\.|[^"\\])*)"', re.DOTALL)
        quote = '"'
    elif suffix == ".py":
        pattern = re.compile(r'(?<![A-Za-z])([rubfRUBF]*)(["\'])((?:\\.|(?!\2).)*)\2', re.DOTALL)
        for match in pattern.finditer(source):
            prefix = match.group(1)
            if "f" in prefix.lower() or "r" in prefix.lower():
                continue
            raw = match.group(0)
            text = decode_escaped(match.group(3)) if match.group(2) == '"' else match.group(3).encode("utf-8").decode("unicode_escape")
            if text is not None:
                yield match.start(), match.group(2), raw, text
        return
    elif suffix == ".sh":
        pattern = re.compile(r'"((?:\\.|[^"\\])*)"')
        quote = '"'
    else:
        return

    for match in pattern.finditer(source):
        literal = match.group(0)
        inner = match.group(1)
        if suffix == ".swift" and "\\(" in inner:
            continue
        text = decode_escaped(inner)
        if text is not None:
            yield match.start(), quote, literal, text


def collect_entries() -> list[StringEntry]:
    entries: list[StringEntry] = []
    counter = 1
    seen: set[tuple[str, str, int]] = set()
    for path in source_paths():
        source = path.read_text(encoding="utf-8", errors="ignore")
        for offset, quote, literal, text in scan_simple_literals(source, path.suffix):
            if not is_reviewable(text):
                continue
            line = line_number(source, offset)
            key = (path.as_posix(), literal, line)
            if key in seen:
                continue
            seen.add(key)
            entries.append(
                StringEntry(
                    id=f"STR-{counter:04d}",
                    path=path,
                    line=line,
                    kind=path.suffix.removeprefix(".") or "text",
                    quote=quote,
                    literal=literal,
                    text=text,
                    sha=sha_text(text),
                )
            )
            counter += 1
    return entries


def markdown_escape(value: str) -> str:
    return value.replace("-->", "-- >")


def export_review() -> None:
    entries = collect_entries()
    counts_by_file: dict[str, int] = {}
    for entry in entries:
        counts_by_file[entry.relpath] = counts_by_file.get(entry.relpath, 0) + 1
    lines: list[str] = [
        "# Command String Review",
        "",
        "Edit `Replacement` blocks only. Leave a replacement blank to keep current text.",
        "Run `python3 tools/string_review.py apply` after editing to update source files.",
        "",
        "Notes:",
        "- `Current` is source of truth when this file was generated.",
        "- `Source literal` lets apply script find exact code token.",
        "- If source changed before apply, matching entry is skipped instead of guessed.",
        "",
        f"Generated entries: {len(entries)}",
        "",
    ]
    lines.append("## Source Summary")
    lines.append("")
    for relpath, count in sorted(counts_by_file.items(), key=lambda item: (-item[1], item[0])):
        lines.append(f"- `{relpath}` — {count}")
    lines.extend(["", "## Entries", ""])

    for entry in entries:
        literal_json = json.dumps(entry.literal, ensure_ascii=False)
        lines.extend(
            [
                f"<!-- string-review id={entry.id} file={entry.relpath} line={entry.line} kind={entry.kind} sha={entry.sha} literal={markdown_escape(literal_json)} -->",
                f"## {entry.id}",
                f"- Source: `{entry.relpath}:{entry.line}`",
                f"- Kind: `{entry.kind}`",
                f"- Hash: `{entry.sha}`",
                "",
                "Current:",
                "~~~text",
                entry.text,
                "~~~",
                "",
                "Replacement:",
                "~~~text",
                "",
                "~~~",
                "",
                "Source literal:",
                "~~~text",
                entry.literal,
                "~~~",
                "",
            ]
        )

    REVIEW_PATH.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {REVIEW_PATH.relative_to(ROOT)} ({len(entries)} entries)")


ENTRY_RE = re.compile(
    r"<!-- string-review id=(?P<id>\S+) file=(?P<file>\S+) line=(?P<line>\d+) "
    r"kind=(?P<kind>\S+) sha=(?P<sha>\S+) literal=(?P<literal>.*?) -->"
    r".*?Current:\n~~~text\n(?P<current>.*?)\n~~~"
    r".*?Replacement:\n~~~text\n(?P<replacement>.*?)\n~~~",
    re.DOTALL,
)


def replacement_literal(kind: str, quote: str, replacement: str) -> str:
    escaped = encode_escaped(replacement)
    if kind == "swift":
        return f'"{escaped}"'
    if quote == "'":
        return "'" + replacement.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n") + "'"
    return f'"{escaped}"'


def apply_review() -> None:
    if not REVIEW_PATH.exists():
        raise SystemExit(f"missing {REVIEW_PATH.relative_to(ROOT)}; run export first")

    text = REVIEW_PATH.read_text(encoding="utf-8")
    changes_by_file: dict[pathlib.Path, list[tuple[str, str, str]]] = {}
    requested = 0
    skipped: list[str] = []

    for match in ENTRY_RE.finditer(text):
        replacement = match.group("replacement")
        if not replacement.strip():
            continue
        requested += 1
        file_path = ROOT / match.group("file")
        literal = json.loads(match.group("literal").replace("-- >", "-->"))
        current = match.group("current")
        if sha_text(current) != match.group("sha"):
            skipped.append(f"{match.group('id')}: current text hash changed")
            continue
        quote_match = re.match(r'([rubfRUBF]*)(["\'])', literal)
        quote = quote_match.group(2) if quote_match else '"'
        new_literal = replacement_literal(match.group("kind"), quote, replacement)
        changes_by_file.setdefault(file_path, []).append((match.group("id"), literal, new_literal))

    applied = 0
    for file_path, changes in changes_by_file.items():
        source = file_path.read_text(encoding="utf-8")
        for entry_id, old_literal, new_literal in changes:
            count = source.count(old_literal)
            if count != 1:
                skipped.append(f"{entry_id}: expected one source literal match, found {count}")
                continue
            source = source.replace(old_literal, new_literal, 1)
            applied += 1
        file_path.write_text(source, encoding="utf-8")

    print(f"requested {requested}, applied {applied}, skipped {len(skipped)}")
    for item in skipped:
        print(f"skip: {item}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["export", "apply"])
    args = parser.parse_args()
    if args.command == "export":
        export_review()
    else:
        apply_review()


if __name__ == "__main__":
    main()
