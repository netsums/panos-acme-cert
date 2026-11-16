#!/usr/bin/env python3
"""Copy the shared text in docs/_shared/ into README.md and PANORAMA.md.

Text that appears word for word in both guides lives once, in
docs/_shared/<name>.md. In README.md and PANORAMA.md it sits between two
hidden markers (GitHub doesn't display HTML comments):

    <!-- BEGIN shared/<name>.md: ... -->
    ...copied text...
    <!-- END shared/<name>.md -->

This script replaces everything between each pair of markers with the
current content of the snippet file. The GitHub Action in
.github/workflows/build-docs.yml runs it on every push to main.

    python3 scripts/build_docs.py          # rewrite the guides
    python3 scripts/build_docs.py --check  # only report, exit 1 if out of date
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHARED = ROOT / "docs" / "_shared"
TARGETS = ["README.md", "PANORAMA.md"]

BLOCK = re.compile(
    r"(?P<begin><!-- BEGIN shared/(?P<name>[\w.-]+\.md)\b[^\n]*-->\n)"
    r"(?P<body>.*?)"
    r"(?P<end><!-- END shared/(?P=name) -->)",
    re.DOTALL,
)


def build(text: str, target: str) -> str:
    def fill(m: re.Match) -> str:
        snippet = SHARED / m["name"]
        if not snippet.is_file():
            sys.exit(f"{target}: marker names {m['name']}, but {snippet.relative_to(ROOT)} doesn't exist")
        body = snippet.read_text(encoding="utf-8").strip("\n")
        return f"{m['begin']}\n{body}\n\n{m['end']}"

    return BLOCK.sub(fill, text)


def main() -> int:
    check = "--check" in sys.argv[1:]
    stale = []
    for target in TARGETS:
        path = ROOT / target
        old = path.read_text(encoding="utf-8")
        # Every BEGIN needs its END, or the shared text would silently stop updating.
        begins = re.findall(r"<!-- BEGIN shared/([\w.-]+\.md)", old)
        ends = re.findall(r"<!-- END shared/([\w.-]+\.md) -->", old)
        if sorted(begins) != sorted(ends):
            sys.exit(f"{target}: BEGIN and END markers don't pair up: {sorted(begins)} vs {sorted(ends)}")
        new = build(old, target)
        if new != old:
            stale.append(target)
            if not check:
                path.write_text(new, encoding="utf-8")
    if check and stale:
        print("Out of date with docs/_shared/: " + ", ".join(stale))
        print("Run: python3 scripts/build_docs.py")
        return 1
    print(("Updated: " + ", ".join(stale)) if stale else "Up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
