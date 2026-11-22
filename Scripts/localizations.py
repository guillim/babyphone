#!/usr/bin/env python3
"""Checks that every string the app shows exists in French and in English.

The app refers to its strings by key ("role.title"). A key that is missing
from the catalog shows up on screen as the raw key, which no compiler catches.
Run from the repository root; exits non-zero on any mismatch.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "App" / "Resources" / "Localizable.xcstrings"
LANGUAGES = ("fr", "en")
# First word of every key. Other dotted strings in the code, such as SF Symbol
# names ("wifi.slash"), are not localization keys. Add new families here.
FAMILIES = {
    "baby", "common", "diagnostics", "error", "failure", "icloud", "journal", "meter", "network",
    "notification", "pairing", "parent", "role", "sensitivity", "settings",
}
# A key is lowercase words joined by dots, optionally followed by interpolations.
KEY = re.compile(r'"([a-z][A-Za-z0-9]*)((?:\.[A-Za-z0-9]+)+)((?: \\\([^"]*\))*)"')
# Accessibility identifiers share the dotted shape but are never shown.
IDENTIFIER = re.compile(r'accessibilityIdentifier\(.*')


def keys_in_code():
    found = set()
    for path in (ROOT / "App").rglob("*.swift"):
        for family, rest, interpolations in KEY.findall(IDENTIFIER.sub("", path.read_text())):
            if family in FAMILIES:
                found.add(family + rest + " %@" * interpolations.count("\\("))
    return found


def main():
    catalog = json.loads(CATALOG.read_text())["strings"]
    used = keys_in_code()
    problems = [f"missing from the catalog: {key}" for key in sorted(used - catalog.keys())]
    problems += [f"unknown family, add it to FAMILIES: {key}" for key in sorted(catalog) if key.split(".")[0] not in FAMILIES]
    problems += [f"in the catalog but never used: {key}" for key in sorted(catalog.keys() - used)]
    for key, entry in sorted(catalog.items()):
        for language in LANGUAGES:
            value = entry.get("localizations", {}).get(language, {}).get("stringUnit", {}).get("value", "")
            if not value:
                problems.append(f"no {language} text: {key}")
            elif value.count("%@") != key.count("%@"):
                problems.append(f"wrong number of placeholders in {language}: {key}")
    for problem in problems:
        print(problem)
    print(f"{len(catalog)} strings, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
