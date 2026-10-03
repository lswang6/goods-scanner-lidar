#!/usr/bin/env python3
"""Localization gate. Exit 1 on any problem.

  python3 tools/l10n/check.py                  # all 10 target languages
  python3 tools/l10n/check.py --langs zh-Hans  # subset

Checks: every translatable key in l10n/keys.json is translated (non-empty) in each language; format
specifiers match the English key (same multiset, positional allowed); plural keys carry the language's
required CLDR categories; InfoPlist strings exist; no Swift string literal in GoodsScanner/ contains Han
characters or CJK punctuation (outside comments and the DEBUG seedDemo data)."""
import argparse, glob, os, re, sys
from common import L10N, LANGS, PLURAL_REQUIRED, PLURAL_ALLOWED, ROOT, load, specs, infoplist_keys

HAN = re.compile(r"[㐀-䶿一-鿿　-〿＀-｠]")

def check_lang(lang, keys, errs):
    t = load(os.path.join(L10N, lang + ".json"))
    if t is None: errs.append(f"{lang}: l10n/{lang}.json missing"); return
    need = PLURAL_REQUIRED.get(lang, {"other"})
    for e in keys:
        k = e["key"]
        if e.get("translate") is False: continue
        v = t.get(k)
        if v is None or v == "" or v == {}: errs.append(f"{lang}: missing {k!r}"); continue
        forms = v if isinstance(v, dict) else {"other": v}
        if isinstance(v, dict) and not e.get("plural"): errs.append(f"{lang}: {k!r} is not plural, give a plain string")
        if e.get("plural") and isinstance(v, str) and need != {"other"}:
            errs.append(f"{lang}: plural {k!r} needs {sorted(need)} forms")
        if e.get("plural") and isinstance(v, dict):
            if need - set(v): errs.append(f"{lang}: plural {k!r} lacks {sorted(need - set(v))}")
            if set(v) - PLURAL_ALLOWED: errs.append(f"{lang}: {k!r} has unknown categories {sorted(set(v) - PLURAL_ALLOWED)}")
        for cat, s in forms.items():
            if not isinstance(s, str) or not s.strip(): errs.append(f"{lang}: empty {cat!r} for {k!r}")
            elif specs(s) != specs(k): errs.append(f"{lang}: specifiers {specs(s)} != {specs(k)} in {k!r} ({cat})")
    known = {e["key"] for e in keys}
    for k in t:
        if k not in known: errs.append(f"{lang}: stale key not in keys.json: {k!r}")
    ip = load(os.path.join(L10N, "infoplist", lang + ".json"), {})
    for k in infoplist_keys():
        if not ip.get(k): errs.append(f"{lang}: infoplist/{lang}.json lacks {k}")

def literals(line):
    """String-literal contents on one line, ignoring a trailing // comment. ponytail: per-line, no multi-line strings."""
    out, cur, i, in_s = [], "", 0, False
    while i < len(line):
        c = line[i]
        if in_s:
            if c == "\\": cur += line[i:i + 2]; i += 2; continue
            if c == '"': out.append(cur); cur = ""; in_s = False
            else: cur += c
        elif c == '"': in_s = True
        elif line.startswith("//", i): break
        i += 1
    return out

def han_literals():
    hits = []
    for path in sorted(glob.glob(os.path.join(ROOT, "GoodsScanner", "**", "*.swift"), recursive=True)):
        lines, in_block, in_seed = open(path, encoding="utf-8").read().split("\n"), False, False
        for n, line in enumerate(lines, 1):
            s = line.strip()
            if "func seedDemo" in s: in_seed = True   # DEBUG demo data (App.swift) stays Chinese on purpose
            if in_seed:
                if s == "#endif": in_seed = False
                continue
            if in_block:
                if "*/" in s: in_block = False
                continue
            if s.startswith("/*"): in_block = "*/" not in s; continue
            if any(HAN.search(x) for x in literals(line)):
                hits.append(f"{os.path.relpath(path, ROOT)}:{n}: {s[:100]}")
    return hits

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--langs", nargs="*", default=LANGS)
    a = ap.parse_args()
    keys = load(os.path.join(L10N, "keys.json"))
    errs = []
    en = load(os.path.join(L10N, "en.json"), {})
    for e in keys:  # English plural forms live in en.json
        if e.get("plural"):
            v = en.get(e["key"])
            if not isinstance(v, dict) or {"one", "other"} - set(v): errs.append(f"en: plural {e['key']!r} needs one/other in l10n/en.json")
            elif any(specs(s) != specs(e["key"]) for s in v.values()): errs.append(f"en: specifier mismatch in {e['key']!r}")
    for lang in a.langs: check_lang(lang, keys, errs)
    for h in han_literals(): errs.append(f"Han literal: {h}")
    by_lang = {}
    for e in errs: by_lang[e.split(":")[0]] = by_lang.get(e.split(":")[0], 0) + 1
    for e in errs[:400]: print(e)
    if len(errs) > 400: print(f"… {len(errs) - 400} more")
    print(f"{len(keys)} keys, {sum(1 for k in keys if k.get('plural'))} plural; problems: {by_lang or 'none'}")
    sys.exit(1 if errs else 0)

if __name__ == "__main__": main()
