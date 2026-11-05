#!/usr/bin/env python3
"""Check catalog parity, indexed placeholders, and literal UI lookup coverage."""
import json
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
catalog_dir = root / "Sources/PoolCore/Localizations"
LANGUAGES = ("en", "zh-Hans", "zh-Hant", "ja", "ko")


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"Duplicate localization key: {key}")
        value[key] = item
    return value


catalogs = {
    language: json.loads((catalog_dir / f"{language}.json").read_text(), object_pairs_hook=unique_object)
    for language in LANGUAGES
}
errors = []
english = catalogs["en"]
placeholder = re.compile(r"\{\d+\}")
for language, catalog in catalogs.items():
    for key in english.keys() - catalog.keys():
        errors.append(f"{language}: missing {key!r}")
    for key in catalog.keys() - english.keys():
        errors.append(f"{language}: extra {key!r}")
    for key, value in catalog.items():
        if language == "en" and re.search(r"[\u3400-\u9fff]", value if isinstance(value, str) else ""):
            errors.append(f"{language}: non-English text for {key!r}")
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{language}: empty or invalid value for {key!r}")
        elif sorted(placeholder.findall(key)) != sorted(placeholder.findall(value)):
            errors.append(f"{language}: placeholders differ for {key!r}")

for language, catalog in catalogs.items():
    if language == "en":
        continue
    same = [key for key, value in catalog.items() if value == english.get(key) and re.search(r"[A-Za-z]{4,}", key)]
    if len(same) > len(english) * 0.1:
        errors.append(f"{language}: {len(same)} entries are copied from English, e.g. {same[:3]!r}")

# Terms stay as the field says them. "conversation" is what Desktop shows and "session" is a Claude Code
# run, so the two keep separate words; token, tok/s and MTok are not translated into look-alikes.
CONVERSATION = {"zh-Hans": "对话", "zh-Hant": "對話", "ja": "会話", "ko": "대화"}
SESSION = {"zh-Hans": "会话", "zh-Hant": "工作階段", "ja": "セッション", "ko": "세션"}
BANNED = {"zh-Hans": ("令牌", "词元", "账户"), "zh-Hant": ("權杖", "詞元", "帳戶", "令牌")}
VERBATIM = ("tok/s", "MTok")
stand_in = re.compile(r"\{\{[A-Z_]+_\d+\}\}")
for language, catalog in catalogs.items():
    for key, value in catalog.items():
        if not isinstance(value, str):
            continue
        if stand_in.search(value):
            errors.append(f"{language}: redaction stand-in in {key!r}")
        for term in VERBATIM:
            if term in key and term not in value:
                errors.append(f"{language}: {term!r} must stay as written in {key!r}")
        for word in BANNED.get(language, ()):
            if word in value:
                errors.append(f"{language}: {word!r} in {key!r}; keep the established term")
        if language == "en":
            continue
        lowered = key.lower()
        if "conversation" in lowered and "session" not in lowered and SESSION[language] in value:
            errors.append(f"{language}: conversation said as session in {key!r}")
        if "session" in lowered and "conversation" not in lowered and CONVERSATION[language] in value:
            errors.append(f"{language}: session said as conversation in {key!r}")

lookup = re.compile(r'\b(?:t|tr|refuse)\(\s*"([^"\n]*)"')
for path in (root / "Sources").rglob("*.swift"):
    source = path.read_text()
    # L10n.swift holds each language's own name, which must not follow the interface language.
    if path.name != "L10n.swift" and re.search(r"[\u3400-\u9fff]", source):
        errors.append(f"{path.relative_to(root)}: hard-coded CJK text")
    for match in lookup.finditer(source):
        if match.group(1) not in english:
            errors.append(f"{path.relative_to(root)}: missing lookup {match.group(1)!r}")

for source in ("Sources/PoolRuntime/RuntimeError.swift", "Sources/PoolCore/Bridge.swift", "Sources/PoolEngine/QuotaRefresh.swift", "Sources/PoolPrivacy/PrivacyContract.swift"):
    for key in re.findall(r'case [^:\n]+: return "([^"\n]+)"', (root / source).read_text()):
        if key not in english:
            errors.append(f"{source}: missing fixed error {key!r}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Localization passed: {len(english)} keys in {len(catalogs)} catalogs.")
