# DSH 版本 / npm Tag 选择器 — 设计

**日期**：2026-10-01
**状态**：设计已批准，待实现计划

## 目标

在偏好设置面板里，让用户选择 `@deepseek-ai/dsh` 的 npm 安装通道（tag），并一键切换本机安装的 dsh 版本——无需打开终端。

## 背景

面板已有一行 "DSH Command Line"，通过 `which dsh` 定位路径、读 `dsh --version` 显示版本，并提供 Recheck / Install 两个动作。缺的是**版本切换**：目前要换 dsh 版本只能回终端敲 `npm install -g @deepseek-ai/dsh@<tag>`。

npm 上该包有三个 dist-tag（实测值，随时会变）：

| tag | 指向（2026-10-01） |
| :--- | :--- |
| `latest` | `0.2.0-rc.2` |
| `next` | `0.2.0-rc.2` |
| `alpha` | `0.1.7-alpha.2` |

注意 `latest` 与 `next` 目前指向同一版本——这正是"只按 tag 选择"比"只比版本号"更有意义的地方：用户想说的是"我要跟 latest 还是跟 next"，而不是"我要 0.2.0-rc.2"。

## 决策

以下五项由用户拍板，不再重新讨论：

| 决策 | 选择 | 理由 |
| :--- | :--- | :--- |
| 可选范围 | 只列 npm tag + 显示当前已装版本 | 完整 versions 数组有几十个 rc/alpha 条目，容易误装旧版本；registry 文档含全部依赖字段，本地解析负担大 |
| 服务运行中 | 允许安装，服务保持运行，提示"重启后生效" | `npm install -g` 替换磁盘二进制，已运行进程继续用内存里的旧代码，两者共存不互相破坏 |
| 安装失败 | 原样显示错误，不回滚、不杀进程 | npm 失败时通常不会删掉旧版本；主动回滚多一次网络操作且自身也可能失败 |
| 偏好记忆 | 记住选中的 tag 作为偏好，只读不自动执行 | 下拉框需要记住用户选过什么；但绝不自动重装 |
| 安装确认 | 弹确认框，列出完整的 `npm install -g` 命令 | 全局 npm 安装影响的不只本应用，用户应看见将执行的确切命令 |

## 明确不做的事

- **不自动重启服务。** 换版本不触发重启，也不接入 `restartPreflight`。何时重启由用户决定。
- **不拉取完整 `versions` 数组。** 只用 dist-tags 端点。
- **不提供 semver 输入框。** 用户不能手填版本号。
- **不做回滚安装。** 安装失败就是失败。
- **不修改 `ServiceManager.installCommand` 的值。** 新增带 tag 的变体；`DshInstallAssistant` 的两条现有路径继续用原值 `npm install -g @deepseek-ai/dsh`。

## 数据流

### 探测

```
面板打开 / 用户点 Recheck
  → GET https://registry.npmjs.org/-/package/@deepseek-ai/dsh/dist-tags
  → {"alpha":"0.1.7-alpha.2","latest":"0.2.0-rc.2","next":"0.2.0-rc.2"}
  → 与本机 `dsh --version` 的输出比对
  → 填充下拉框 + 决定是否显示"重启后生效"
```

选这个端点而不是 registry 文档端点：响应约 90 字节，只含三个 tag。文档端点约 200KB，含每个版本的完整依赖树，本地只需 dist-tags 却要解析全部——不划算。

**不走 `npm view`。** 本机 npm cache 是 root-owned，`npm view` 会 `EPERM` 失败。HTTP 是唯一可靠路径。

### 安装

```
用户点 Install
  → 确认框列出 `npm install -g @deepseek-ai/dsh@<tag>`
  → 后台跑 npm，stdout/stderr 收进结果视图
  → 完成后重新探测版本，更新"待重启"提示
```

## 组件

| 文件 | 职责 |
| :--- | :--- |
| `Sources/DshVersionController.swift`（新增） | 唯一懂 tag 语义的地方：拉 dist-tags、比对本地版本、组装安装参数、执行并解析结果。不碰 UI。 |
| `Sources/SettingsManager.swift` | 新增 `preferredDshTag: String?`，UserDefaults key `DSH_DshTag`。 |
| `Sources/DashboardWindow.swift` | 偏好区 DSH 行下新增一行；调整固定高度常量。 |
| `Sources/Localization.swift` | 新增 key，中英两表同步。 |
| `CONTRIBUTING.md` | 把 `DSH_DshTag` 加入不可变键列表。 |
| `Tests/run-checks.sh` | 新增一条 grep 断言（见「测试」）。 |

### `DshVersionController`

对外只暴露两个方法，两者都在后台队列执行、completion 回主线程——与 `ServiceManager.detectDshInstallation`（`Sources/ServiceManager.swift:244`）现有的分派方式一致：

```swift
func fetchTags(completion: @escaping (Result<[String: String], Error>) -> Void)
func install(tag: String, completion: @escaping (Result<String, Error>) -> Void)
```

`fetchTags` 返回 tag → 版本号的字典。`install` 的 `Result` 成功值是 npm 的 stdout，失败值是包含 exit code 与 stderr 的错误。

**并发保护**：一次只允许一个 npm 进程。安装进行中重复点击 Install 被忽略而非排队——两个 `npm install -g` 同时写同一个全局前缀会互相破坏。

### `preferredDshTag` 语义

`String?`，`nil` 表示用户从未选过。存的是 **tag 名**（`"next"`），不是版本号——tag 会移动，存版本号下次打开就变成一个无效的选项。

只读不执行：它只决定下拉框的初始选中项。探测和安装都从 registry / 用户点击出发，不看这个偏好。

## UI

在偏好区 "DSH Command Line" 行**下面**新增一行，结构复用现有 `makeTextStack(title:description:)` + 右侧控件的模式：

```
┌──────────────────────────────────────────────────────────┐
│ DSH Command Line                                         │
│ /opt/homebrew/bin/dsh • 0.2.0-rc.2            [Recheck]   │
├──────────────────────────────────────────────────────────┤
│ Install channel                        ┌───────────────┐  │
│ Picks the npm tag to install.          │ latest ▾      │ [Install] │
│                                        └───────────────┘         │
└──────────────────────────────────────────────────────────┘
```

下拉框与 Install 按钮**并排**，与 `portRow`（输入框 + Reset）、`shortcutRow`（按钮 + Reset）一致。最初的设计草稿把 Install 画在下拉框**下方**；实测证明那样放会让按钮落到卡片底边之外 4.5pt（`tagRow` 是无固定高度的撑余行，下拉框 `centerY` 居中后按钮整体偏下），所以改为并排。

下拉框宽度取 **210pt**，而不是沿用 `languageRow` 的 148pt —— 148pt 是给 `English`/`中文` 这类短标题的。实测小号 `NSPopUpButton` 的 `fittingSize.width`：`latest` 74、`alpha` 73、`0.1.7-alpha.2` 117、而 `latest (0.2.0-rc.2, installed)` 需要 **204**。中文标题 `latest（0.2.0-rc.2，已安装）` 200，比英文窄。

- **下拉框**：只列 registry 返回的 tag。当前实际安装的版本所对应的 tag 加 `(installed)` 后缀。
- **Install 按钮**：仅当「选中 tag ≠ 当前已装 tag」时可用。选到已装的那个就只是重装同一个东西，不该诱导点击。
- **服务运行中**：不禁用 Install。装完在 DSH 行显示橙色"重启后生效"。
- **加载中**：下拉框禁用并显示 `Checking…`。
- **探测失败**：下拉框退化为只显示已装版本，Install 禁用，给出可读原因（离线 / 超时 / 404）。

### 面板高度

偏好区是固定高度栈，放在 `preferencesScroll` 里。加一行意味着改两个常量：

| 常量 | 位置 | 值 | 性质 |
| :--- | :--- | :--- | :--- |
| `cardIsNaturalHeight` | `Sources/DashboardWindow.swift:213` | 432 → 486 | **必需**：固定部分变成 382 + `dshRow` 54 + `separator7` 1 = 437，保持 432 会欠 5pt 导致约束冲突 |
| `naturalContentHeight` | `Sources/DashboardWindow.swift:30` | 538 → 592 | **仅观感**：让窗口最小高度时多露出 54pt 的行（可视区 180 → 234）；不改也不会裁掉任何内容，卡片本来就在滚动视图里 |

实测（用 layout harness 驱动真实 `DashboardWindowController`）：

```
scroll slice = min(windowContentHeight - 358, cardHeight)
card height  = 自己的常量，与窗口高度无关
```

卡片在任何 ≥538 的窗口尺寸下都是 432，变化的是滚动可视区。`538 = 358pt 外框 + 滚动视图自身的 180pt 下限`（`Sources/DashboardWindow.swift:232`），**不是**卡片高度 —— `Sources/DashboardWindow.swift:26-30` 的注释本来就这么说。

`dshRow` 补上显式 `heightAnchor.constraint(equalToConstant: 54)`，新的 tag 行接手撑余行的角色（实测分到 51pt）且**不加固定高度**。新增的分隔线编号 `separator7`，插在 `dshRow` 与新行之间。

## 安全与失败约束

- **绝不因为安装失败而终止任何进程。** 失败就是失败，显示错误。
- **绝不自动重启服务。** 不接入 preflight 逻辑。
- npm 子进程继承 `ServiceManager.commandEnvironment()`（`Sources/ServiceManager.swift:320`），与 `findNpmBinary` 用同一套 PATH 解析规则。
- 网络请求设超时，避免面板卡在加载态。
- 确认框里显示的是**将要执行的完整命令**，由 tag 参数拼出，用户能看见 `@deepseek-ai/dsh@next` 这类实际字符串。

## 测试

`make check` 现有检查已覆盖本次改动触及的两处：

- 翻译 key 对齐（`Tests/run-checks.sh:42-71`）——新增 key 必须中英同步，否则失败。
- 面板高度断言（`Tests/run-checks.sh:102-104`）——它断言 `naturalContentHeight = 538`，我改成 592 时**这条检查会失败**，提醒我同步更新脚本里的期望值。这是故意让它失败的：它证明改动没被静默漏掉。

新增一条 grep 断言：安装命令必须来自 `DshVersionController` 的拼装逻辑，不能是硬编码字符串。

```bash
# 7. The npm install command carries a tag and must be built in one place.
if grep -q "installCommand" Sources/DshVersionController.swift \
   && ! grep -qE 'npm install -g @deepseek-ai/dsh@[a-z]' Sources/DshVersionController.swift; then
    fail "DshVersionController must build the tagged npm install command, not hardcode it"
else
    pass "tagged npm install command is assembled in DshVersionController"
fi
```

项目没有单测 target（`CONTRIBUTING.md` 明确说明），所以这是捕获"退回硬编码"回归的唯一低成本手段。

## 风险

| 风险 | 缓解 |
| :--- | :--- |
| npm 全局安装因权限失败（EACCES） | 错误原样显示；用户可自行用 `sudo` 处理。不做提权。 |
| 用户选的 tag 指向一个不兼容的 dsh | `dsh web` 启动失败会走现有的 `.error` 相位与 `couldNotStartService` 提示，面板已经能表达这件事。 |
| 探测请求在离线时静默失败 | 退化为只显示已装版本 + 明确原因，而不是空白下拉框。 |
| `latest` 与 `next` 指向同一版本 | Install 按钮按 tag 比较，两者相同时禁用，避免诱导无意义重装。 |
