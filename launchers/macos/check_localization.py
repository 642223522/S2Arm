#!/usr/bin/env python3
"""Read-only audit of direct Swift L(...) calls (not a Swift parser/UI test).

Exact ordinary string arguments are checked against the launcher catalog and the
subset exposed by BackendText.sharedEntries (S2ArmAppleAdapter). Templates, composed messages,
dynamic/raw/multiline arguments need manual review. Other UI APIs are not scanned.
Exit 1: missing literal mappings; 2: invalid input; 0: no missing literal mappings
(manual review can still be required). Existing gaps are not silently baselined.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent
SLOTS = re.compile(r'\{\d+\}')
HAN = re.compile(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U000323af]')


def string_end(text, start):
    """Skip a Swift string, including nested strings inside interpolation."""
    match = re.match(r'(#+)?("""|")', text[start:])
    hashes, quote = match.group(1) or '', match.group(2)
    end = quote + hashes
    escape = '\\' + hashes
    i = start + len(match.group())
    while i < len(text):
        if text.startswith(end, i):
            return i + len(end)
        if text.startswith(escape + '(', i):
            i += len(escape) + 1
            depth = 1
            while i < len(text) and depth:
                if re.match(r'#+"|"', text[i:]):
                    i = string_end(text, i)
                elif text[i] == '(':
                    depth += 1; i += 1
                elif text[i] == ')':
                    depth -= 1; i += 1
                else:
                    i += 1
        elif text.startswith(escape, i):
            i += len(escape) + 1
        else:
            i += 1
    raise ValueError('unterminated Swift string')


def literal_value(raw):
    if not raw.startswith('"') or raw.startswith('"""') or '\\(' in raw:
        return None
    # Swift's scalar escape differs from JSON. All unsupported escapes stay manual.
    body = raw[1:-1]
    def scalar(match):
        value = int(match.group(1), 16)
        if value > 0x10ffff or 0xd800 <= value <= 0xdfff:
            raise ValueError('invalid Unicode scalar')
        return json.dumps(chr(value), ensure_ascii=False)[1:-1]
    try:
        body = re.sub(r'\\u\{([0-9A-Fa-f]+)\}', scalar, body)
        return json.loads('"' + body + '"')
    except (ValueError, json.JSONDecodeError):
        return None


def tokens(text):
    result = []
    i = 0
    while i < len(text):
        if text[i].isspace():
            i += 1
        elif text.startswith('//', i):
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
        elif text.startswith('/*', i):
            depth = 1; i += 2
            while i < len(text) and depth:
                if text.startswith('/*', i): depth += 1; i += 2
                elif text.startswith('*/', i): depth -= 1; i += 2
                else: i += 1
            if depth: raise ValueError('unterminated Swift comment')
        elif re.match(r'#+"|"', text[i:]):
            end = string_end(text, i)
            result.append(('string', literal_value(text[i:end]), i))
            i = end
        else:
            match = re.match(r'[A-Za-z_][A-Za-z_0-9]*', text[i:])
            word = match.group() if match else text[i]
            result.append((word, None, i)); i += len(word)
    return result


def shared_entries(spec):
    """Only entries actually returned by BackendText.sharedEntries (S2ArmAppleAdapter)."""
    titles = [s['title'] for s in spec['states'] if s['id'] in ('running', 'failed')]
    titles += [spec['event_map']['terminal_results'][key]['title']
               for key in ('job.succeeded', 'job.cancelled')]
    titles += list(spec['pack_graphics_mode']['labels'].values())
    titles += list(spec['stage_labels'].values())
    return [{'source': t['zh-Hans'], 'en': t['en']} for t in titles]


def validate_entries(entries):
    if not isinstance(entries, list) or any(
        not isinstance(entry, dict) or not isinstance(entry.get('source'), str)
        or not isinstance(entry.get('en'), str) for entry in entries
    ):
        raise ValueError('catalog must be an array of source/en string entries')


def audit(text, entries):
    validate_entries(entries)
    exact = {entry['source'] for entry in entries}
    templates = [re.compile(''.join('(.*?)' if SLOTS.fullmatch(part) else re.escape(part)
                  for part in re.split(r'(\{\d+\})', key)), re.DOTALL)
                 for key in exact if SLOTS.search(key)]
    ts = tokens(text)
    findings = []
    for i, (kind, _, pos) in enumerate(ts):
        if kind != 'L' or i + 1 >= len(ts) or ts[i + 1][0] != '(':
            continue
        # A member named L is not the project's global presentation function.
        if i and ts[i - 1][0] in ('.', 'func'):
            continue
        value = ts[i + 2][1] if i + 2 < len(ts) and ts[i + 2][0] == 'string' else None
        simple = i + 3 < len(ts) and ts[i + 3][0] == ')' and value is not None
        status, reason = 'manual', 'dynamic or unsupported Swift expression'
        if simple:
            if value in exact:
                status, reason = 'covered', 'exact catalog/shared key (not a visual assertion)'
            elif not HAN.search(value):
                status, reason = 'unchanged', 'no Han characters; English path preserves it'
            elif '\n' in value or '；' in value or any(p.fullmatch(value) for p in templates):
                reason = 'template or split-message fallback requires runtime review'
            else:
                status, reason = 'missing', 'literal has no exact key or applicable fallback'
        findings.append({'line': text.count('\n', 0, pos) + 1,
                         'source': value if simple else None, 'status': status, 'reason': reason})
    return findings


def missing_inventory(sources, entries):
    """Stable identity: relative path + literal + occurrence count, never line number.

    Exact comparison with a reviewed baseline detects new gaps even when another
    gap is repaired in the same change, and removes stale exemptions on repair.
    """
    counts = Counter((path, row['source']) for path, text in sources.items()
                     for row in audit(text, entries) if row['status'] == 'missing')
    return [{'path': path, 'source': source, 'count': count}
            for (path, source), count in sorted(counts.items())]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sources', nargs='*', type=Path, help='explicit Swift source files; default: launcher sources')
    parser.add_argument('--catalog', type=Path, default=ROOT / 'adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json')
    parser.add_argument('--shared', type=Path, default=ROOT.parent / 'shared/experience.v1.json')
    args = parser.parse_args(argv)
    try:
        entries = json.loads(args.catalog.read_text(encoding='utf-8'))
        validate_entries(entries)
        shared = shared_entries(json.loads(args.shared.read_text(encoding='utf-8')))
        validate_entries(shared)
        if {e['source'] for e in entries} & {e['source'] for e in shared}:
            raise ValueError('catalog duplicates shared experience text')
        entries += shared
        sources = args.sources or sorted((ROOT / 'Sources/S2ArmLauncher').rglob('*.swift'))
        findings = []
        for path in sources:
            findings.extend(dict(path=str(path), **item) for item in audit(path.read_text(encoding='utf-8'), entries))
        counts = {status: sum(item['status'] == status for item in findings)
                  for status in ('covered', 'unchanged', 'manual', 'missing')}
        print(json.dumps({'scope': 'direct L calls only; not full UI coverage', 'counts': counts,
                          'findings': findings}, ensure_ascii=False, indent=2))
        return int(counts['missing'] > 0)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f'localization audit input error: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
