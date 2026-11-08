#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Convert a git-diff patch from old private-repo paths to public-repo paths.

Usage:
  port_old_patch.py [--partial] [--table TSV] [patch_file]

Reads from patch_file or stdin. Rewrites diff --git / --- / +++ / rename
header lines using the prefix table in tools/port_old_paths.tsv (longest-
prefix match). Patch body (context and diff lines) is passed through as-is.
Outputs the converted patch to stdout.

Unmapped files are listed on stderr; exits 1. With --partial, the convertible
portion is still written and exit is still 1.
"""
import argparse
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TSV = os.path.join(SCRIPT_DIR, 'port_old_paths.tsv')


def load_table(tsv_path: str) -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    with open(tsv_path, encoding='utf-8') as fh:
        for line in fh:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) >= 2:
                rows.append((parts[0], parts[1]))
    rows.sort(key=lambda r: len(r[0]), reverse=True)  # longest prefix first
    return rows


def map_path(path: str, table: list[tuple[str, str]]) -> str | None:
    for old, new in table:
        if path.startswith(old):
            return new + path[len(old):]
    return None


# git may quote non-ASCII paths: "a/path\303\251" — octal bytes, still ASCII prefix
_RE_DIFF_UNQUOTED = re.compile(r'^(diff --git )a/(\S.*) b/(\S.*)$')
_RE_DIFF_QUOTED = re.compile(r'^(diff --git )"a/([^"]*)" "b/([^"]*)"$')
_RE_MINUS = re.compile(r'^(--- )a/(.+)$')
_RE_PLUS = re.compile(r'^(\+\+\+ )b/(.+)$')
_RE_REN_FROM = re.compile(r'^(rename from )(.+)$')
_RE_REN_TO = re.compile(r'^(rename to )(.+)$')


def _remap(path: str, table: list[tuple[str, str]], unmapped: set[str]) -> str:
    result = map_path(path, table)
    if result is None:
        unmapped.add(path)
        return path
    return result


def convert_patch(
    lines: list[str],
    table: list[tuple[str, str]],
) -> tuple[list[str], set[str]]:
    unmapped: set[str] = set()
    out: list[str] = []
    for line in lines:
        nl = '' if line.endswith('\n') else '\n'
        raw = line.rstrip('\n')

        m = _RE_DIFF_QUOTED.match(raw)
        if m:
            prefix, a, b = m.group(1), m.group(2), m.group(3)
            na = _remap(a, table, unmapped)
            nb = _remap(b, table, unmapped)
            out.append(f'{prefix}"a/{na}" "b/{nb}"\n')
            continue

        m = _RE_DIFF_UNQUOTED.match(raw)
        if m:
            prefix, a, b = m.group(1), m.group(2), m.group(3)
            na = _remap(a, table, unmapped)
            nb = _remap(b, table, unmapped)
            out.append(f'{prefix}a/{na} b/{nb}\n')
            continue

        m = _RE_MINUS.match(raw)
        if m:
            prefix, p = m.group(1), m.group(2)
            if p != '/dev/null':
                p = _remap(p, table, unmapped)
            out.append(f'{prefix}a/{p}\n')
            continue

        m = _RE_PLUS.match(raw)
        if m:
            prefix, p = m.group(1), m.group(2)
            if p != '/dev/null':
                p = _remap(p, table, unmapped)
            out.append(f'{prefix}b/{p}\n')
            continue

        m = _RE_REN_FROM.match(raw)
        if m:
            prefix, p = m.group(1), m.group(2)
            out.append(f'{prefix}{_remap(p, table, unmapped)}\n')
            continue

        m = _RE_REN_TO.match(raw)
        if m:
            prefix, p = m.group(1), m.group(2)
            out.append(f'{prefix}{_remap(p, table, unmapped)}\n')
            continue

        out.append(line if line.endswith('\n') else line + '\n')
    return out, unmapped


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('patch', nargs='?', help='patch file (default: stdin)')
    ap.add_argument('--partial', action='store_true',
                    help='write convertible hunks even when some paths are unmapped')
    ap.add_argument('--table', default=DEFAULT_TSV,
                    metavar='TSV',
                    help='path mapping TSV (default: tools/port_old_paths.tsv)')
    args = ap.parse_args()

    table = load_table(args.table)

    if args.patch:
        with open(args.patch, encoding='utf-8', errors='replace') as fh:
            lines = fh.readlines()
    else:
        lines = sys.stdin.readlines()

    out_lines, unmapped = convert_patch(lines, table)

    if args.partial or not unmapped:
        sys.stdout.writelines(out_lines)

    if unmapped:
        for p in sorted(unmapped):
            print(f'unmapped: {p}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
