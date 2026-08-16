#!/usr/bin/env python3
"""Every relative link, and every back-ticked *.md path, in tracked markdown
must resolve to a file that exists.

Two passes, because this repo cross-references two ways: real markdown links
([text](docs/DESIGN.md#anchor)) and back-ticked paths in prose (`docs/CI.md`).
A checker that only reads the first form checks almost nothing here.

Fenced code is blanked (not removed, so line numbers hold). URL schemes and
pure in-page anchors are skipped in pass one; an anchor into a markdown file
must match one of its headings, slugged the way GitHub does. Pass two skips
docs/plans/implemented/, whose bodies deliberately name paths as they were.

Emits ::error file=,line= so the finding lands on the line in the PR view.
"""
import os, re, subprocess, sys

LINK = re.compile(r'\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)|^\s*\[[^\]]+\]:\s*(\S+)', re.M)
TICKED = re.compile(r'`([^`\s*<>]+\.md)`')
SCHEME = re.compile(r'^[a-z][a-z0-9+.-]*:')
FENCE = re.compile(r'^\s*(```|~~~)')
HEADING = re.compile(r'^#{1,6}\s+(.*?)\s*#*\s*$')

def slug(h):
    h = re.sub(r'[^\w\s-]', '', h.lower())
    return re.sub(r'\s', '-', h.strip())

def unfenced(lines):
    out, fenced = [], False
    for l in lines:
        if FENCE.match(l):
            fenced = not fenced; out.append(''); continue
        out.append('' if fenced else l)
    return out

def headings(path):
    with open(path, encoding='utf-8') as f:
        return {slug(m.group(1)) for l in unfenced(f.read().splitlines()) if (m := HEADING.match(l))}

files = subprocess.run(['git', 'ls-files', '-z', '*.md'], capture_output=True, text=True, check=True).stdout.split('\0')
files = [f for f in files if f]
fail = checked = 0
for f in files:
    d = os.path.dirname(f)
    with open(f, encoding='utf-8') as fh:
        lines = unfenced(fh.read().splitlines())
    for n, l in enumerate(lines, 1):
        for m in LINK.finditer(l):
            t = m.group(1) or m.group(2)
            if SCHEME.match(t):
                continue
            path, _, anchor = t.partition('#')
            target = os.path.normpath(os.path.join(d, path)) if path else f
            checked += 1
            if not os.path.exists(target):
                print(f'::error file={f},line={n}::broken link {t!r}: {target} does not exist'); fail += 1
            elif anchor and target.endswith('.md') and anchor not in headings(target):
                print(f'::error file={f},line={n}::broken anchor {t!r}: no heading #{anchor} in {target}'); fail += 1
        if f.startswith('docs/plans/implemented/'):
            continue
        for m in TICKED.finditer(l):
            t = m.group(1)
            checked += 1
            if not (os.path.exists(os.path.normpath(os.path.join(d, t))) or os.path.exists(t)):
                print(f'::error file={f},line={n}::`{t}` names a markdown file that does not exist'); fail += 1
print(f'{checked} references checked in {len(files)} markdown files, {fail} broken')
sys.exit(1 if fail else 0)
