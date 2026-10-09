# Localization Placeholder Validation in `make check` (Issue #2)

## 目的与范围

实现 GitHub Issue #2 的提议：在 `make check` 阶段校验 `Sources/Localization.swift` 中英文翻译字典中的插值占位符一致性。

### 背景与现状

在 `CONTRIBUTING.md` 中曾明确标注：
> `make check` fails if the two key sets differ. It does not check the placeholders, so a `"{port}"` dropped from one side still ships.

目前 `Tests/run-checks.sh` 中的检查 3 仅使用内联 Python 脚本通过正则表达式对比 `english` 与 `chinese` 两个静态字典中的键集合（`Key` 枚举项）。如果在某一语言翻译中漏写了变量占位符（例如英文为 `"RUNNING : {port}"`，中文写成 `"运行中"` 漏掉了 `{port}`），检查仍会通过，导致运行时无法正确插值或丢失关键动态信息。

### 目标与交付物

1. **独立校验脚本** `Tests/localization-check.py`：
   - 提取 `Sources/Localization.swift` 中的 `english` 与 `chinese` 字典。
   - 校验两套语言字典的键集合是否完全一致（若不一致，分别报告英文独有或中文独有键）。
   - 校验字符串字面量中花括号 `{` 与 `}` 的配对平衡（防止出现类似 `{port` 或 `port}` 的笔误）。
   - 提取所有 `{placeholder}` 变量名并比对：对于两边共有的键，校验占位符集合是否完全一致，若不一致明确报告具体键及缺失的占位符名。
   - 支持内置 `--test` 自测套件：在不改动真实代码的前提下，针对合成的变异用例（键缺失、占位符缺失、占位符名称不一致、花括号不平衡、字典格式损坏）验证校验器本身的拦截能力与退出码。
2. **集成到检查套件**：
   - 更新 `Tests/run-checks.sh` 检查 3，调用 `python3 "$SCRIPT_DIR/localization-check.py"`，输出清晰的 `ok` / `fail` 状态。
3. **更新项目文档**：
   - 更新 `CONTRIBUTING.md` 中关于 `make check` 所验证内容的描述，移除“不检查占位符”的旧有说明，明确占位符一致性已纳入检查范围。

## 架构与数据流

```
make check / Tests/run-checks.sh
    └── python3 Tests/localization-check.py Sources/Localization.swift
            ├── 解析 english / chinese 字典表
            ├── 键对齐检查 (Key parity)
            ├── 花括号平衡检查 (Brace balance)
            └── 占位符对齐检查 (Placeholder parity: {identifier})
```

- **解析逻辑**：
  - 通过正则匹配 `static let (?:english|chinese):\s*\[Key:\s*String\]\s*=\s*\[(.*?)\n    \]`。
  - 通过正则 `\.(\w+):\s*"((?:[^"\\]|\\.)*)"` 提取键值对。
- **占位符提取**：
  - 使用 `\{([a-zA-Z0-9_]+)\}` 提取命名占位符集合。
- **退出码约定**：
  - `0`：检查全部通过（或 `--test` 自测全部通过）。
  - `1`：键不一致、占位符不匹配或花括号不平衡。
  - `2`：未能定位或解析语言表。
