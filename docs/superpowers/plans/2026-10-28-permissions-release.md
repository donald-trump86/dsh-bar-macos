# v1.0.5 权限引导补充与发布 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补全本地网络引导，将权限引导作为 v1.0.5 合并发布。

**Architecture:** 在现有枚举和本地化中增加第五项，复用滚动窗口和设置链接回退。发布使用已有 main CI 和 tag Release 工作流。

**Tech Stack:** Swift/AppKit、Python fixture、GitHub Actions、Sparkle；macOS 13+，arm64/x86_64。

**Spec:** [发布补充设计](../specs/2026-10-28-permissions-release-design.md)

状态：已完成。main 已合并推送，`v1.0.5` 已发布为最新稳定版；对应 CI、Release 工作流及正式资产核验全部通过。

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

- [x] **Step 1:** 扩展 `test_settings_links_and_fallback` 和窗口断言到五项（`.localNetwork`, `Privacy_LocalNetwork`）；运行 `python3 Tests/permissions-guide-check.py`，预期缺少第五项导致失败。
- [x] **Step 2:** 追加枚举映射与中英文标题、说明；手动路径复用现有实现。默认版本的两个值改为 `1.0.5`；README 补充本地网络操作，Markdown/HTML 说明描述完整本次发布。
- [x] **Step 3:** 运行权限和本地化检查，预期 PASS；完整 `make check` 与正式双架构构建交由合并后对应提交的现有 CI，在临时 runner 执行且通过后才可打 tag。完整套件的签名测试会临时更改用户钥匙串搜索列表，本机不执行该步骤。记录真实输出与已有诊断，避免屏蔽或绕过沙箱。
- [x] **Step 4:** 自审并提交，只包含本任务文件，写详细实施报告并返回提交和检查结果。由新审查代理检查该补充及整组集成，无阻塞后进入发布。

## 发布执行

- [x] 主工作区原有本轮文档与已提交版本比较后保留副本，避免覆盖；快进合并 feature 到 main，推送 main。
- [x] 等待对应提交的 CI 成功；创建 annotated `v1.0.5` 并推送，不覆盖已有 tag。
- [x] 收集 Release 工作流结果；下载 ZIP、SHA256、appcast 到仓库内专用验证目录。
- [x] 核对版本、macOS 下限、双架构、SHA256、嵌套代码签名、稳定签名证书、Ed25519 更新签名和 latest feed；记录证据并给出 Release/下载链接。

自审：补充设计各要求均有上述实现或发布检查；不重复原始任务，不增加无关功能。实际设置路由、系统授权及关机耗时仍由用户在本机验证。

## 发布核验（2026-10-28）

- 发布代码：`7bf0520427fcc9c86f471fda758a1351a895e97e`，已快进合入并推送 main。注解 tag `v1.0.5` 的对象为 `ae118c56c2d0f5bffb7704163fb409f1fa439e9a`，解引用指向同一发布代码，未覆盖已有 tag。
- [最终 CI 40652809383](https://github.com/donald-trump86/dsh-bar-macos/actions/runs/40652809383)：成功；同一提交的双架构构建和完整一致性检查通过。
- [Release 工作流 40653264459](https://github.com/donald-trump86/dsh-bar-macos/actions/runs/40653264459)：成功；正式构建、签名、封包、EdDSA appcast 和发布均完成。使用既有自签名证书，公证步骤按配置跳过。
- [v1.0.5 发布页](https://github.com/donald-trump86/dsh-bar-macos/releases/tag/v1.0.5)：公开稳定版；GitHub latest 元数据指向该版本。

### 正式资产

| 核验项 | 结果 |
| --- | --- |
| [通用 ZIP](https://github.com/donald-trump86/dsh-bar-macos/releases/download/v1.0.5/DSH-Bar-1.0.5-universal.zip) | 3,773,820 字节；ZIP 完整性通过 |
| SHA256 | `074b251670a50dd75f2c5582d9770fc63ccf3a7773be68feac5ef2c6dff252d3`；与发布校验文件及 GitHub asset digest 一致 |
| 版本与架构 | 版本/构建号均为 `1.0.5`；最低 macOS `13.0`；`arm64`、`x86_64` |
| 代码签名 | `codesign --verify --deep --strict` 通过，含 Sparkle 嵌套组件；Authority 为 `DSH Bar Self-Signing` |
| 证书连续性 | 叶证书 SHA1 `34959d783d07b4e31befa94f5f5c33f8825ba32e`，与 v1.0.4 正式包相同 |
| Sparkle 更新签名 | 使用包内既有公钥对下载 ZIP 执行 Ed25519 验签，通过；版本、长度及下载 URL 与 appcast 一致 |
| [线上更新源](https://github.com/donald-trump86/dsh-bar-macos/releases/latest/download/appcast.xml) | 下载内容与 v1.0.5 发布的 appcast 逐字节一致；包内公钥及更新 URL 保持原值 |

正式资产与元数据保存在仓库内 [核验目录](../../../build/release-verification/1.0.5/)。仅解包和验签，未安装或启动应用，也未操作宿主 DSH 或系统权限。

### CI 中发现并处理的两处差异

macOS 14 的传统滚动条占用 15 点，旧宽度约束使文档宽 620、可视区宽 605。[权限窗口](../../../Sources/PermissionsWindow.swift#L43) 现于 `NSScrollView.tile()` 完成后按实际可视区宽度同步文档，实际 runner 已确认两者均为 605；不写死滚动条尺寸，也不更改系统偏好。

同一平台会把按钮标题作为原生文本框后代暴露。[权限引导检查](../../../Tests/permissions-guide-check.py#L224) 现按公开的 `NSButton` 祖先关系区分说明文字与按钮文字，仍严格比较说明集合，并独立验证七个按钮的标题多重集及可见性。回归用例确认按钮内部文本被分类，而未知说明文字仍会被检测。最终真实 CI 的中英文、初始/最小尺寸四组布局、八次滚动条切换及原有首启、重开、操作和观察者生命周期检查全部通过。

### 本轮判断与保留项

1. 沿用版本序列选择下一个未使用补丁号 `1.0.5`。如需不同编号，后续发布必须使用新的版本号和 tag；本 tag 保持不变。
2. 保持引导版本为 `1`，因为这是首次公开发布该引导。已运行本地预览且保存过版本 1 的用户，需要从设置手动重开。
3. 完整检查放在一次性 CI runner 执行，避免本机签名测试更改用户钥匙串搜索列表。代价是跨系统差异在 main 推送后才暴露；两处差异已在打 tag 前修正，并由最终对应提交的完整 CI 验证。

原整组审查的四个非阻塞轻微项保留：关闭动作断言的敏感性、既有 sandbox 诊断、预期热键故障注入 stderr 的标注，以及服务管理器的未变变量警告。CI 也保留了既有签名测试的旧 Bash `mapfile` 警告；本轮未扩展到签名脚本维护。

真实系统设置页面路由、窗口焦点、Finder 交互、权限申请程序身份及实际授权/撤销仍需本机验证。本版本未宣称修复关机延迟，也未实测关机耗时。
