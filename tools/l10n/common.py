"""Shared bits for the l10n tools (stdlib only)."""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
L10N = os.path.join(ROOT, "l10n")
LANGS = ["zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "pt-BR", "ru", "vi"]  # + en (source)
# CLDR cardinal categories a translation must provide for integer counts.
PLURAL_REQUIRED = {"en": {"one", "other"}, "es": {"one", "other"}, "fr": {"one", "other"}, "de": {"one", "other"},
                   "pt-BR": {"one", "other"}, "ru": {"one", "few", "many", "other"}}
PLURAL_ALLOWED = {"zero", "one", "two", "few", "many", "other"}
SPEC = re.compile(r"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(lld|llu|ld|lu|d|i|u|@|f|e|g|s)")

def load(path, default=None):
    return json.load(open(path, encoding="utf-8")) if os.path.exists(path) else default

def specs(s):
    """Format specifiers of `s`, positional index stripped (so `%2$@` == `%@`); `%%` ignored."""
    return sorted(m.group(2) for m in SPEC.finditer(s.replace("%%", "")))

def plural_arg(entry):
    """1-based argument number that drives the plural: keys.json `pluralArg`, else the first integer argument."""
    if entry.get("pluralArg"): return entry["pluralArg"]
    for i, m in enumerate(SPEC.finditer(entry["key"].replace("%%", "")), 1):
        if m.group(2) not in "@fegs": return i
    raise ValueError(f"plural key without an integer argument: {entry['key']!r}")

def arg_spec(key, n):
    return [m.group(2) for m in SPEC.finditer(key.replace("%%", ""))][n - 1]

def infoplist_keys():
    """CFBundleDisplayName / CFBundleName / NS*UsageDescription declared in project.yml's info properties."""
    yml = open(os.path.join(ROOT, "project.yml"), encoding="utf-8").read()
    return sorted(set(re.findall(r"^\s+(CFBundleDisplayName|CFBundleName|NS\w+UsageDescription):", yml, re.M)))
