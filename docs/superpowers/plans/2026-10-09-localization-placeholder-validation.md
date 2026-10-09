# Localization Placeholder Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `make check` to validate that interpolation placeholders (`{name}`) match between English and Chinese translations, preventing translation placeholders from being accidentally dropped.

**Architecture:** A standalone Python validator `Tests/localization-check.py` parses `Sources/Localization.swift`, compares keys and placeholder sets, checks brace balance, and provides a built-in `--test` self-test suite. `Tests/run-checks.sh` check 3 delegates to this script, and `CONTRIBUTING.md` is updated to reflect that placeholders are now strictly validated.

**Tech Stack:** Python 3 (standard library only: `re`, `sys`), Bash.

**Spec:** `docs/superpowers/specs/2026-10-09-localization-placeholder-validation-design.md`

## Global Constraints

- Use only the Python 3 standard library (`re`, `sys`). No external dependencies.
- Zero changes to Swift runtime code or `Sources/Localization.swift` dictionary content (all 184 keys currently have matching placeholders).
- Fast execution: validator must complete in under 50ms so `make check` remains fast.
- Exit code conventions: 0 for all checks passed, 1 for key/placeholder/brace mismatches, 2 for syntax/table parse errors.
- Documentation in `CONTRIBUTING.md` must be updated to state that `make check` now catches missing placeholders.

## Review Focus

1. **Multiple placeholders in one string** (e.g. `{days}` and `{hours}`): check detects when only one placeholder is omitted or mismatched. — pinned in Task 1.
2. **Reversed placeholder omissions**: check detects placeholders present in Chinese but missing in English as well as the opposite. — pinned in Task 1.
3. **Strings with no placeholders**: keys without placeholders in both languages must pass without false positives. — pinned in Task 1.
4. **Unbalanced or broken braces**: a typo like `{port` or `port}` is caught as unbalanced braces rather than silently passing as non-placeholder text. — pinned in Task 1.
5. **Missing table delimiters**: if `Sources/Localization.swift` refactors table declaration format, check fails loudly with exit code 2 ("could not locate both translation tables") instead of passing vacuously. — pinned in Task 1.

---

### Task 1: Create standalone `Tests/localization-check.py` with `--test` suite

**Files:**
- Create: `Tests/localization-check.py`

**Interfaces:**
- Produces: `Tests/localization-check.py` CLI
  - `python3 Tests/localization-check.py [path/to/Localization.swift]`: returns 0 on pass, 1 on mismatch/unbalanced braces, 2 on parse error.
  - `python3 Tests/localization-check.py --test`: runs synthetic test suite covering all Review Focus conditions.

- [ ] **Step 1: Write test runner verification command**

Run: `python3 Tests/localization-check.py --test`
Expected: FAIL with `python3: can't open file 'Tests/localization-check.py'`

- [ ] **Step 2: Implement `Tests/localization-check.py`**

Create `Tests/localization-check.py`:
- Function `parse_tables(source: str) -> tuple[dict[str, str], dict[str, str]] | None`:
  Finds `static let (?:english|chinese):\s*\[Key:\s*String\]\s*=\s*\[(.*?)\n    \]` (or named groups). If fewer than 2 tables found, returns `None`. Parses entries with `\.(\w+):\s*"((?:[^"\\]|\\.)*)"`. Returns `(en_dict, zh_dict)`.
- Function `check_tables(en_dict: dict[str, str], zh_dict: dict[str, str]) -> list[str]`:
  - Compares keys: detects `en_only` and `zh_only` keys.
  - Checks brace balance: detects `count('{') != count('}')` in either table.
  - Compares placeholders: for keys in both tables, extracts `set(re.findall(r'\{([a-zA-Z0-9_]+)\}', text))`, finds differences, reports missing in Chinese or missing in English.
  - Returns list of error message strings (empty if all pass).
- Function `run_self_tests()`:
  - Tests valid tables pass.
  - Tests missing key in Chinese / English.
  - Tests missing placeholder in Chinese (e.g. `{port}` missing).
  - Tests missing placeholder in English.
  - Tests multi-placeholder partial mismatch (`{days}` present, `{hours}` missing).
  - Tests unbalanced brace (e.g. `{port`).
  - Tests parse error returns exit code 2.
- CLI handler:
  - If `--test` in `sys.argv`: runs `run_self_tests()`, prints results, exits 0 on success.
  - Otherwise, reads target file (default `Sources/Localization.swift`), runs `parse_tables`, runs `check_tables`, prints errors with indent `    ` matching `run-checks.sh` style, exits with appropriate exit code (0, 1, or 2).

- [ ] **Step 3: Run `--test` to verify self-tests pass**

Run: `python3 Tests/localization-check.py --test`
Expected: PASS with all synthetic test assertions passing.

- [ ] **Step 4: Run validator against real `Sources/Localization.swift`**

Run: `python3 Tests/localization-check.py Sources/Localization.swift`
Expected: Exit code 0, no errors printed.

- [ ] **Step 5: Commit**

```bash
git add Tests/localization-check.py
git commit -m "test: add localization key and placeholder consistency checker"
```

---

### Task 2: Wire `localization-check.py` into `Tests/run-checks.sh`

**Files:**
- Modify: `Tests/run-checks.sh:40-71`

**Interfaces:**
- Consumes: `python3 "$SCRIPT_DIR/localization-check.py"` from Task 1.
- Produces: Updated `make check` step 3.

- [ ] **Step 1: Update check 3 in `Tests/run-checks.sh`**

Replace inline python block in `Tests/run-checks.sh` with call to `python3 "$SCRIPT_DIR/localization-check.py Sources/Localization.swift"`:
```bash
# 3. Translation keys and placeholders must align across languages.
#    A missing key falls back to English silently; a dropped placeholder
#    leaves un-interpolated template variables or drops values at runtime.
if command -v python3 >/dev/null 2>&1; then
    if python3 "$SCRIPT_DIR/localization-check.py"; then
        pass "translation keys and placeholders align across both languages"
    else
        fail "translation keys or placeholders are out of sync (see above)"
    fi
else
    echo "SKIP  translation key and placeholder alignment (python3 not found)"
fi
```

- [ ] **Step 2: Run `make check` to verify check 3 passes**

Run: `make check`
Expected: PASS, with line `ok    translation keys and placeholders align across both languages`.

- [ ] **Step 3: Commit**

```bash
git add Tests/run-checks.sh
git commit -m "ci: integrate localization placeholder check into make check"
```

---

### Task 3: Update `CONTRIBUTING.md` documentation

**Files:**
- Modify: `CONTRIBUTING.md:26-31`, `CONTRIBUTING.md:51-53`

**Interfaces:**
- Updates contributor documentation to state that placeholders are validated.

- [ ] **Step 1: Update `CONTRIBUTING.md`**

In table:
Update row:
`| Translation key & placeholder alignment | A Key or interpolation placeholder added to one language table but not the other. |`

In Section "Changing user-facing text":
Change:
```markdown
`make check` fails if the two key sets differ. It does not check the
placeholders, so a `"{port}"` dropped from one side still ships.
```
To:
```markdown
`make check` fails if the two key sets differ or if interpolation
placeholders (such as `"{port}"`) do not match across translations.
```

- [ ] **Step 2: Verify `make check` still passes**

Run: `make check`
Expected: All checks pass, including check 2 (README paths).

- [ ] **Step 3: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "docs: document localization placeholder check in CONTRIBUTING.md"
```
