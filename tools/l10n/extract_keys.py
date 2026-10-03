#!/usr/bin/env python3
"""Refresh l10n/keys.json from the .stringsdata files Xcode writes during a build (SWIFT_EMIT_LOC_STRINGS=YES).

    xcodebuild build ... -derivedDataPath build/DD-l1
    python3 tools/l10n/extract_keys.py [build/DD-l1]

Existing entries keep their hand-written comment / plural / pluralArg; new keys get an auto comment
(file + UI element + length hint). Keys no longer in source are dropped (and listed)."""
import glob, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
KEYS = os.path.join(ROOT, "l10n", "keys.json")
dd = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "DD-l1")

files = glob.glob(os.path.join(dd, "Build/Intermediates.noindex/GoodsScanner.build/*/GoodsScanner.build/Objects-normal/*/*.stringsdata"))
if not files: sys.exit(f"no .stringsdata under {dd}; build the app first")

KINDS = [  # (regex on the source text just before the literal, element, length hint)
    (r"tabItem|Label\(\"$", None, None),
    (r"Button\($|Button\(\"$|confirmationAction|cancellationAction", "button", "keep short (≤ 16 chars)"),
    (r"navigationTitle\($", "navigation title", "keep short (≤ 24 chars)"),
    (r"Section\($", "section header", "≤ 30 chars"),
    (r"TextField\($|prompt: $", "text field placeholder", None),
    (r"alert\($|confirmationDialog\($", "alert / dialog title", None),
    (r"accessibilityLabel\(|accessibilityHint\(", "VoiceOver label (not shown)", None),
    (r"unit: $", "unit after a number", "keep very short"),
    (r"label: $|addTile\($|dimField\($", "short label", "keep short (≤ 16 chars)"),
    (r"title: $", "title", None), (r"message: $", "message", None),
    (r"String\(localized: $", "code-built text", None),
]

found = {}
for f in sorted(files):
    j = json.load(open(f))
    src = j.get("source", "")
    lines = open(src).read().split("\n") if os.path.exists(src) else []
    for e in j.get("tables", {}).get("Localizable", []):
        loc = e.get("location", {}); ln, col = loc.get("startingLine", 0), loc.get("startingColumn", 1)
        before = lines[ln - 1][:col - 1].rstrip() if 0 < ln <= len(lines) else ""
        before = before.rstrip('"')
        kind = hint = None
        for rx, k, h in KINDS:
            if re.search(rx, before + ("\"" if rx.endswith('\\"$') else "")):
                kind, hint = k, h; break
        if re.search(r"tabItem", lines[ln - 1] if 0 < ln <= len(lines) else ""):
            kind, hint = "tab bar title", "≤ 12 chars"
        where = os.path.basename(src).replace(".swift", "")
        d = found.setdefault(e["key"], {"where": [], "kind": kind, "hint": hint, "dev": e.get("comment", "")})
        if where not in d["where"]: d["where"].append(where)

old = {k["key"]: k for k in json.load(open(KEYS))} if os.path.exists(KEYS) else {}
out = []
for key in sorted(found, key=str.lower):
    d = found[key]
    if key in old: out.append(old[key]); continue
    parts = [", ".join(d["where"])] + [p for p in (d["kind"], d["dev"], d["hint"]) if p]
    out.append({"key": key, "comment": " · ".join(parts), "plural": False})
gone = sorted(set(old) - set(found))
json.dump(out, open(KEYS, "w"), ensure_ascii=False, indent=2); open(KEYS, "a").write("\n")
print(f"{len(out)} keys ({len(out) - len(set(old) & set(found))} new); removed: {gone or 'none'}")
