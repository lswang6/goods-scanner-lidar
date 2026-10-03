#!/usr/bin/env python3
"""Write GoodsScanner/Localizable.xcstrings and GoodsScanner/InfoPlist.xcstrings from l10n/.

Inputs: l10n/keys.json (inventory), l10n/<lang>.json ({key: text} or, for plural keys,
{key: {"one": ..., "other": ...}}), l10n/en.json (optional English overrides, e.g. plural forms),
l10n/infoplist/<lang>.json. Missing translations are simply left out (check.py reports them)."""
import glob, json, os, sys
from common import L10N, ROOT, SPEC, load, plural_arg, arg_spec, infoplist_keys

def unit(v): return {"stringUnit": {"state": "translated", "value": v}}

def positional(s):
    """`%@ … %lld` -> `%1$@ … %2$lld`. Required inside substitutions: the outer `%N$#@count@` is positional, and a
    plain `%@` after it would read the wrong argument (crash)."""
    if any(m.group(1) for m in SPEC.finditer(s)): return s
    n = iter(range(1, 100))
    return SPEC.sub(lambda m: "%" + str(next(n)) + "$" + m.group(0)[1:], s.replace("%%", "\0")).replace("\0", "%%")

def localization(entry, value, lang):
    if isinstance(value, str): return unit(value)
    if not entry.get("plural"): sys.exit(f"{lang}: {entry['key']!r} is not a plural key but got {value!r}")
    n = plural_arg(entry)
    # Whole-sentence variants behind one substitution: works for any argument position / count of numbers.
    return {"stringUnit": {"state": "translated", "value": "%#@count@"},
            "substitutions": {"count": {"argNum": n, "formatSpecifier": arg_spec(entry["key"], n),
                                        "variations": {"plural": {c: unit(positional(v)) for c, v in value.items()}}}}}

def write(path, strings):
    doc = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2, sort_keys=True); f.write("\n")

def langs_in(d):
    return sorted(os.path.basename(p)[:-5] for p in glob.glob(os.path.join(d, "*.json")) if not p.endswith("keys.json"))

def main():
    keys = load(os.path.join(L10N, "keys.json"))
    tr = {l: load(os.path.join(L10N, l + ".json")) for l in langs_in(L10N)}
    strings = {}
    for e in keys:
        s = {"extractionState": "manual"}
        if e.get("comment"): s["comment"] = e["comment"]
        if e.get("translate") is False: s["shouldTranslate"] = False
        else:
            locs = {l: localization(e, t[e["key"]], l) for l, t in tr.items() if t.get(e["key"])}
            if locs: s["localizations"] = locs
        strings[e["key"]] = s
    write(os.path.join(ROOT, "GoodsScanner", "Localizable.xcstrings"), strings)

    idir = os.path.join(L10N, "infoplist")
    itr = {l: load(os.path.join(idir, l + ".json")) for l in langs_in(idir)}
    istrings = {k: {"extractionState": "manual",
                    "localizations": {l: unit(t[k]) for l, t in itr.items() if t.get(k)}} for k in infoplist_keys()}
    write(os.path.join(ROOT, "GoodsScanner", "InfoPlist.xcstrings"), istrings)
    print(f"Localizable.xcstrings: {len(strings)} keys, languages {sorted(tr)}; InfoPlist.xcstrings: {sorted(istrings)} in {sorted(itr)}")

if __name__ == "__main__": main()
