# DSH Bar (macOS) 🐋

<p align="center">
  <img src="Resources/icon.png" width="128" height="128" alt="DSH Bar Icon">
</p>

<p align="center">
  <b>A native, ultra-lightweight macOS menu bar companion and quick launcher for DeepSeek Harness.</b><br>
  专为 DeepSeek Harness 打造的原生极简 macOS 菜单栏状态助手与快捷启动器。
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#prerequisites">Prerequisites</a> •
  <a href="#installation">Installation</a> •
  <a href="#keyboard-shortcuts">Shortcuts</a> •
  <a href="#license">License</a>
</p>

---

## 💡 为什么选择 DSH Bar？ / Why DSH Bar?

如果你已经在终端中通过 `dsh web` 使用 DeepSeek Harness，每次查看服务是否在跑、停止后台进程、重启服务往往需要反复切换终端敲 `lsof` 或 `kill` 命令。

市面上现有的 Launcher 多为基于 Electron / Tauri 的独立大窗口重型套件（内嵌各种独立运行时与依赖，体积与内存消耗上百兆）。

**DSH Bar 坚持极客、轻量与无感伴随的理念**：
- **纯原生 Swift 构建**：无第三方依赖，纯二进制仅约 **150 KB**，冷启动 <0.1 秒，运行时内存占用仅 **~15 MB**。
- **隐形常驻**：常驻顶部菜单栏，不占用 Dock 栏位置，不打扰日常工作。
- **键盘优先**：支持菜单快捷键与系统全局热键，随时随地一键唤起。

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

- **操作系统支持**：macOS 13.0 (Ventura) 及更高版本（支持 Apple Silicon M1/M2/M3/M4 及 Intel 芯片）。

---

## ✨ 核心特性 / Features

- 🟢 **实时状态感知**：状态栏实时轮询监测 `http://127.0.0.1:3080` 服务健康状态（绿色在线 / 灰色已停止）。
- 🚀 **一键启停与平滑重启**：无缝拉起后台守护进程，支持一键重启，日志自动归档至 `~/.dsh/logs/dsh-web.log`。
- 🌐 **瞬间直达**：点击或快捷键即可直接在系统默认浏览器中打开/聚焦 Harness 界面。
- 🪟 **原生毛玻璃控制面板**：按 `⌘D` 弹出 HUD 悬浮卡片，支持一键复制本地地址、查看状态与日志。
- ⌨️ **全局盲操热键**：在任何软件下按下全局热键，立即后台启动并拉起浏览器。

---

## ⌨️ 快捷键速查 / Shortcuts

### 全局系统热键（任何软件处于前台均有效）
| 快捷键 | 动作 | 说明 |
| :--- | :--- | :--- |
| **`⌥ + ⇧ + D`**<br>(Option + Shift + D) | **一键直达 DSH Web** | 若服务未启动则后台拉起并打开浏览器；若已在运行则直接前置浏览器 |
| **`⌥ + ⇧ + H`**<br>(Option + Shift + H) | **唤出控制面板** | 弹出原生悬浮卡片窗口 |

### 菜单栏 / 面板内快捷键
| 快捷键 | 动作 |
| :--- | :--- |
| **`⌘ + O`** | 在默认浏览器中打开 Web 控制台 |
| **`⌘ + S`** | 启动 / 停止后台 Harness 服务 |
| **`⌘ + R`** | 重启 Harness 服务 |
| **`⇧ + ⌘ + C`** | 复制 Web 地址 (`http://127.0.0.1:3080`) 到剪贴板 |
| **`⌘ + D`** | 展开详细控制中心面板 |
| **`⌘ + L`** | 查看实时运行日志 |
| **`Esc` / `⌘ + W`** | 关闭控制中心面板（应用仍在后台静默常驻） |
| **`⌘ + Q`** | 退出 DSH Bar 菜单栏应用 |

---

## 🛠 安装与构建 / Installation & Build

### 方式一：源码编译与安装（推荐）

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

你也可以直接运行脚本：
```bash
./build.sh install
```

### 方式二：直接运行

如无需安装到系统 `/Applications`，可在编译后直接运行：
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
│   ├── AppDelegate.swift       # 菜单栏 UI、菜单项、状态栏控制器
│   ├── ServiceManager.swift    # Harness 服务检测、生命周期管理与日志
│   ├── HotKeyManager.swift     # Carbon 原生无权限门槛全局热键管理
│   └── DashboardWindow.swift   # 原生毛玻璃悬浮控制中心面板
├── Resources/
│   ├── AppIcon.icns            # 1024x1024 Retina 高清应用图标
│   ├── icon.png                # DeepSeek 原生图标
│   ├── MenuBarIcon.png         # 18x18 菜单栏状态图标
│   └── MenuBarIcon@2x.png      # 36x36 Retina 菜单栏状态图标
├── Info.plist                  # macOS Bundle 配置（LSUIElement 状态栏应用配置）
├── build.sh                    # 自动化编译、签名与打包脚本
├── Makefile                    # 极简 make 构建命令
├── LICENSE                     # MIT 开源许可证
└── README.md                   # 项目说明文档
```

---

## 📄 开源许可证 / License

本项目基于 [MIT License](LICENSE) 协议开源。
欢迎提 Issue 或 PR 一起完善！
