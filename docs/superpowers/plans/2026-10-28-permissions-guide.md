# 权限与访问引导 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> 用户已经指定 subagent-driven-development。审阅通过后沿用该方式，不再询问执行方式。

**Goal:** 为 DSH Bar 增加可跳过的首次运行权限说明，并在设置中保留入口，帮助用户配置完全磁盘访问、自动化、照片和媒体权限。

**Architecture:** 新增一个原生 AppKit 权限窗口，将权限项目、设置链接和说明集中放置。启动时仅根据本地版本标记决定是否展示，设置按钮可以随时重开；服务管理与安装流程沿用现有行为。

**Tech Stack:** Swift、AppKit、UserDefaults、现有中英文本地化、Python + Swift fixture；macOS 13+，arm64 与 x86_64。

**Spec:** [权限引导设计](../specs/2026-10-28-permissions-guide-design.md)

状态：用户已于 2026-10-28 审阅通过，按子代理方式实施。关机调查见 [调查记录](../../research/permissions-and-shutdown-investigation.md)；本计划不修改退出流程。

## Global Constraints

- 支持 macOS 13+；不增加依赖，不改启动器、进程模型或签名方式。
- 引导版本为 `1`，持久化键为 `DSH_PermissionsGuideVersion`，未设置时按 `0` 处理。
- 引导为非模态窗口，可直接关闭；首次显示后不因未授权而反复自动弹出。
- 所有新增文案提供中英文；不能把“已打开系统设置”显示成“已授权”。
- 权限说明应区分实际申请程序与目标 App，不保证 DSH 子进程继承菜单栏 App 的全部权限。
- 不读取 TCC 数据库或受保护文件，不调用权限重置、照片读取、音乐读取或自动化请求 API。
- 测试使用隔离的偏好存储与无服务副作用的 fixture；不启动、停止或重启本机 DSH，不安装替换应用，不改变系统权限。

## Review Focus

1. 首启展示前已经开始退出：不弹出新窗口、不覆盖已读版本。由 Task 2 的启动检查 fixture 验证。
2. 打开设置返回失败或系统未定位到子页面：失败时回退隐私主页，并始终给出手动路径。由 Task 1 的链接测试与文案检查验证。
3. 重复重开或关闭后再打开：复用窗口，保持可用；不触发服务方法。由 Task 1 / 2 的 AppKit 与入口测试验证。
4. 英文长文案、紧凑宽度及切换语言：滚动内容可达、按钮无裁切，已读标记不变。由 Task 1 / 2 的布局 fixture 验证。
5. 本地保存了高于当前版本的标记：不再次自动展示，也不把标记降为 1。由 Task 2 的版本测试验证。

## 文件职责

新增 `Sources/PermissionsWindow.swift`，只负责权限窗口、静态说明和链接操作。新增 `Tests/permissions-guide-check.py`，检验窗口与首次展示规则。

修改 [应用代理](../../../Sources/AppDelegate.swift)、[设置存储](../../../Sources/SettingsManager.swift) 和 [主窗口](../../../Sources/DashboardWindow.swift)，接入首启和手动入口；修改 [本地化](../../../Sources/Localization.swift) 和 [构建脚本](../../../build.sh)，纳入新增界面。沿用并扩展 [UI fixture](../../../Tests/dashboard-ui-fixture.py)、[布局检查](../../../Tests/settings-layout-check.py) 和 [检查入口](../../../Tests/run-checks.sh)。在 [README](../../../README.md) 说明授权位置与限制。

## Task 1: 可独立打开的权限窗口

**Files:**

- Create: `Sources/PermissionsWindow.swift`
- Create: `Tests/permissions-guide-check.py`
- Modify: [本地化](../../../Sources/Localization.swift)、[构建脚本](../../../build.sh)、[UI fixture](../../../Tests/dashboard-ui-fixture.py)、[检查入口](../../../Tests/run-checks.sh)

**Interfaces:**

- Consumes: `Localization.shared.addObserver(_ observer: @escaping () -> Void) -> UUID`、`Localization.shared.removeObserver(_ token: UUID)`，以及现有 `L(...)` 文案查找。
- Produces: `enum PermissionSettingsTarget: CaseIterable`，cases 为 `fullDiskAccess`、`automation`、`photos`、`mediaLibrary`；各项包含设置 URL 和本地化手动路径。
- Produces: `final class PermissionsWindowController: NSWindowController`，提供 `static let shared`、`static let guideVersion = 1`、`func showGuide()`。
- Produces: `static func openSettings(for target: PermissionSettingsTarget, openURL: (URL) -> Bool) -> Bool`。按“子页面、隐私主页”的顺序尝试；首个成功后停止，全部失败返回 `false`。按钮传入 `NSWorkspace.shared.open`，测试传入记录调用的闭包。

- [ ] **Step 1: 编写设置链接的失败测试。**

在新增检查中编译实际窗口源码，测试名为 `test_settings_links_and_fallback`。使用记录 URL 的闭包，断言四个项目分别使用设计中的 `Privacy_AllFiles`、`Privacy_Automation`、`Privacy_Photos`、`Privacy_Media`；首个调用成功时只调用一次，首个失败时尝试隐私主页，两次失败时返回 `false`。其中一个 Swift 断言如下，其余目标使用对应 URL：

```swift
var attempted: [String] = []
let result = PermissionsWindowController.openSettings(for: .photos) { url in
    attempted.append(url.absoluteString)
    return attempted.count == 2
}
expect(result && attempted == [
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos",
    "x-apple.systempreferences:com.apple.preference.security"
], "photo settings fallback")
```

运行 `python3 Tests/permissions-guide-check.py`，预期因新增类型尚不存在而失败。

- [ ] **Step 2: 实现权限项目和链接打开方法。**

在新增 Swift 文件中实现 Interfaces 里的枚举和方法。主页使用 `x-apple.systempreferences:com.apple.preference.security`；不从打开结果推导授权状态。窗口尚未完成时，测试可只编译这些实际声明。

- [ ] **Step 3: 实现原生权限窗口和中英文文案。**

实现 `showGuide()` 及四项说明、手动路径、打开设置按钮、完全磁盘访问项的“在访达显示本应用”和“稍后设置”。使用 `Bundle.main.bundleURL` 定位当前 App。窗口初始内容区约 620 × 560，最小约 520 × 460；采用滚动布局。链接全部失败时在窗口内显示错误提示；重复调用复用已有窗口。通过语言观察者更新文案，并按仓库方式释放观察者。

- [ ] **Step 4: 增加窗口行为与布局检查。**

fixture 编译真实权限窗口，替换服务、系统设置打开和应用定位依赖，使用隔离进程内状态。验证中英文的四项内容和手动路径存在、无“全部已授权”状态；620 × 560 与 520 × 460 下内容可滚动到末尾、按钮完整。验证重复打开复用同一窗口、关闭后可重开、语言变化可见。沿用现有 AppKit fixture 的测量与渲染方式，不启动真实 App 入口。

- [ ] **Step 5: 接入构建和统一检查。**

把新增 Swift 文件加入构建脚本的 `SOURCE_FILES`。扩展 UI fixture 的编译源列表，使现有布局测试也能引用权限窗口；把新增检查接入统一入口。运行 `python3 Tests/permissions-guide-check.py` 和 `python3 Tests/localization-check.py`，预期全部 PASS。

- [ ] **Step 6: 提交并进行 Task 1 审查。**

检查差异，只暂存本任务文件和已审阅的设计、计划、调查记录，提交 `feat: add native permissions guide`。按用户指定方式生成该任务完整差异包，交给新的审查子代理；处理影响正确性或需求覆盖的问题后，才开始下一任务。

## Task 2: 首次展示与设置入口

**Files:**

- Modify: [应用代理](../../../Sources/AppDelegate.swift)、[设置存储](../../../Sources/SettingsManager.swift)、[主窗口](../../../Sources/DashboardWindow.swift)、[本地化](../../../Sources/Localization.swift)
- Modify: `Tests/permissions-guide-check.py`、[UI fixture](../../../Tests/dashboard-ui-fixture.py)、[布局检查](../../../Tests/settings-layout-check.py)、[README](../../../README.md)

**Interfaces:**

- Consumes: Task 1 的 `PermissionsWindowController.shared.showGuide()` 和 `PermissionsWindowController.guideVersion`。
- Produces: `SettingsManager.permissionsGuideVersion: Int`，读写 `DSH_PermissionsGuideVersion`。
- Produces: `private func showPermissionsGuideIfNeeded()`，放在 `AppDelegate`。仅当 `terminationReplyPending == false` 且存储版本 `< guideVersion` 时显示，显示后保存当前版本。
- Produces: 主窗口中的“权限与访问 / 打开引导”设置行；其按钮动作只调用 Task 1 的 `showGuide()`。

- [ ] **Step 1: 编写首次显示规则的失败测试。**

按仓库 fixture 方式运行实际检查方法，测试名为 `test_first_display_version_and_termination`。替换窗口展示与设置依赖；偏好属性使用唯一的 `UserDefaults` suite。测试使用以下输入与预期：

```swift
let cases: [(stored: Int, quitting: Bool, shows: Int, saved: Int)] = [
    (0, false, 1, 1),
    (1, false, 0, 1),
    (2, false, 0, 2),
    (0, true, 0, 0)
]
```

每个用例断言展示次数与最终存储版本；首个用例再检查一次，展示总次数仍为 1。运行 `python3 Tests/permissions-guide-check.py`，预期因属性或方法缺失失败。

- [ ] **Step 2: 实现持久化属性与首次显示检查。**

在设置存储中实现 `permissionsGuideVersion`。在应用代理中实现 Interfaces 指定的方法；在现有启动初始化尾部异步调用一次。检查和写入在主线程完成。保留现有监控、安装提示及服务行为。

- [ ] **Step 3: 实现设置入口并扩展 fixture。**

在主窗口的设置区添加一行，通过按钮调用 `showGuide()`。使用现有设置分组与布局方式；补齐中英文标题、说明与按钮。更新 fixture 的惰性依赖，避免真实服务、更新器或权限操作。

- [ ] **Step 4: 验证手动入口与已有布局。**

调用真实按钮动作并断言可以重新打开引导，不修改已读版本，服务启动、停止、重启和安装调用次数均为 0。切换语言后重开窗口，确认文案更新、版本不变。运行 `python3 Tests/permissions-guide-check.py` 和 `python3 Tests/settings-layout-check.py`，预期全部 PASS，并检查紧凑宽度下原有设置仍完整。

- [ ] **Step 5: 更新使用说明。**

在 README 加入首启可跳过、设置中可重开和完全磁盘访问的操作说明。明确自动化按申请程序和目标 App 分别授权，照片、媒体 API 另有授权；系统显示的申请程序可能是 DSH Bar、终端或实际运行程序。说明打开设置不等于已获授权，不承诺权限继承或消除所有系统提示。

- [ ] **Step 6: 运行仓库回归与双架构构建。**

运行 `make check`，预期所有检查通过；运行 `./build.sh`，预期 arm64 与 x86_64 均编译完成并生成通用 App。执行前核对构建脚本删除的目标均为当前仓库的预期构建产物。仅生成安装包，不运行 `make install` 或重启本机应用。

- [ ] **Step 7: 提交并完成任务及整体验收。**

检查差异，只暂存本任务文件，提交 `feat: show permissions guide on first launch and in settings`。交给新的子代理审查 Task 2；通过后再由全新审查者检查整组提交。按用户指定流程记录任务、测试与审查状态。

## 完成后的交付

给出改动与验证结果、生成的 App 位置，以及未自动验证的项目：不同 macOS 版本的系统设置定位、真实权限请求中的程序名称和实际关机耗时。权限功能完成与关机调查结论分别报告；没有实测证据时，不宣称关机问题已修复。

## 自审记录

已逐项核对设计覆盖、两个任务的接口名称、版本规则、四个设置入口、关闭与语言行为、测试隔离及构建接入。设计经独立 macOS 工程子代理检查，结果为“nothing important left”。本计划保留用户指定的子代理执行方式，设计与计划已获用户批准，现按任务实施。
