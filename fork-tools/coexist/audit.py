#!/usr/bin/env python3
"""Inventory everything that ties the app to its own package name or to a host path.

Why this exists
---------------
The coexistence package is not one edit. `applicationId` is read at runtime by
providers, task affinities, intent actions, component lookups and launcher
aliases; a single hardcoded copy of the name breaks one of those silently. The
point of this report is to turn "I think that is all of them" into a list with
file and line numbers.

It has to run where the whole checkout exists. This workstation cannot clone the
363 MB repository (the egress cuts long connections and codeload serves no
Range), and GitHub's code search returns nothing for this fork, so the scan
belongs in CI. `fork-tools/coexist/audit.yml` does exactly that.

Usage
-----
    python3 -I fork-tools/coexist/audit.py                 # report to stdout
    python3 -I fork-tools/coexist/audit.py --out audit.md  # and to a file
    python3 -I fork-tools/coexist/audit.py --limit 400     # cap the printed table

Exit status is 0 even when it finds things: this is a measurement, not a gate.
"""

from __future__ import annotations

import argparse
import collections
import os
import re
import sys
from pathlib import Path

SELF = "io.github.ccch1mneyyy.dsh_app"
SELF_FAMILY = "io.github.ccch1mneyyy"

# Directories that are generated, vendored, or simply not ours to reason about.
SKIP_DIRS = {
    ".git", ".gradle", ".dart_tool", "node_modules", "build", "dist",
    "__pycache__", ".idea", ".vscode", ".refs",
}

# The scanner must not report itself: its pattern table quotes the very strings
# it hunts for, which would fill the report with noise from one file.
SKIP_PATHS = {"fork-tools/coexist/audit.py"}

# Only text we can meaningfully grep. Markdown is counted separately: it almost
# always discusses the package name rather than depending on it.
SCAN_EXT = {
    ".kt", ".java", ".dart", ".xml", ".kts", ".gradle", ".properties",
    ".json", ".yaml", ".yml", ".sh", ".py", ".mjs", ".js", ".ts", ".rs",
    ".toml", ".cfg", ".pro", ".gradle.kts", ".txt", ".proguard",
}
SKIP_EXT = {".md", ".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".ttf",
            ".otf", ".so", ".apk", ".aab", ".jar", ".zip", ".xz", ".gz",
            ".onnx", ".bin", ".ico", ".pdf", ".diff", ".patch"}

# Files where the name only ever appears as data (manifest attribute, gradle
# value, json key), so a plain substring match is the right test.
DATA_EXT = {".xml", ".gradle", ".kts", ".properties", ".json", ".yaml",
            ".yml", ".pro", ".proguard", ".toml", ".cfg", ".txt"}

# In source files the package name appears three different ways and only one of
# them matters:
#   package io.github.ccch1mneyyy.dsh_app.foo;   <- namespace, NOT applicationId
#   import  io.github.ccch1mneyyy.dsh_app.Bar;   <- same
#   ComponentName("io.github.ccch1mneyyy...")    <- real coupling, in a literal
# So source files are scanned for *quoted* occurrences only.
LITERAL_RE = re.compile(r"'([^'\\]*)'|\"((?:[^\"\\]|\\.)*)\"")
DECL_RE = re.compile(r"^\s*(?:package|import)\s")

PATTERNS = [
    ("self_package", re.compile(re.escape(SELF)),
     "the app's own applicationId / namespace"),
    ("self_family", re.compile(re.escape(SELF_FAMILY)),
     "the publisher id, e.g. the old LSPosed module"),
    ("host_data_path", re.compile(r"/data/data"),
     "absolute host path; breaks in a second install"),
    ("external_storage", re.compile(r"/storage/emulated/0"),
     "absolute external path"),
    ("packagemanager_lookup", re.compile(
        r"\b(?:getPackageName|getInstalledPackages|PackageInfo|ComponentName|resolveActivity|"
        r"queryIntentActivities|setComponent|getLaunchIntentForPackage|applicationId)\b"),
     "runtime component/package resolution"),
]

# A line may opt out in plain words. Used where the string looks exactly like an
# applicationId but is not one (a class-name prefix, say) and no shape rule can
# tell the difference.
MARKER = re.compile(r"\bcoexok\b")

# Namespace references: a class or AIDL name that keeps upstream's package no
# matter what applicationId the build has. Changing these breaks the app
# (a ComponentName pointing at a class that does not exist), so they are counted
# separately rather than as work to do.
NAMESPACE_HINTS = re.compile(
    r"targetClass\s*=|\bDESCRIPTOR\b|\bACTIVITY_CLASS\b"
)
# A dotted name whose last segment is capitalised is a class, not a package.
CLASS_NAME = re.compile(r'^"?[\w.]*\.[A-Z][\w$]*"?$')

# Test fixtures, dev entry points and upstream tooling quote the package name as
# sample data. They do not ship and do not resolve components; separate them so
# the "needs work" number means what it says.
TEST_PATH = re.compile(
    r"(^|/)(src/test|src/androidTest|test|tests)/|^app/test/|^tooling/test_|^runtime/tests/|^app/lib/dev/"
)

# Lines that already read the value at build time need nothing done to them.
PARAMETRISED = re.compile(r"\$\{applicationId\}|\$\{?applicationId\}?|\bapplicationId\b\s*=")


def _quoted_literal(line: str) -> str | None:
    """The first quoted string on the line, if any (best effort)."""
    m = re.search(r'"([^"]*)"|\'([^\']*)\'', line)
    if not m:
        return None
    return m.group(1) if m.group(1) is not None else m.group(2)


def is_scannable(path: Path) -> bool:
    suffix = path.suffix.lower()
    if suffix in SKIP_EXT:
        return False
    if suffix in SCAN_EXT:
        return True
    # gradle.kts reports ".kts"; belt and braces for files without a suffix
    return path.name in {"AndroidManifest.xml", "gradle.properties"}


def walk(root: Path):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            p = Path(dirpath) / name
            if p.is_symlink() or not p.is_file():
                continue
            yield p


def scan(root: Path):
    """Return per-file hits: {relpath: [(lineno, pattern_name, action, text)]}."""
    hits: dict[str, list[tuple[int, str, str, str]]] = {}
    markdown_mentions: collections.Counter[str] = collections.Counter()
    unreadable = 0

    for path in walk(root):
        rel = path.relative_to(root).as_posix()
        if rel in SKIP_PATHS:
            continue
        if path.suffix.lower() in SKIP_EXT:
            if path.suffix.lower() == ".md":
                try:
                    text = path.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    unreadable += 1
                    continue
                if SELF in text or SELF_FAMILY in text:
                    markdown_mentions[rel] = text.count(SELF) + text.count(SELF_FAMILY)
            continue
        if not is_scannable(path):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            unreadable += 1
            continue
        if SELF not in text and SELF_FAMILY not in text and "/data/data" not in text:
            # cheap rejection before paying for the regex sweep
            if "getPackageName" not in text and "ComponentName" not in text:
                continue

        literal_only = path.suffix.lower() not in DATA_EXT
        for lineno, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if not stripped:
                continue
            if DECL_RE.match(line):
                continue
            haystack = line
            if literal_only:
                quoted = [m.group(0) for m in LITERAL_RE.finditer(line)]
                if not quoted:
                    continue
                haystack = " ".join(quoted)
            matched = [name for name, rx, _why in PATTERNS if rx.search(haystack)]
            if not matched:
                continue
            # self_package is a stricter form of self_family; reporting both for
            # one line doubles the count without adding information.
            if "self_package" in matched and "self_family" in matched:
                matched.remove("self_family")
            # A line that reads ${applicationId} is already portable.
            portable = "${applicationId}" in line
            is_test = bool(TEST_PATH.search(rel))
            literal = _quoted_literal(line)
            for name in matched:
                if portable:
                    action = "ok"
                elif MARKER.search(line):
                    action = "namespace"
                elif NAMESPACE_HINTS.search(line):
                    action = "namespace"
                elif literal and CLASS_NAME.match(literal):
                    action = "namespace"
                elif is_test:
                    action = "fixture"
                elif name == "packagemanager_lookup":
                    action = "review"
                else:
                    action = "TODO"
                hits.setdefault(rel, []).append((lineno, name, action, stripped[:200]))
    return hits, markdown_mentions, unreadable


def render(hits, markdown_mentions, unreadable, limit):
    out: list[str] = []
    add = out.append

    by_action = collections.Counter()
    by_pattern = collections.Counter()
    for entries in hits.values():
        for _ln, pat, action, _txt in entries:
            by_action[action] += 1
            by_pattern[pat] += 1

    add("# 共存包耦合面审计\n")
    add(f"扫描根目录：`{Path.cwd()}`\n")
    add("## 汇总\n")
    add("| 分类 | 数量 |")
    add("|---|---|")
    for action in ("TODO", "review", "namespace", "fixture", "ok"):
        add(f"| {action} | {by_action.get(action, 0)} |")
    add(f"| 涉及文件 | {len(hits)} |")
    add(f"| 读不了的文件 | {unreadable} |")
    add("")
    add("| 模式 | 命中 |")
    add("|---|---|")
    for name, _rx, why in PATTERNS:
        add(f"| `{name}`（{why}） | {by_pattern.get(name, 0)} |")
    add("")

    todo_files = sorted(
        (f for f, es in hits.items() if any(a == "TODO" for _l, _p, a, _t in es)),
        key=lambda f: (-sum(1 for e in hits[f] if e[2] == "TODO"), f),
    )
    add(f"## 需要动手的文件（{len(todo_files)} 个）\n")
    add("| 文件 | TODO 行数 |")
    add("|---|---|")
    for f in todo_files[:limit]:
        n = sum(1 for e in hits[f] if e[2] == "TODO")
        add(f"| `{f}` | {n} |")
    if len(todo_files) > limit:
        add(f"| …还有 {len(todo_files) - limit} 个，见 artifact | |")
    add("")

    add("## 逐行明细（TODO）\n")
    shown = 0
    for f in todo_files:
        if shown >= limit:
            add(f"\n_已截断，其余 {len(todo_files) - shown} 个文件见 artifact。_")
            break
        add(f"\n### `{f}`\n")
        add("```")
        for lineno, pat, action, text in hits[f]:
            if action != "TODO":
                continue
            add(f"{lineno:>5}  [{pat}]  {text}")
        add("```")
        shown += 1

    review_files = sorted(f for f, es in hits.items() if any(a == "review" for _l, _p, a, _t in es))
    add(f"\n## 需要人工判断的文件（{len(review_files)} 个）\n")
    for f in review_files[:limit]:
        add(f"- `{f}`")
    if len(review_files) > limit:
        add(f"- …还有 {len(review_files) - limit} 个")

    if markdown_mentions:
        add(f"\n## 文档里提到包名的文件（仅供参考，{len(markdown_mentions)} 个）\n")
        for f, n in markdown_mentions.most_common(20):
            add(f"- `{f}`（{n} 次）")

    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=".")
    ap.add_argument("--out")
    ap.add_argument("--limit", type=int, default=200,
                    help="cap rows per table so the job summary stays readable")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not (root / "app").is_dir():
        print(f"not a dsh-Go checkout: {root}", file=sys.stderr)
        return 2

    hits, md, unreadable = scan(root)
    report = render(hits, md, unreadable, args.limit)
    sys.stdout.write(report)
    if args.out:
        Path(args.out).write_text(report, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
