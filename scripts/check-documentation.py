#!/usr/bin/env python3
"""Validate local Markdown links and release-version documentation."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
MARKDOWN_FILES = sorted(
    path
    for pattern in ("*.md", "*.mdx")
    for path in ROOT.rglob(pattern)
    if ".build" not in path.parts and ".git" not in path.parts
)
LINK_PATTERN = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")
VERSION_PATTERN = re.compile(r'const Current = "([^"]+)"')


def check_local_links() -> list[str]:
    errors: list[str] = []
    for document in MARKDOWN_FILES:
        text = document.read_text(encoding="utf-8")
        for raw_target in LINK_PATTERN.findall(text):
            target = raw_target.strip().split()[0].strip("<>")
            if target.startswith(("http://", "https://", "mailto:", "#", "/")):
                continue
            path_text = unquote(target.split("#", 1)[0].split("?", 1)[0])
            if not path_text:
                continue
            resolved = (document.parent / path_text).resolve()
            if not resolved.exists():
                errors.append(
                    f"{document.relative_to(ROOT)}: missing local link target {target!r}"
                )
    return errors


def check_release_version() -> list[str]:
    errors: list[str] = []
    version_file = ROOT / "internal/version/version.go"
    match = VERSION_PATTERN.search(version_file.read_text(encoding="utf-8"))
    if match is None:
        return ["internal/version/version.go: release version not found"]

    version = match.group(1)
    if version.endswith("-dev"):
        errors.append(f"release version still has development suffix: {version}")

    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    if f"## [{version}]" not in changelog:
        errors.append(f"CHANGELOG.md: missing release heading for {version}")

    root_test = (ROOT / "cmd/root_test.go").read_text(encoding="utf-8")
    if "version.Current" not in root_test:
        errors.append("cmd/root_test.go: missing version.Current assertion")

    return errors


def main() -> int:
    errors = check_local_links() + check_release_version()
    if errors:
        for error in errors:
            print(f"documentation check: {error}", file=sys.stderr)
        return 1
    print(
        f"documentation check passed: {len(MARKDOWN_FILES)} Markdown/MDX files; "
        "local links and release version are consistent"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
