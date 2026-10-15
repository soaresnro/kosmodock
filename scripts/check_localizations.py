#!/usr/bin/env python3
"""Checks that every UI string used in the Swift sources is translated.

    python3 scripts/check_localizations.py          # verify all languages
    python3 scripts/check_localizations.py --keys   # print the keys found in code

Keys are the English text. They come from SwiftUI literals (Text("…"),
Button("…"), .help("…") …) and from L10n.tr("…") calls. Each language's
Localization/<lang>.lproj/Localizable.strings must contain every key, and the
format specifiers (%@, %lld, %d) of a translation must match its key's.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "Kosmodock"
LOCALIZATION = ROOT / "Localization"
LANGUAGES = ["en", "pt-BR", "es"]

STRING = r'"((?:[^"\\]|\\.)*)"'
# First-argument literals that SwiftUI treats as LocalizedStringKey.
SWIFTUI_PATTERNS = [
    r'\bText\(' + STRING,
    r'\bLabel\(' + STRING,
    r'\bButton\(' + STRING,
    r'\bToggle\(' + STRING,
    r'\bSection\(' + STRING,
    r'\bPicker\(' + STRING,
    r'\bMenu\(' + STRING,
    r'\bTextField\(' + STRING,
    r'\bLabeledContent\(' + STRING,
    r'\bColorPicker\(' + STRING,
    r'\bContentUnavailableView\(' + STRING,
    r'\.navigationTitle\(' + STRING,
    r'\.confirmationDialog\(' + STRING,
    r'\.help\(' + STRING,
    r'\bHintText\(' + STRING,
    r'\bmessage: ' + STRING,
]
L10N_PATTERN = r'\bL10n\.tr\(' + STRING
FORMAT = re.compile(r'%(?:\d+\$)?(?:lld|ld|d|@|lf|f)')


def unescape(text):
    return text.encode("utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")


def keys_in_code():
    keys = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        if path.name == "SnapshotRenderer.swift":
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if line.strip().startswith("//"):
                continue
            for pattern in SWIFTUI_PATTERNS + [L10N_PATTERN]:
                for match in re.finditer(pattern, line):
                    raw = match.group(1)
                    if "\\(" in raw:  # interpolated literals must use L10n.tr
                        print(f"warning: interpolated SwiftUI literal at {path.name}:{number}: {raw}")
                        continue
                    if not re.search(r"[A-Za-z]", raw):
                        continue
                    keys.setdefault(unescape(raw), f"{path.name}:{number}")
    return keys


def parse_strings(path):
    entries = {}
    text = path.read_text(encoding="utf-8")
    for match in re.finditer(STRING + r'\s*=\s*' + STRING + r'\s*;', text):
        entries[unescape(match.group(1))] = unescape(match.group(2))
    return entries


def main():
    keys = keys_in_code()
    if "--keys" in sys.argv:
        for key in sorted(keys, key=str.lower):
            print(key)
        return 0

    failures = 0
    for language in LANGUAGES:
        path = LOCALIZATION / f"{language}.lproj" / "Localizable.strings"
        if not path.exists():
            print(f"✗ {language}: missing {path.relative_to(ROOT)}")
            failures += 1
            continue
        table = parse_strings(path)
        missing = [key for key in keys if key not in table]
        mismatched = [
            key for key in keys
            if key in table and sorted(FORMAT.findall(key)) != sorted(FORMAT.findall(table[key]))
        ]
        unused = [key for key in table if key not in keys]
        for key in missing:
            print(f"✗ {language}: missing “{key}” ({keys[key]})")
        for key in mismatched:
            print(f"✗ {language}: format specifiers differ for “{key}” → “{table[key]}”")
        if unused:
            print(f"  {language}: {len(unused)} unused entr{'y' if len(unused) == 1 else 'ies'}")
        failures += len(missing) + len(mismatched)
        if not missing and not mismatched:
            print(f"✓ {language}: {len(keys)} keys translated")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
