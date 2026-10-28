# v1.0.5 权限引导补充与发布 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补全本地网络引导，将权限引导作为 v1.0.5 合并发布。

**Architecture:** 在现有枚举和本地化中增加第五项，复用滚动窗口和设置链接回退。发布使用已有 main CI 和 tag Release 工作流。

**Tech Stack:** Swift/AppKit、Python fixture、GitHub Actions、Sparkle；macOS 13+，arm64/x86_64。

**Spec:** [发布补充设计](../specs/2026-10-28-permissions-release-design.md)

状态：已获用户本轮合并、推送、tag 和 Release 授权。原两个实现任务与整组审查已完成，不重新派发。

## Global Constraints

- 追加 `localNetwork` 和 `Privacy_LocalNetwork`；保留原四项、隐私主页回退与手动路径。
- 保持 `guideVersion = 1`、`DSH_PermissionsGuideVersion`、macOS 13+、窗口尺寸、原签名与更新源不变。
- 中英文提及 macOS 15 起的本地网络隐私控制；不保证申请程序身份或权限继承。
- 不增加依赖、网络或权限探测、TCC 读取、usage-description 键或服务操作；测试使用已有隔离 fixture。
- 发布版本 `1.0.5`，tag `v1.0.5`；不声称关机问题修复。

## Review Focus

1. 第五项的直接成功、主页回退、完全失败：现有链接实际源码测试扩展到五项。
2. 旧 macOS 没有该页面：中英文保留版本条件和手动查找说明。
3. 增加内容后窗口最小尺寸：已有布局测试验证第五项、末尾及按钮可达。
4. 首启和重开：现有版本规则与无服务副作用断言继续通过。
5. 发布版本与资产：默认版本、Markdown/HTML 说明、tag、正式 ZIP 和 appcast 一致。

## Task 1: 第五项权限与发布元数据

**Files:** 修改 `Sources/PermissionsWindow.swift`、`Sources/Localization.swift`、`Tests/permissions-guide-check.py`、`README.md`、`Info.plist`；创建 `Packaging/ReleaseNotes/1.0.5.md` 与 `.html`。本计划与补充设计一起提交。除测试新项要求外不重构 fixture，不修改其他服务代码。

**Interfaces:** 消费 `PermissionSettingsTarget: CaseIterable` 和 `PermissionsWindowController.openSettings(for:openURL:)`；产出追加 case `localNetwork`，不改既有签名。

- [ ] **Step 1:** 扩展 `test_settings_links_and_fallback` 和窗口断言到五项（`.localNetwork`, `Privacy_LocalNetwork`）；运行 `python3 Tests/permissions-guide-check.py`，预期缺少第五项导致失败。
- [ ] **Step 2:** 追加枚举映射与中英文标题、说明；手动路径复用现有实现。默认版本的两个值改为 `1.0.5`；README 补充本地网络操作，Markdown/HTML 说明描述完整本次发布。
- [ ] **Step 3:** 运行权限和本地化检查，预期 PASS；完整 `make check` 与正式双架构构建交由合并后对应提交的现有 CI，在临时 runner 执行且通过后才可打 tag。完整套件的签名测试会临时更改用户钥匙串搜索列表，本机不执行该步骤。记录真实输出与已有诊断，避免屏蔽或绕过沙箱。
- [ ] **Step 4:** 自审并提交，只包含本任务文件，写详细实施报告并返回提交和检查结果。由新审查代理检查该补充及整组集成，无阻塞后进入发布。

## 发布执行

- [ ] 主工作区原有本轮文档与已提交版本比较后保留副本，避免覆盖；快进合并 feature 到 main，推送 main。
- [ ] 等待对应提交的 CI 成功；创建 annotated `v1.0.5` 并推送，不覆盖已有 tag。
- [ ] 收集 Release 工作流结果；下载 ZIP、SHA256、appcast 到仓库内专用验证目录。
- [ ] 核对版本、macOS 下限、双架构、SHA256、嵌套代码签名、稳定签名证书、Ed25519 更新签名和 latest feed；记录证据并给出 Release/下载链接。

自审：补充设计各要求均有上述实现或发布检查；不重复原始任务，不增加无关功能。实际设置路由、系统授权及关机耗时仍由用户在本机验证。
