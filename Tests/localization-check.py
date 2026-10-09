#!/usr/bin/env python3
"""
Checks that localization keys and template placeholders align between
English and Chinese translation tables in Sources/Localization.swift.
"""

import re
import sys
from typing import Dict, List, Optional, Tuple


def strip_comments(text: str) -> str:
    """Strip single-line and multi-line comments while preserving string literals."""
    pattern = re.compile(
        r'(?P<single>//[^\n]*)|(?P<multi>/\*.*?\*/)|(?P<string>"(?:\\.|[^"\\])*")',
        re.DOTALL,
    )

    def replacer(match: re.Match) -> str:
        if match.group("single") or match.group("multi"):
            return " "
        return match.group("string")

    return pattern.sub(replacer, text)


def parse_table_for_lang(lang: str, source: str) -> Optional[Dict[str, str]]:
    """Extract key-value pairs for a language table."""
    match = re.search(
        rf'static let {lang}:\s*\[Key:\s*String\]\s*=\s*\[(.*?)\n    \]',
        source,
        re.S,
    )
    if not match:
        return None
    cleaned = strip_comments(match.group(1))
    entries = re.findall(r'\.(\w+):\s*"((?:[^"\\]|\\.)*)"', cleaned)
    return dict(entries)


def parse_tables(source: str) -> Optional[Tuple[Dict[str, str], Dict[str, str]]]:
    """Parse both english and chinese tables from source text."""
    en_dict = parse_table_for_lang("english", source)
    zh_dict = parse_table_for_lang("chinese", source)
    if en_dict is None or zh_dict is None:
        return None
    return en_dict, zh_dict


def check_tables(en_dict: Dict[str, str], zh_dict: Dict[str, str]) -> List[str]:
    """Validate key parity, brace balance, and placeholder parity."""
    errors: List[str] = []

    en_keys = set(en_dict.keys())
    zh_keys = set(zh_dict.keys())

    en_only = en_keys - zh_keys
    zh_only = zh_keys - en_keys
    if en_only:
        errors.append(f"English-only keys: {', '.join(sorted(en_only))}")
    if zh_only:
        errors.append(f"Chinese-only keys: {', '.join(sorted(zh_only))}")

    common_keys = sorted(en_keys & zh_keys)
    for key in common_keys:
        en_val = en_dict[key]
        zh_val = zh_dict[key]

        if en_val.count("{") != en_val.count("}"):
            errors.append(f"unbalanced braces in English .{key}")
        if zh_val.count("{") != zh_val.count("}"):
            errors.append(f"unbalanced braces in Chinese .{key}")

        en_phs = set(re.findall(r"\{([a-zA-Z0-9_]+)\}", en_val))
        zh_phs = set(re.findall(r"\{([a-zA-Z0-9_]+)\}", zh_val))

        missing_in_zh = en_phs - zh_phs
        missing_in_en = zh_phs - en_phs
        mismatch_parts = []
        if missing_in_zh:
            mismatch_parts.append(
                f"missing in Chinese: {{{', '.join(sorted(missing_in_zh))}}}"
            )
        if missing_in_en:
            mismatch_parts.append(
                f"missing in English: {{{', '.join(sorted(missing_in_en))}}}"
            )
        if mismatch_parts:
            errors.append(f"placeholder mismatch in .{key}: {'; '.join(mismatch_parts)}")

    return errors


def run_self_tests() -> None:
    """Run synthetic test cases covering key, placeholder, brace, and syntax edge cases."""
    # 1. Matching tables pass
    src_valid = '''
    static let english: [Key: String] = [
        .greeting: "Hello {name}",
        .ok: "OK"
    ]
    static let chinese: [Key: String] = [
        .greeting: "你好 {name}",
        .ok: "确定"
    ]
    '''
    res = parse_tables(src_valid)
    assert res is not None, "Failed to parse valid synthetic tables"
    assert check_tables(*res) == [], "Valid tables should have 0 errors"

    # 2. Missing key in Chinese
    src_missing_key = '''
    static let english: [Key: String] = [
        .greeting: "Hello {name}",
        .extra: "Extra"
    ]
    static let chinese: [Key: String] = [
        .greeting: "你好 {name}"
    ]
    '''
    en_d, zh_d = parse_tables(src_missing_key)
    errs = check_tables(en_d, zh_d)
    assert any("English-only keys: extra" in e for e in errs), f"Expected missing key error, got: {errs}"

    # 3. Missing placeholder in Chinese
    src_missing_ph_zh = '''
    static let english: [Key: String] = [
        .runningPort: "RUNNING : {port}"
    ]
    static let chinese: [Key: String] = [
        .runningPort: "运行中"
    ]
    '''
    en_d, zh_d = parse_tables(src_missing_ph_zh)
    errs = check_tables(en_d, zh_d)
    assert any(
        "placeholder mismatch in .runningPort: missing in Chinese: {port}" in e
        for e in errs
    ), f"Expected missing placeholder in Chinese, got: {errs}"

    # 4. Missing placeholder in English (placeholder only in Chinese)
    src_missing_ph_en = '''
    static let english: [Key: String] = [
        .runningPort: "RUNNING"
    ]
    static let chinese: [Key: String] = [
        .runningPort: "运行中 : {port}"
    ]
    '''
    en_d, zh_d = parse_tables(src_missing_ph_en)
    errs = check_tables(en_d, zh_d)
    assert any(
        "placeholder mismatch in .runningPort: missing in English: {port}" in e
        for e in errs
    ), f"Expected missing placeholder in English, got: {errs}"

    # 5. Multiple placeholders with partial mismatch
    src_multi_ph = '''
    static let english: [Key: String] = [
        .duration: "{days}d {hours}h"
    ]
    static let chinese: [Key: String] = [
        .duration: "{days} 天"
    ]
    '''
    en_d, zh_d = parse_tables(src_multi_ph)
    errs = check_tables(en_d, zh_d)
    assert any(
        "placeholder mismatch in .duration: missing in Chinese: {hours}" in e
        for e in errs
    ), f"Expected partial multi-placeholder mismatch, got: {errs}"

    # 6. Unbalanced braces
    src_unbalanced = '''
    static let english: [Key: String] = [
        .typo: "Port {port"
    ]
    static let chinese: [Key: String] = [
        .typo: "端口 {port}"
    ]
    '''
    en_d, zh_d = parse_tables(src_unbalanced)
    errs = check_tables(en_d, zh_d)
    assert any("unbalanced braces in English .typo" in e for e in errs), f"Expected unbalanced braces error, got: {errs}"

    # 7. Malformed tables return None
    src_malformed = 'let somethingElse = 123'
    assert parse_tables(src_malformed) is None, "Malformed table should return None"

    # 8. Single-line commented out entry (//) is ignored and reported missing
    src_commented_single = '''
    static let english: [Key: String] = [
        .runningPort: "RUNNING : {port}"
    ]
    static let chinese: [Key: String] = [
        // .runningPort: "运行中 : {port}"
    ]
    '''
    en_d, zh_d = parse_tables(src_commented_single)
    errs = check_tables(en_d, zh_d)
    assert any("English-only keys: runningPort" in e for e in errs), f"Expected missing key error for // comment, got: {errs}"

    # 9. Multi-line commented out entry (/* ... */) is ignored and reported missing
    src_commented_multi = '''
    static let english: [Key: String] = [
        .runningPort: "RUNNING : {port}"
    ]
    static let chinese: [Key: String] = [
        /* .runningPort: "运行中 : {port}" */
    ]
    '''
    en_d, zh_d = parse_tables(src_commented_multi)
    errs = check_tables(en_d, zh_d)
    assert any("English-only keys: runningPort" in e for e in errs), f"Expected missing key error for /* */ comment, got: {errs}"

    # 10. String literal containing comment tokens is preserved
    src_string_with_comment_tokens = '''
    static let english: [Key: String] = [
        .url: "https://example.com//test/*not comment*/ {var}"
    ]
    static let chinese: [Key: String] = [
        .url: "https://example.com//test/*not comment*/ {var}"
    ]
    '''
    parsed = parse_tables(src_string_with_comment_tokens)
    assert parsed is not None
    en_d, zh_d = parsed
    assert en_d.get("url") == "https://example.com//test/*not comment*/ {var}"
    assert zh_d.get("url") == "https://example.com//test/*not comment*/ {var}"
    assert check_tables(en_d, zh_d) == []

    print("PASS localization-check synthetic self-tests")


def main() -> int:
    if "--test" in sys.argv:
        run_self_tests()
        return 0

    path = sys.argv[1] if len(sys.argv) > 1 else "Sources/Localization.swift"
    try:
        with open(path, "r", encoding="utf-8") as f:
            source = f.read()
    except Exception as exc:
        print(f"    could not read {path}: {exc}")
        return 2

    parsed = parse_tables(source)
    if parsed is None:
        print(f"    could not locate both translation tables in {path}")
        return 2

    en_dict, zh_dict = parsed
    errors = check_tables(en_dict, zh_dict)
    if errors:
        for err in errors:
            print(f"    {err}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
