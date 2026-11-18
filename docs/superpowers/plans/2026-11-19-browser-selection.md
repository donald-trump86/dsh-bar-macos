# v1.0.7 浏览器选择 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 偏好设置新增“打开 Web 使用的浏览器”，选项为系统默认浏览器和本机检测到的其他浏览器；版本升到 1.0.7 并按既有流程推送、打 tag、发布 Release。

**Architecture:** 新增 `Sources/BrowserLauncher.swift` 承担探测与启动路由；`ServiceManager.openBrowser()` 把选好的 URL 交给它，其余身份/凭据判断一行不改；偏好设置 General 组新增一行弹出菜单，读写 `SettingsManager.preferredBrowserBundleIdentifier`。

**Tech Stack:** Swift 6 / AppKit（最低 macOS 13.0），已有 `Tests/*-check.py` + `swiftc` 夹具体系，不引入任何依赖。

**Spec:** 无独立设计文档。需求原文（m00002）：`/subagent-driven-development 添加选择默认打开浏览器的功能，提供选项包括：系统默认浏览器，以及检测到的本机其他浏览器，版本号加0.0.1，完成后推送，tag，release`。

## 需求来源与裁定

需求本身只有一句话，下面几条是本计划对它的解释，已写入 SDD ledger：

- **“检测到的本机其他浏览器”用什么筛。** 只收同时声明 `http`、`https` 且声明能处理 HTML 的应用，并要求它没有登记终端类客户端协议。本机实测：`LSApplicationCategoryType` 不可靠（Chrome/Brave/Orion 为空，Safari/Firefox/Zen/iTerm 都是 productivity）；iTerm 也声明 `http`/`https`/`public.html`，只能靠协议组排除。
- **所选浏览器被卸载后怎么办。** 静默回退系统默认浏览器，不弹窗、不改偏好值（重装后自动恢复）。
- **探测时机。** 面板构建时与 `showWindow` 各探测一次；不做常驻监视器。面板打开期间新装的浏览器下次打开即出现。
- **发布前不额外确认。** 用户在需求里直接授权“完成后推送，tag，release”；发布说明正文随本计划的 Release Notes 任务一起产出，并在最终汇报里原文列出。

## Global Constraints

- 不改 `dsh web` 启动参数，不新增网络请求，不调用任何修改系统默认浏览器的 API（`LSSetDefaultHandlerForURLScheme` 之类一律不用）。
- 新文件必须加入 `build.sh` 的 `SOURCE_FILES`，并在 `README.md` 项目结构树里有一行中文说明。
- 所有新用户可见文案同时写入 `english` 与 `chinese` 表，占位符名一致（`Tests/localization-check.py` 双向校验）。
- 检测规则写死如下：候选来自 `NSWorkspace.shared.urlsForApplications(toOpen: BrowserLauncher.sampleURL)`，`sampleURL = URL(string: "https://example.com")!`；必须 (a) `CFBundleURLTypes` 同时声明 `http` 与 `https`；(b) 任一协议组都不含客户端协议 deny list：`ssh sftp telnet rlogin ftp tftp mailto news nntp gopher wais whois gemini titan irc ircs afp smb nfs x-man-page`；(c) `CFBundleDocumentTypes` 任一项的 `LSItemContentTypes` 含 `public.html`，或 `CFBundleTypeExtensions` 含 `html htm shtml xhtml xht` 之一；(d) 能读到 `CFBundleIdentifier`。显示名取 `.app` 文件名去掉扩展名；按显示名 `localizedCaseInsensitiveCompare` 排序，按 bundle identifier 去重。
- 偏好键 `DSH_PreferredBrowser`，值为 bundle identifier；读回 `nil` 表示系统默认浏览器。
- 启动路由：首选值能解析到应用且该应用仍满足 (a)(b)(c) 时用 `NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())`；否则（含首选值为 `nil`）用 `NSWorkspace.shared.open(url)`。
- 版本：`Info.plist` 的 `CFBundleShortVersionString` 与 `CFBundleVersion` 都改为 `1.0.7`；发布说明 `Packaging/ReleaseNotes/1.0.7.md` 与 `1.0.7.html` 用英文，结构对齐 1.0.6。
- 测试不得真的打开浏览器、不得读写系统默认浏览器设置：只用合成 `.app` 目录 + stub `NSWorkspace`。
- `PYTHONDONTWRITEBYTECODE=1 make check` 必须全绿后才有下一次提交。提交信息沿用 `feat:` / `test:` / `chore:` / `docs:`。

## Review Focus

1. **所选浏览器被删除。** 用户选了某浏览器后再把它卸载，下次点 Open Web 必须打开系统默认浏览器，而不是无反应、报错或打开任意别的应用。（Task 1 的测试固定这条）
2. **终端类误报。** iTerm 同时声明 `http`/`https`/`public.html`，它不能出现在列表里；列表里只应有浏览器形态的应用。（Task 1 的合成用例固定这条）
3. **伪造或过期的偏好值。** 手改 defaults 写入不存在的 bundle id、或旧版本残留值，必须回退到系统默认浏览器而不是崩溃或打开错误应用。（Task 1 的测试固定这条）
4. **语言切换后选择丢失。** 切换语言会整页重建（`setupUI()`），重建后弹出的列表与已选浏览器必须和偏好一致，不能被重置成系统默认。（Task 2 的布局检查固定这条）
5. **长名称撑坏设置行。** “Google Chrome for Testing” 这类长名字不得挤掉标题、越出文档宽度。（Task 2 的布局检查固定这条）

---

### Task 1: 浏览器探测与启动路由

**Files:**
- Create: `Sources/BrowserLauncher.swift`
- Modify: `Sources/SettingsManager.swift`（在 `preferredDshTag` 那一段之后、`// MARK: - Launch At Login` 之前插入新段）
- Modify: `Sources/ServiceManager.swift:1694-1706`（`openBrowser()` 里两处 `NSWorkspace.shared.open(...)` 改为交给 launcher）
- Modify: `build.sh:37-57`（`SOURCE_FILES` 里 `Sources/ServiceNotifier.swift` 之后加一行）
- Modify: `README.md`（项目结构树 `ServiceNotifier.swift` 行之后加 `BrowserLauncher.swift` 一行中文说明）
- Create: `Tests/browser-picker-check.py`
- Modify: `Tests/run-checks.sh`（末尾新增第 20 项检查）
- Modify: `Tests/service-identity-check.py`（只改 harness：`NSWorkspace` stub 补一条方法、新增 `BrowserLauncher` stub）

**Interfaces:**
- Produces（Task 2 直接用）：
  - `struct BrowserCandidate: Equatable { let bundleIdentifier: String; let displayName: String; let applicationURL: URL }`
  - `final class BrowserLauncher { static let shared: BrowserLauncher; func options() -> [BrowserCandidate]; func systemDefaultBrowserName() -> String?; func open(_ url: URL) }`
  - `SettingsManager.preferredBrowserBundleIdentifier: String?`（读写 `DSH_PreferredBrowser`）
- Consumes: `SettingsManager.shared`、`NSWorkspace.shared`。

- [ ] **Step 1: 写失败测试 `Tests/browser-picker-check.py`**

照 `Tests/update-availability-check.py` 的写法：`method(source, signature)` 用花括号配对从生产文件里取代码块，写进临时目录，`xcrun swiftc -Onone` 编译后运行，全部断言通过才打印 PASS。被测代码只取 `Sources/BrowserLauncher.swift` 中的 `struct BrowserCandidate` 与 `final class BrowserLauncher` 两个块（不要文件的 `import AppKit` 头，夹具用 Foundation + stub 代替）。

夹具 stub（放进同一个 `main.swift`）：

```swift
import Foundation

final class SettingsManager {
    static let shared = SettingsManager()
    var preferredBrowserBundleIdentifier: String? = nil
}

final class NSWorkspace {
    final class OpenConfiguration {}
    static let shared = NSWorkspace()
    var candidates: [URL] = []
    var resolvable: [String: URL] = [:]
    var defaultApplication: URL?
    var openedDefaultURLs: [URL] = []
    var openedApps: [(app: URL, url: URL)] = []
    func urlsForApplications(toOpen url: URL) -> [URL] { candidates }
    func urlForApplication(withBundleIdentifier id: String) -> URL? { resolvable[id] }
    func urlForApplication(toOpen url: URL) -> URL? { defaultApplication }
    func open(_ url: URL) { openedDefaultURLs.append(url) }
    func open(_ urls: [URL], withApplicationAt app: URL, configuration: OpenConfiguration) {
        for url in urls { openedApps.append((app, url)) }
    }
}
```

测试自己用 `PropertyListSerialization` 在临时目录合成 `.app`：写 `Contents/Info.plist` 即可（`Bundle(url:)` 能读到 `CFBundleIdentifier`、`CFBundleURLTypes`、`CFBundleDocumentTypes`；已在 /tmp 实测）。必须覆盖的断言：

```swift
// 合成应用：chrome(浏览器)、terminal(ssh/telnet 客户端、声明 http/https、无 html)、iterm(声明 http/https+public.html+ssh)、nohtml(声明 http/https、不声明 html)、noid(浏览器形态但缺 CFBundleIdentifier)
expect(launcher.options().map(\.bundleIdentifier) == ["com.example.chrome"], "filter kept a non-browser")
expect(launcher.options().map(\.displayName) == ["Google Chrome"], "display name must come from the .app filename")
expect(launcher.systemDefaultBrowserName() == "Google Chrome", "system default name missing")
// 排序：再加一个 "Brave Browser.app" 后按名排序 => ["Brave Browser", "Google Chrome"]
// 启动路由
SettingsManager.shared.preferredBrowserBundleIdentifier = nil
launcher.open(url); expect(NSWorkspace.shared.openedDefaultURLs == [url], "system default must use plain open")
SettingsManager.shared.preferredBrowserBundleIdentifier = "com.example.chrome"
NSWorkspace.shared.resolvable = ["com.example.chrome": chromeURL]
launcher.open(url); expect(NSWorkspace.shared.openedApps.count == 1 && NSWorkspace.shared.openedApps[0].app == chromeURL, "chosen browser not used")
SettingsManager.shared.preferredBrowserBundleIdentifier = "com.example.gone"   // 未解析
launcher.open(url); expect(NSWorkspace.shared.openedDefaultURLs.last == url, "vanished browser must fall back to system default")
SettingsManager.shared.preferredBrowserBundleIdentifier = "com.example.terminal" // 解析到客户端应用
NSWorkspace.shared.resolvable = ["com.example.terminal": terminalURL]
launcher.open(url); expect(NSWorkspace.shared.openedDefaultURLs.last == url, "client app must not receive Web console links")
expect(launcher.systemDefaultBrowserName() == nil, "missing default handler must not crash or invent a name")
```

另外用文本断言锁住偏好键的读写形式（键写字面量一次，getter/setter 用常量名，与 `keyPort`、`keyPreferredDshTag` 同一种写法）：

```python
setting = (ROOT / "Sources/SettingsManager.swift").read_text()
assert setting.count('"DSH_PreferredBrowser"') == 1
assert "string(forKey: preferredBrowserKey)" in setting
assert "set(newValue, forKey: preferredBrowserKey)" in setting
assert "removeObject(forKey: preferredBrowserKey)" in setting
```

以及锁住 `ServiceManager.openBrowser()` 不再直接调 `NSWorkspace`：取该函数文本，断言两处都调用 `BrowserLauncher.shared.open(`，且函数体内不出现 `NSWorkspace.shared.open`。

- [ ] **Step 2: 跑测试确认失败**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 Tests/browser-picker-check.py`
Expected: FAIL — `Sources/BrowserLauncher.swift` 不存在，`FileNotFoundError` / `ValueError: substring not found`。

- [ ] **Step 3: 实现 `Sources/BrowserLauncher.swift`**

```swift
import AppKit

/// A browser DSH Bar can hand the Web console URL to. Only the application
/// bundle is carried — the icon is fetched where it is shown.
struct BrowserCandidate: Equatable {
    let bundleIdentifier: String
    let displayName: String
    let applicationURL: URL
}

/// Decides which browser `Open Web` uses.
///
/// Detection reads LaunchServices once per panel build. The filter is
/// deliberately structural rather than category-based: `LSApplicationCategoryType`
/// is absent on Chrome/Brave/Orion and says "productivity" for Safari, Firefox,
/// Zen and iTerm alike, and iTerm also declares http/https plus `public.html`.
/// Scheme groups and HTML handling are what actually separate a browser from a
/// terminal.
final class BrowserLauncher {
    static let shared = BrowserLauncher()

    static let sampleURL = URL(string: "https://example.com")!

    /// Applications that claim http/https because they *open links in another
    /// program* (terminals, mail/news clients, file-transfer tools) rather than
    /// render pages. Observing iTerm's scheme list is what motivated this.
    private static let clientSchemes: Set<String> = [
        "ssh", "sftp", "telnet", "rlogin", "ftp", "tftp", "mailto", "news", "nntp",
        "gopher", "wais", "whois", "gemini", "titan", "irc", "ircs", "afp", "smb",
        "nfs", "x-man-page"
    ]

    private static let htmlExtensions: Set<String> = ["html", "htm", "shtml", "xhtml", "xht"]

    func options() -> [BrowserCandidate] { ... }

    func systemDefaultBrowserName() -> String? { ... }

    func open(_ url: URL) { ... }

    // MARK: - Internals
    private static func schemes(_ appURL: URL) -> [[String]] { ... }
    private static func declaresHTML(_ appURL: URL) -> Bool { ... }
    private static func isBrowser(_ appURL: URL) -> Bool { ... }
    private static func displayName(_ appURL: URL) -> String { ... }
}
```

实现要点（其余由实现者按签名写）：`options()` 遍历 `urlsForApplications`，过滤 `isBrowser`、跳过无 bundle id 的项、按 identifier 去重、按 `displayName.localizedCaseInsensitiveCompare` 排序；`isBrowser` 检查 (a) 所有协议组**合并后**同时含 `http` 与 `https`（Firefox 与 Zen 把它们分别登记在 `[["http"], ["https"], ["file"]]` 两个组里，所以不能按「某一组同时含两者」判断），(b) 所有组都不含 `clientSchemes`（`isDisjoint`），(c) `declaresHTML`；`displayName` 取 `url.deletingPathExtension().lastPathComponent`；`systemDefaultBrowserName` 用 `urlForApplication(toOpen: Self.sampleURL)` 再取显示名，取不到返回 `nil`；`open(_:)` 先读 `SettingsManager.shared.preferredBrowserBundleIdentifier`，能解析到 `urlForApplication(withBundleIdentifier:)` 且 `isBrowser(appURL)` 为真时 `NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())`，否则 `NSWorkspace.shared.open(url)`。

- [ ] **Step 4: 加 `SettingsManager` 偏好键**

在 `preferredDshTag` 段之后插入，形式与 `preferredDshTag` 一致（`nil` 即删除键）：

```swift
    // MARK: - Default Browser
    private let preferredBrowserKey = "DSH_PreferredBrowser"

    /// Bundle identifier of the browser `Open Web` uses; `nil` means the
    /// system default handler. Not validated here on purpose: a stored app
    /// can disappear, and `BrowserLauncher` is what re-checks eligibility.
    var preferredBrowserBundleIdentifier: String? {
        get {
            guard let value = UserDefaults.standard.string(forKey: preferredBrowserKey) else { return nil }
            return value.isEmpty ? nil : value
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: preferredBrowserKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferredBrowserKey)
            }
        }
    }
```

- [ ] **Step 5: 改 `ServiceManager.openBrowser()` 与 `build.sh`**

`openBrowser()` 保持全部身份判断与 URL 选择不变，只把两个打开点交给 launcher：

```swift
    func openBrowser() {
        guard snapshot.isRunning, snapshot.isManaged, let record = managedRecord,
              record.port == snapshot.port, record.pid == snapshot.pid,
              let startedAt = snapshot.startedAt,
              abs(startedAt.timeIntervalSince(record.startedAt)) < 5 else {
            BrowserLauncher.shared.open(baseUrl)
            return
        }
        let currentLaunchURL = snapshot.pid == launchedProcess?.processIdentifier
            ? launchedLogWriter?.authenticatedURL : nil
        let url = authenticatedURL ?? currentLaunchURL ?? baseUrl
        BrowserLauncher.shared.open(url.port == snapshot.port ? url : baseUrl)
    }
```

`build.sh` 的 `SOURCE_FILES` 在 `Sources/ServiceNotifier.swift` 之后插入 `Sources/BrowserLauncher.swift`。`README.md` 项目结构树里在 `ServiceNotifier.swift` 行后插入：

```text
│   ├── BrowserLauncher.swift   # 检测本机浏览器并决定 Open Web 用哪个打开
```

- [ ] **Step 6: 让 `Tests/service-identity-check.py` 继续通过**

该文件把 `openBrowser()` 抽出来跑在 stub 世界里，只需补两个 stub（断言一条都不用改）：`final class NSWorkspace` 增加 `func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? { nil }`，并新增

```swift
final class BrowserLauncher {
    static let shared = BrowserLauncher()
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
```

`BrowserLauncher` 在这个夹具里永远解析不到应用，因此每次都走 `NSWorkspace.shared.open(url)`，既有的 `NSWorkspace.shared.lastURL` 断言原样成立。

- [ ] **Step 7: 把新检查接进 `Tests/run-checks.sh`**

在文件末尾（第 19 项之后、`exit $FAILED` 之前）加：

```bash
# 20. Open Web must follow the chosen browser and fall back to the system default.
if python3 "$SCRIPT_DIR/browser-picker-check.py"; then
    pass "browser detection filters terminals and honours the chosen browser"
else
    fail "browser picker check failed — run python3 $SCRIPT_DIR/browser-picker-check.py to see why"
fi
```

- [ ] **Step 8: 跑测试与全量检查**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 Tests/browser-picker-check.py` → Expected: PASS
Run: `PYTHONDONTWRITEBYTECODE=1 python3 Tests/service-identity-check.py` → Expected: PASS
Run: `PYTHONDONTWRITEBYTECODE=1 make check` → Expected: 20 项检查全 ok，无 FAIL

- [ ] **Step 9: Commit**

```bash
git add Sources/BrowserLauncher.swift Sources/SettingsManager.swift Sources/ServiceManager.swift build.sh README.md Tests/browser-picker-check.py Tests/run-checks.sh Tests/service-identity-check.py
git commit -m "feat: open the Web console in a chosen browser"
```

---

### Task 2: 偏好设置里的浏览器行

**Files:**
- Modify: `Sources/DashboardWindow.swift`（控件声明区 ~:190-215、`makePreferencesCard()` General 组 :640-650、新增 `refreshBrowserOptions()` 与 `@objc didChangeBrowser()`、`showWindow()` :315-333）
- Modify: `Sources/Localization.swift`（`Key` 的精确四个 case + `english` 表 + `chinese` 表）
- Modify: `Tests/dashboard-ui-fixture.py`（STUBS 里补 `BrowserCandidate`、`BrowserLauncher`，给 `SettingsManager` 补偏好字段）
- Modify: `Tests/settings-layout-check.py`（`controls`、标题键列表、`rowControls`、以及“切换语言后选择仍正确”的断言）
- Modify: `README.md`（核心特性里偏好设置那组 bullet）

**Interfaces:**
- Consumes：`BrowserLauncher.shared.options()`, `.systemDefaultBrowserName()`, `BrowserCandidate`（Task 1 产出）；`SettingsManager.shared.preferredBrowserBundleIdentifier`。
- Produces：`private let browserPopup = NSPopUpButton()`；`private func refreshBrowserOptions()`；`@objc private func didChangeBrowser()`。

- [ ] **Step 1: 先写失败断言（改 `Tests/settings-layout-check.py`）**

`controls` 列表加一项 `("browser picker", panel.browserPopup)`；标题键列表加 `.openWebBrowser`；`rowControls` 加 `(.openWebBrowser, panel.browserPopup)`（重叠断言按行比较标题右缘与控制左缘，这一行的长标题正好是它要压的那条）。逐条渲染的 `geometry(_:active:)` 里只加一条与状态无关的宽度断言 `expect(panel.browserPopup.bounds.width >= 160, ...)`。

列表内容与“重建后选择不丢”两条断言放在文件末尾、`geometry` 之外单独跑一次（它们在 `geometry` 内会污染其后所有组合：一旦把偏好设成 `com.example.chrome`，后续每次重建前的“系统默认在首位且被选中”就不再成立）：

```swift
// 列表内容：系统默认在首位，随后是按名排序的检测结果；长名字被接受而不是越界。
SettingsManager.shared.preferredBrowserBundleIdentifier = nil
panel.setupUI()
panel.updateState(ServiceManager.shared.snapshot)
let browserItems = panel.browserPopup.itemArray.map { $0.title }
expect(panel.browserPopup.numberOfItems == 3, "browser picker items: \(browserItems)")
expect(panel.browserPopup.selectedItem?.representedObject as? String == "",
       "system default must be the first, pre-selected item")
expect(browserItems[1] == "Google Chrome" && browserItems[2] == "Google Chrome for Testing",
       "detected browsers missing or unsorted: \(browserItems)")
expect(panel.browserPopup.selectedItem?.title.hasPrefix("System default") == true,
       "system default item must name the handler: \(panel.browserPopup.selectedItem?.title ?? "none")")
// 语言重建（setupUI）之后选择必须还在。
SettingsManager.shared.preferredBrowserBundleIdentifier = "com.example.chrome"
panel.setupUI()
panel.updateState(ServiceManager.shared.snapshot)
expect(panel.browserPopup.selectedItem?.representedObject as? String == "com.example.chrome",
       "language rebuild reset the chosen browser")
// 记住的值在列表里消失时回到系统默认，而不是留空的选中项。
SettingsManager.shared.preferredBrowserBundleIdentifier = "com.example.uninstalled"
panel.setupUI()
expect(panel.browserPopup.selectedItem?.representedObject as? String == "",
       "a stale preference must fall back to the system default item")
SettingsManager.shared.preferredBrowserBundleIdentifier = nil
```

- [ ] **Step 2: 跑测试确认失败**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 Tests/settings-layout-check.py`
Expected: FAIL — `DashboardWindow.swift` 编译失败（`browserPopup` 无此成员）。

- [ ] **Step 3: 加双语文案**

`Key` 的 “Preferences rows” 组里、`case language, languageDesc, languageAutomatic` 之后加一行：

```swift
        case openWebBrowser, openWebBrowserDesc, systemDefaultBrowser, systemDefaultBrowserNamed
```

`english` 表在原 `.language*` 条目附近加：

```swift
        .openWebBrowser: "Open Web in",
        .openWebBrowserDesc: "The console opens here. Other browsers found on this Mac are listed below.",
        .systemDefaultBrowser: "System default",
        .systemDefaultBrowserNamed: "System default ({browser})",
```

`chinese` 表加：

```swift
        .openWebBrowser: "打开 Web 使用的浏览器",
        .openWebBrowserDesc: "控制台在此浏览器中打开；本机找到的其他浏览器列在下方。",
        .systemDefaultBrowser: "系统默认浏览器",
        .systemDefaultBrowserNamed: "系统默认（{browser}）",
```

- [ ] **Step 4: 面板里的控件、构建与切换**

控件声明区（`private let languagePopup = NSPopUpButton()` 之后）加 `private let browserPopup = NSPopUpButton()`。

`makePreferencesCard()` 里在 `permissionsGuideButton` 配置之后、`notificationInfoLabel` 之前构建列表：

```swift
        refreshBrowserOptions()
        browserPopup.target = self
        browserPopup.action = #selector(didChangeBrowser)
        browserPopup.setAccessibilityLabel(L(.openWebBrowser))
        browserPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
```

General 组的 rows 里，`permissionsAccess` 行之前插入：

```swift
            settingsRow(text: makeTextStack(title: L(.openWebBrowser), description: L(.openWebBrowserDesc)), control: browserPopup),
```

新增两个方法（放在 `didChangeLanguage` 附近）：

```swift
    /// Rebuilds the popup from what LaunchServices reports right now. The
    /// selected browser is re-read here so a language rebuild or a browser
    /// that was uninstalled since the last open both land on a valid item.
    private func refreshBrowserOptions() {
        let launcher = BrowserLauncher.shared
        browserPopup.removeAllItems()
        let defaultTitle = launcher.systemDefaultBrowserName().map {
            L(.systemDefaultBrowserNamed, ["browser": $0])
        } ?? L(.systemDefaultBrowser)
        browserPopup.addItem(withTitle: defaultTitle)
        browserPopup.lastItem?.representedObject = ""
        for candidate in launcher.options() {
            browserPopup.addItem(withTitle: candidate.displayName)
            browserPopup.lastItem?.representedObject = candidate.bundleIdentifier
            browserPopup.lastItem?.image = NSWorkspace.shared.icon(forFile: candidate.applicationURL.path)
        }
        let preferred = SettingsManager.shared.preferredBrowserBundleIdentifier ?? ""
        let index = browserPopup.itemArray.firstIndex { ($0.representedObject as? String) == preferred }
        browserPopup.selectItem(at: index ?? 0)
    }

    @objc private func didChangeBrowser() {
        let identifier = browserPopup.selectedItem?.representedObject as? String
        SettingsManager.shared.preferredBrowserBundleIdentifier =
            (identifier?.isEmpty ?? true) ? nil : identifier
    }
```

选择本身只写偏好键，不重建列表：重建只可能发生在面板构建与重新打开时（新装的浏览器只在这两个时刻才可能出现），和 `didChangeTag()`（Sources/DashboardWindow.swift:1216-1221）只写偏好、由另一行重渲染的做法一致。

`showWindow(_:)` 里在 `loadTagOptions()` 之后加一行 `refreshBrowserOptions()`，让面板重新打开时能看到新装的浏览器。`rebuildForLanguage()` 无需改动：它调用 `setupUI()`，`makePreferencesCard()` 会重建列表。

- [ ] **Step 5: 夹具补 stub**

`Tests/dashboard-ui-fixture.py` 的 STUBS：`final class SettingsManager` 加 `var preferredBrowserBundleIdentifier: String? = nil`；STUBS 末尾（`expect`/`pump` 之前）加

```swift
struct BrowserCandidate: Equatable {
    let bundleIdentifier: String
    let displayName: String
    let applicationURL: URL
}
final class BrowserLauncher {
    static let shared = BrowserLauncher()
    var preferredDefaultName: String? = "Google Chrome"
    var detected: [BrowserCandidate] = [
        BrowserCandidate(bundleIdentifier: "com.example.chrome", displayName: "Google Chrome",
                         applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")),
        BrowserCandidate(bundleIdentifier: "com.example.chrome.testing", displayName: "Google Chrome for Testing",
                         applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome for Testing.app"))
    ]
    func options() -> [BrowserCandidate] { detected }
    func systemDefaultBrowserName() -> String? { preferredDefaultName }
    func open(_ url: URL) {}
}
```

- [ ] **Step 6: 跑测试确认通过**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 Tests/settings-layout-check.py` → Expected: PASS（英文/中文、540/580 宽、深浅色全部通过，PNG 仍在 `build/settings-preview`）
Run: `PYTHONDONTWRITEBYTECODE=1 python3 Tests/localization-check.py` → Expected: PASS
Run: `PYTHONDONTWRITEBYTECODE=1 make check` → Expected: 20 项全 ok

- [ ] **Step 7: README 特性说明**

核心特性里「手动打开 Web」那条改成点名新设置，并在偏好设置 bullet 组里加一行：

```markdown
- **手动打开 Web**：只有点击 Open Web 或使用它的全局热键时，才会打开浏览器。默认跟随系统默认浏览器，可在偏好设置里改成本机检测到的其他浏览器；所选应用被卸载后自动回退系统默认浏览器。使用本次启动捕获的认证 URL，token 只保留在内存中。
```

偏好设置 bullet 组（`**全局热键**` 那行之后）加：

```markdown
  - **打开 Web 使用的浏览器**：系统默认浏览器，或本机检测到的其他浏览器。检测只读，列出的是同时声明 http/https 并能处理 HTML 的应用，终端等链接客户端不在列表内。
```

- [ ] **Step 8: Commit**

```bash
git add Sources/DashboardWindow.swift Sources/Localization.swift Tests/dashboard-ui-fixture.py Tests/settings-layout-check.py README.md
git commit -m "feat: choose the browser Open Web uses"
```

---

### Task 3: 版本 1.0.7 与发布说明

**Files:**
- Modify: `Info.plist`（`CFBundleShortVersionString`、`CFBundleVersion` 两处 `1.0.6` → `1.0.7`）
- Create: `Packaging/ReleaseNotes/1.0.7.md`
- Create: `Packaging/ReleaseNotes/1.0.7.html`

**Interfaces:**
- Consumes：Task 1/2 的行为；发布工作流按 tag 取 `Packaging/ReleaseNotes/${VERSION}.md` 与 `.html`。

- [ ] **Step 1: 写发布说明（先写文本，再让版本与检查对齐）**

`Packaging/ReleaseNotes/1.0.7.md`：

```markdown
### What's changed

- Added an "Open Web in" choice in Settings. The Web console now opens in the system default browser or in any browser found on this Mac, and remembers the choice across launches and language switches.
- Browser detection is read-only. It lists applications that both claim http/https links and handle HTML; terminal and other link clients that register http/https are excluded.
- If the chosen browser is removed later, Open Web falls back to the system default browser instead of failing, and the choice returns automatically once that browser is installed again.

### Permissions and defaults stay untouched

This release never changes the system default browser. The new row only decides which application DSH Bar hands its own console URL to.
```

`Packaging/ReleaseNotes/1.0.7.html` 用 1.0.6.html 的同一结构（`<h3>What's changed</h3><ul><li>…`）：

```html
<h3>What's changed</h3>
<ul>
<li>Added an "Open Web in" choice in Settings. The Web console now opens in the system default browser or in any browser found on this Mac, and remembers the choice across launches and language switches.</li>
<li>Browser detection is read-only. It lists applications that both claim http/https links and handle HTML; terminal and other link clients that register http/https are excluded.</li>
<li>If the chosen browser is removed later, Open Web falls back to the system default browser instead of failing, and the choice returns automatically once that browser is installed again.</li>
</ul>
<h3>Permissions and defaults stay untouched</h3>
<p>This release never changes the system default browser. The new row only decides which application DSH Bar hands its own console URL to.</p>
```

- [ ] **Step 2: 修改 `Info.plist` 版本**

```bash
python3 - <<'PY'
from pathlib import Path
path = Path("Info.plist")
text = path.read_text()
assert text.count("<string>1.0.6</string>") == 2, text.count("<string>1.0.6</string>")
path.write_text(text.replace("<string>1.0.6</string>", "<string>1.0.7</string>"))
PY
grep -n "1.0.7" Info.plist
```

Expected: 两行 `1.0.7`（`CFBundleShortVersionString` 与 `CFBundleVersion`）。

- [ ] **Step 3: 跑全量检查**

Run: `PYTHONDONTWRITEBYTECODE=1 make check` → Expected: 20 项全 ok（`Tests/sparkle-check.sh` 用的是自带的 `1.0.0` 夹具，不受影响）
Run: `ARCHS=arm64 ./build.sh` → Expected: 构建成功，`build/DeepSeek Harness Bar.app/Contents/Info.plist` 里版本为 1.0.7（`grep -A1 CFBundleShortVersionString "build/DeepSeek Harness Bar.app/Contents/Info.plist"`）

- [ ] **Step 4: Commit**

```bash
git add Info.plist Packaging/ReleaseNotes/1.0.7.md Packaging/ReleaseNotes/1.0.7.html
git commit -m "chore: release v1.0.7"
```

---

## 发布（控制器执行，不属于任何实现子代理）

最终审查通过后由控制器完成，顺序不可换：

1. `PYTHONDONTWRITEBYTECODE=1 make check` 全绿，`make` 完整通用构建通过。
2. 快进推送到 `main`（`git push origin main`），等待 `ci.yml` 成功。
3. 打 annotated tag `v1.0.7`（不覆盖已有 tag）并推送，等待 `release.yml` 成功。
4. 核验发布资产：ZIP 大小/SHA256、包内版本 1.0.7、`codesign --verify --deep --strict`、appcast 指向 v1.0.7。
5. 把上述结果写进本计划的 `## Verification recorded` 与 `## Release verification recorded — v1.0.7` 两节，提交并推送这条记录。
