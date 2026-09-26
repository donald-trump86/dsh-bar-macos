# DeepSeek Harness Bar (macOS) 🐳

<p align="center">
  <img src="Resources/icon.png" width="128" height="128" alt="DeepSeek Harness Bar Icon">
</p>

<p align="center">
  <b>A native macOS menu bar companion for DeepSeek Harness.</b><br>
  专为 DeepSeek Harness 打造的原生 macOS 菜单栏助手：查看运行状态、一键启停、直达 Web 界面。
</p>

---

## 💡 为什么用它？ / Why DeepSeek Harness Bar?

如果你平时用 `dsh web` 启动 DeepSeek Harness，那么“服务在不在跑”“怎么停掉后台进程”“换端口后怎么重启”这些事，通常都得回到终端敲 `lsof`、`kill`。DSH Bar 把这些操作放进菜单栏，随手一点即可。

- **纯原生 Swift**：无第三方依赖，发布包同时支持 Apple Silicon 与 Intel，不占用 Dock 位置。
- **状态一眼可见**：菜单栏状态灯区分检查中、启动中、运行中、端口冲突与错误，并显示 PID、运行时长和 DSH 版本。
- **可自定义**：端口、打开 Web 的全局热键与开机自启动；应用和服务启动/重启时都不会自动打开网页。
- **只停自己的服务**：停止时只结束由本应用启动的 `dsh` 进程，不会误杀占用同一端口的浏览器或其他程序。

---

## ⚡️ 前置条件 / Prerequisites

> **本应用是 DeepSeek Harness 的伴侣工具，需要官方 `dsh` 命令行。**

DSH Bar 会通过 `which dsh` 自动检测安装路径并读取版本。如果没有找到，会在设置界面显示 **Install…**，复制官方 npm 安装命令并打开终端协助安装：

```bash
npm install -g @deepseek-ai/dsh
```

- **操作系统**：macOS 13.0 (Ventura) 及以上，支持 Apple Silicon 与 Intel。

---

## 🚨 常见问题：提示“应用已损坏，无法打开”？ / Troubleshooting

本项目没有使用 Apple Developer Program 的签名与公证证书，所以从 GitHub 下载后，macOS 的 Gatekeeper 可能提示：

> **“DeepSeek Harness Bar 已损坏，无法打开。你应该将它移到废纸篓”** 或 **“无法打开，因为无法验证开发者”**

**解决方法**：在终端里解除隔离属性。

```bash
xattr -cr "/Applications/DeepSeek Harness Bar.app"
```

执行后即可正常启动。若提示权限不足，再在命令前加上 `sudo`。

> ⚠️ **从旧版升级请先删除**：0.1.0 起应用改名为 **DeepSeek Harness Bar**。旧版 `DSH Bar.app` 与新版共用同一个 bundle identifier，两者同时存在时 macOS 可能打开错的那个——请先删掉旧版再安装。

> 💡 **图形界面方法**：打开「系统设置」→「隐私与安全性」，滑到底部会看到"已阻止使用 DeepSeek Harness Bar"，点击 **"仍要打开"**。

---

## ✨ 核心特性 / Features

- 🐳 **菜单栏常驻**：系统原生 `🐳` Emoji，自适应深浅色，不占用 Dock 栏位。
- 🟢 **详细服务状态**：菜单栏与设置页显示检查中、启动中、运行中、停止中、重启中、端口冲突和错误，并提供 PID、运行时长及已安装 DSH 版本。
- 🔌 **自定义端口**：默认 3080。运行中修改端口会保留旧监听，重启前先检查新端口，避免误停或遗留服务。
- 🚀 **安静启停 / 重启**：始终使用 `dsh web --no-open` 在后台启动；Start 和 Restart 不会拉起浏览器。
- 🔐 **只管理自己的服务**：启动时把 `{PID, 端口, 启动时间}` 记录到 `~/.dsh/dsh-bar-service.json`。停止前会校验进程启动时间是否匹配，PID 被复用时拒绝操作。
- 🔧 **也能关掉终端里启动的服务**：若服务是你自己用 `dsh web` 起的，面板会显示 **Stop External…** 与 **Adopt & Restart**。点击后弹窗列出该进程的 PID、端口和完整命令行，确认后才结束它；`Adopt & Restart` 会顺手改由 DSH Bar 接管，之后 Stop/Restart 无需再回终端。非 Harness 监听者、多进程监听、非当前用户的进程一律拒绝。
- 🛡️ **重启前先预检，不会"杀了起不来"**：重启前先确认目标端口空闲、DSH CLI 仍然存在。任何一项不过就**保持旧服务原样运行**并说明原因——以前 `dsh` 被卸载或切换 Node 版本导致 shim 失效时，重启会先杀掉正在工作的服务再启动失败。
- 🚪 **退出语义明确**：`⌘Q` 退出菜单栏图标、**保留后台服务**（下次打开自动重新接管）；需要连服务一起关掉时用 `⌘⌥Q` **Quit & Stop Service…**。外部启动的服务在任何退出路径下都不会被停止。
- 🔔 **异常退出有通知**：DSH Bar 自己启动的服务意外消失时发系统通知，并做**受控自动重启**（10 分钟内最多 3 次，退避 1s/4s/16s，超过就停下并告知，不会无限重启循环）。手动停止过的服务不会自己复活，外部启动的服务只报告、不重启。
- 🧯 **通知失效时有降级路径**：ad-hoc 签名的应用每次重建都可能丢失通知授权，所以面板会用橙色显示通知的真实状态和原因，并提供"Fix…"；崩溃与恢复的提示会保留在面板和菜单栏提示里，不依赖通知送达。
- 🌏 **简体中文界面**：偏好设置里可切换 **自动 / English / 简体中文**，切换后**立即生效、无需重启**（面板、菜单栏、日志窗口同时跟随）。
- 🌐 **显式打开 Web**：只有点击 Open Web 或使用其全局热键时才打开浏览器，并使用本次启动捕获的认证 URL（token 只留在内存中）。
- 📜 **内置实时日志**：直接在应用中跟踪 `~/.dsh/logs/dsh-web.log`，支持暂停、搜索、清空当前视图和在 Finder 中定位；显示时会自动隐藏 URL 中的进程 token。
- 🔎 **DSH 自动检测**：通过 `which dsh` 检测路径和版本，未安装时提供 npm 安装引导。
- 🪟 **偏好设置面板（`⌘,`）**：
  - **端口**：修改并一键恢复默认（服务启停/重启期间会锁定，避免端口错配）。
  - **全局热键**：录制自定义全局热键，录完立即生效。
  - **开机自启动**（Launch at login）。
  - 检查 DSH CLI 路径和版本，并在缺失时提供安装引导。
  - 复制本地 Web 地址、打开内置实时日志。
  - 启动或重启 DSH Bar、启动或重启服务时都不会自动打开 Web 界面。

---

## ⌨️ 快捷键速查 / Shortcuts

### 全局热键（任何软件处于前台时都有效）
| 快捷键 | 动作 | 说明 |
| :--- | :--- | :--- |
| **`⇧ + ⌘ + D`**<br>*(可在设置中修改)* | 打开 DSH Web | 服务未启动则先在后台拉起，再打开浏览器；已在运行则直接打开 |

### 菜单栏 / 面板内快捷键
| 快捷键 | 动作 |
| :--- | :--- |
| **`⌘ + ,`** | 打开偏好设置面板 |
| **`⌘ + O`** | 在默认浏览器中打开 Web 控制台 |
| **`⌘ + S`** | 启动 / 停止后台服务 |
| **`⌘ + R`** | 重启服务 |
| **`⇧ + ⌘ + C`** | 复制 Web 地址 (`http://127.0.0.1:<port>`) |
| **`⌘ + L`** | 查看实时运行日志 |
| **`Esc` / `⌘ + W`** | 关闭面板（应用仍在菜单栏常驻） |
| **`⌘ + Q`** | 退出 DSH Bar（保留后台服务） |
| **`⌘ + ⌥ + Q`** | 退出并停止 DSH Bar 启动的服务 |

> 界面语言在**偏好设置 → 语言**中切换，立即生效。

---

## 🛠 安装与构建 / Installation & Build

### 方式一：下载 GitHub Release（推荐）

每个 `v*` 标签都会由 GitHub Actions 自动构建同时支持 Apple Silicon 和 Intel 的通用应用，并在 Release 中生成（`0.x` 版本会标记为 Pre-release）：

- `DSH-Bar-<version>-universal.zip`
- 对应的 `.sha256` 校验文件

发布包的签名取决于仓库是否配置了 Developer ID secrets：

| 配置 | 结果 |
| :--- | :--- |
| 已配置 `APPLE_CERT_P12_BASE64`、`APPLE_CERT_PASSWORD`、`APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD` | Developer ID 签名 + 硬化运行时 + 公证 + stapler，Gatekeeper 可直接打开 |
| 未配置 | 仅 ad-hoc 签名，Release 说明会明确提示需要手动执行 `xattr -cr` |

发布前可在本地复现同样的产物：

```bash
VERSION=0.1.0 ./build.sh          # 通用二进制 + ad-hoc 签名
VERSION=0.1.0 SIGNING_IDENTITY="Developer ID Application: …" ./build.sh
```

### 方式二：从源码编译并安装

```bash
git clone https://github.com/donald-trump86/dsh-bar-macos.git
cd dsh-bar-macos
make install
open -a "DeepSeek Harness Bar"
```

### 方式三：只编译，不安装

```bash
make
open "build/DeepSeek Harness Bar.app"
```

---

## ✅ 提交前自查 / Before You Commit

```bash
make check
```

校验中英文案 key 是否一一对应、`build.sh` 的应用名与 `Info.plist` 是否一致、README 里的路径是否还能用。CI 也会跑同一份脚本。

---

## 📂 项目结构 / Project Structure

```text
dsh-bar-macos/
├── Sources/
│   ├── main.swift              # 程序入口
│   ├── AppDelegate.swift       # 菜单栏图标（🐳 + 状态点）、菜单与状态控制
│   ├── ServiceManager.swift    # 详细状态、身份检测、安静启停、PID 与 DSH 检测
│   ├── HotKeyManager.swift     # “打开 Web”可配置全局热键
│   ├── SettingsManager.swift   # 端口、开机启动 (SMAppService)、热键持久化
│   ├── DashboardWindow.swift   # 毛玻璃偏好设置面板
│   ├── LogWindow.swift         # 内置实时日志窗口
│   ├── DshInstallAssistant.swift # DSH/npm 安装引导
│   ├── ExternalServicePrompt.swift # 结束外部启动服务的确认弹窗
│   ├── ServiceNotifier.swift   # 系统通知与不可用时的降级
│   └── Localization.swift      # 中英双语文案表（枚举键 + 缺失回退英文）
├── Resources/
│   ├── AppIcon.icns            # 应用图标 (1024x1024)
│   └── icon.png                # README 与面板使用的图标
├── Packaging/
│   └── DSHBar.entitlements     # Developer ID 签名使用的 hardened runtime 配置
├── Info.plist                  # Bundle 配置（LSUIElement，仅菜单栏）
├── .github/workflows/release.yml # 标签触发的通用应用构建与 Release 发布
├── build.sh                    # macOS 13+ 通用二进制编译、签名与打包脚本
├── Makefile                    # make build / install / run / clean
├── LICENSE                     # MIT
└── README.md                   # 项目说明
```

---

## 📄 开源许可证 / License

本项目基于 [MIT License](LICENSE) 开源。
欢迎提 Issue 或 PR。
