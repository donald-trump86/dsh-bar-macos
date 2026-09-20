# DSH Bar (macOS) 🐋

<p align="center">
  <img src="Resources/icon.png" width="128" height="128" alt="DSH Bar Icon">
</p>

<p align="center">
  <b>A native, ultra-lightweight macOS menu bar companion and quick launcher for DeepSeek Harness.</b><br>
  专为 DeepSeek Harness 打造的原生极简 macOS 菜单栏状态助手与快捷控制中心。
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#prerequisites">Prerequisites</a> •
  <a href="#installation">Installation</a> •
  <a href="#troubleshooting-app-is-damaged">解除已损坏提示 (FAQ)</a> •
  <a href="#keyboard-shortcuts">Shortcuts</a> •
  <a href="#preferences">Preferences</a> •
  <a href="#license">License</a>
</p>

---

## 💡 为什么选择 DSH Bar？ / Why DSH Bar?

如果你已经在终端中通过 `dsh web` 使用 DeepSeek Harness，每次查看服务是否在跑、停止后台进程、重启服务往往需要反复切换终端敲 `lsof` 或 `kill` 命令。

市面上现有的 Launcher 多为基于 Electron / Tauri 的独立大窗口重型套件（内嵌各种独立运行时与依赖，体积与内存消耗上百兆）。

**DSH Bar 坚持极客、轻量与无感伴随的理念**：
- **纯原生 Swift 构建**：无第三方依赖，纯二进制仅约 **150 KB**，冷启动 <0.1 秒，运行时内存占用仅 **~15 MB**。
- **全新原创视网膜图标**：融合萌宠小鲸鱼与 macOS 状态栏设计语言，美观高级且无官方版权侵权风险。
- **清晰锐利的鲸鱼 Emoji**：菜单栏采用系统原生 `🐳` Emoji，自适应深浅色模式，告别低分辨率位图模糊。
- **隐形常驻**：常驻顶部菜单栏，不占用 Dock 栏位置，不打扰日常工作。
- **键盘优先**：全面支持 macOS 标准快捷键（`⌘,`）、控制面板与随时随地全局直达热键。

---

## ⚡️ 前置条件 / Prerequisites

> [!IMPORTANT]
> **本应用设计为 DeepSeek Harness 的辅助控制伴侣，运行前需确保系统中已安装官方 `dsh` 命令行工具。**
> 
> This application is a companion controller. Please ensure the official `@deepseek-ai/dsh` CLI is already installed on your system.

你可以通过以下命令确认或安装：

```bash
# 验证 dsh 是否已安装
dsh --version

# 如果尚未安装，请通过 npm/pnpm 或官方渠道全局安装：
npm install -g @deepseek-ai/dsh
```

- **操作系统支持**：macOS 13.0 (Ventura) 及更高版本（原生支持 Apple Silicon M1/M2/M3/M4 系列及 Intel 芯片）。

---

## 🚨 常见问题：提示“应用已损坏，无法打开”？ / Troubleshooting

由于个人开源项目未购买苹果官方昂贵的高级开发者公证证书（Apple Developer Program），macOS 的 Gatekeeper 安全机制在检测到从 GitHub 下载的应用时，可能会弹出警告：

> **“DSH Bar 已损坏，无法打开。你应该将它移到废纸篓”** 或 **“无法打开，因为无法验证开发者”**

### 解决方案（一键解除隔离）：

打开 macOS 自带的 **终端（Terminal）**，复制并运行以下命令解除隔离属性：

```bash
sudo xattr -rd com.apple.quarantine "/Applications/DSH Bar.app"
```
*(输入密码时不会显示字符，直接回车即可)*

或者也可以运行：
```bash
xattr -cr "/Applications/DSH Bar.app"
```

执行后即可正常双击启动！

> 💡 **备用方法（图形界面）**：前往系统「系统设置」→「隐私与安全性」，滑到最下方会看到 *“已阻止使用 DSH Bar”* 的提示，点击旁边的 **“仍要打开”** 即可。

---

## ✨ 核心特性 / Features

- 🐳 **原生极简菜单栏**：采用清晰利落的系统原生鲸鱼 Emoji `🐳`，不模糊、不花哨。
- 🟢 **实时状态感知**：状态栏实时轮询监测服务端口健康状态（绿色在线 / 灰色已停止）。
- 🔌 **支持自定义服务端口**：默认 3080 端口，可自由修改为任意端口（如 3081、8080 等），服务启停与网页访问自动同步适配。
- 🚀 **一键启停与平滑重启**：无缝拉起后台守护进程，支持一键重启，日志自动归档至 `~/.dsh/logs/dsh-web.log`。
- 🌐 **瞬间直达**：点击或快捷键即可直接在系统默认浏览器中打开/聚焦 Harness 界面。
- 🪟 **原生毛玻璃偏好设置面板（⌘,）**：
  - **自定义端口**：支持配置、应用与一键重置默认端口。
  - **自定义全局热键**：自由录制属于你的全局热键（如 `⌥⇧D`、`⌃⌥D`、`⌘⇧D` 等），即按即录、即刻生效。
  - **开机自启动开关**（Launch at login）：一键勾选，开机后自动在后台常驻菜单栏。
  - **启动时自动打开网页**（Auto open Web on launch）：自由开启或关闭。
  - 一键复制本地 Web 地址与查看运行日志。

---

## ⌨️ 快捷键速查 / Shortcuts

### 全局系统热键（任何软件处于前台均有效）
| 快捷键 | 动作 | 说明 |
| :--- | :--- | :--- |
| **`⌥ + ⇧ + D`**<br>*(支持在设置中自定义)* | **一键直达 DSH Web** | 若服务未启动则后台拉起并打开浏览器；若已在运行则直接前置浏览器 |
| **`⌥ + ⇧ + H`** | **唤出设置面板** | 随时弹出原生悬浮偏好设置面板 |

### 菜单栏 / 面板内快捷键
| 快捷键 | 动作 |
| :--- | :--- |
| **`⌘ + ,`** (Command + 逗号) | **展开偏好设置与控制面板 (符合 macOS 标准规范)** |
| **`⌘ + O`** | 在默认浏览器中打开 Web 控制台 |
| **`⌘ + S`** | 启动 / 停止后台 Harness 服务 |
| **`⌘ + R`** | 平滑重启 Harness 服务 |
| **`⇧ + ⌘ + C`** | 复制 Web 地址 (`http://127.0.0.1:<port>`) 到剪贴板 |
| **`⌘ + L`** | 查看实时运行日志 |
| **`Esc` / `⌘ + W`** | 关闭控制中心面板（应用仍在后台静默常驻） |
| **`⌘ + Q`** | 退出 DSH Bar 菜单栏应用 |

---

## 🛠 安装与构建 / Installation & Build

### 方式一：源码一键编译与安装（推荐）

直接在终端克隆本项目并编译安装：

```bash
# 1. 克隆代码
git clone https://github.com/donald-trump86/dsh-bar-macos.git
cd dsh-bar-macos

# 2. 一键编译并安装到 /Applications
make install

# 3. 启动应用
open -a "DSH Bar"
```

### 方式二：直接编译运行（不安装）

```bash
make
open "build/DSH Bar.app"
```

---

## 📂 项目结构 / Project Structure

```text
dsh-bar-macos/
├── Sources/
│   ├── main.swift              # 程序入口
│   ├── AppDelegate.swift       # 菜单栏 UI (🐳 Emoji)、动态菜单项与状态控制器
│   ├── ServiceManager.swift    # 动态端口检测、生命周期管理与日志
│   ├── HotKeyManager.swift     # Carbon 原生无权限门槛全局热键管理
│   ├── SettingsManager.swift   # 自定义端口、开机启动 (SMAppService)、快捷键持久化
│   └── DashboardWindow.swift   # 原生毛玻璃悬浮控制中心、端口设置与快捷键录制面板
├── Resources/
│   ├── AppIcon.icns            # 1024x1024 原创全新 Retina 高清应用图标
│   └── icon.png                # 原创 DeepSeek 萌宠小鲸鱼 + 菜单栏设计图标
├── Info.plist                  # macOS Bundle 配置（LSUIElement 状态栏应用配置）
├── build.sh                    # 自动化编译、签名与打包脚本
├── Makefile                    # 极简 make 构建命令
├── LICENSE                     # MIT 开源许可证
└── README.md                   # 详尽中英文文档说明
```

---

## 📄 开源许可证 / License

本项目基于 [MIT License](LICENSE) 协议开源。
欢迎提 Issue 或 PR 一起完善！
