#!/usr/bin/env python3
"""Crude brace/paren/bracket balance check for Swift sources (no toolchain here)."""
import glob, re, sys
bad = 0
for f in sorted(glob.glob('Sources/**/*.swift', recursive=True) + glob.glob('Tests/**/*.swift', recursive=True)):
    s = open(f).read()
    t = re.sub(r'"""[\s\S]*?"""', '""', s)
    t = re.sub(r'#"[^"]*"#', '""', t)
    t = re.sub(r'"(?:\\.|[^"\\])*"', '""', t)
    t = re.sub(r'//.*', '', t)
    t = re.sub(r'/\*[\s\S]*?\*/', '', t)
    for o, c in ['{}', '()', '[]']:
        if t.count(o) != t.count(c):
            print(f"{f}: {o} {t.count(o)} vs {c} {t.count(c)}"); bad += 1
print("files checked, imbalances:", bad)
sys.exit(1 if bad else 0)
