import Foundation

// MARK: - Language selection

/// Which language the UI is drawn in. `automatic` follows the system, which
/// means the first preferred language macOS would give this app.
enum AppLanguage: String, CaseIterable {
    case automatic
    case english
    case chinese

    /// Endonyms on purpose: a language picker should be readable to someone who
    /// cannot read the language currently selected.
    var displayName: String {
        switch self {
        case .automatic: return L(.languageAutomatic)
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }
}

// MARK: - Localization

/// Holds every user-facing string, in both languages, in one place.
///
/// Strings live in Swift rather than `.lproj` resources because the language is
/// chosen in-app: `Bundle.main` resolves against the *system* language, which
/// for this project's own author is `en-CN` even though they read Chinese, so
/// resource-based lookup could never reach the Chinese table. Keeping the table
/// typed also turns a mistyped key into a compile error.
final class Localization {
    static let shared = Localization()

    /// Every user-facing string in the app.
    enum Key: String, CaseIterable {
        // Generic
        case ok, cancel, copy, copied, done, close, reset, recheck, restartNow
        case recording, windowTitlePreferences
        case installEllipsis, checkingEllipsis, defaultButton, later

        // App identity
        case appName, appSubtitle

        // Sections
        case sectionLocalConsole, sectionPreferences

        // Service status
        case statusChecking, statusStarting, statusRunning, statusStopping
        case statusRestarting, statusStoppedWord, statusPortInUse, statusError
        case runningPort, serviceNotRunning, checkingServiceStatus, checkingServiceDetails
        case externalService, pidLabel, upLabel, dshVersionLabel

        // Buttons / menu items
        case openWeb, startService, stopService, stopExternal, stopExternalMenu
        case retryStart, restart, restartServiceMenu, adoptRestart, adoptRestartMenu
        case viewLiveLogs, viewLiveLogsMenu, preferencesMenu, copyWebURL
        case quit, quitAndStop

        // Tooltips
        case tipChecking, tipStopped, tipStarting, tipRunning
        case tipStopping, tipRestarting, tipError, tipPortInUse
        case menuDshDetecting, menuDshNotInstalled, menuDshPath

        // Preferences rows
        case serverPort, defaultPortLabel, globalShortcut, globalShortcutDesc
        case launchAtLogin, launchAtLoginDesc, automaticRecovery, automaticRecoveryDesc
        case notifications, notificationsDesc, dshCommandLine
        case language, languageDesc, languageAutomatic
        case searchingPath, detectingDsh, installedAt, notFoundInstallNpm

        // Port change dialog
        case portUpdatedTitle, portUpdatedBody

        // Alerts
        case couldNotStopService, couldNotStopExternal, couldNotStartService
        case couldNotRestartService, couldNotRestartExternal

        // ServiceManager: preflight and refusals
        case opInProgress
        case dshMissingLeftAlone, dshNotInstalled, installWith
        case nothingToStop, notStartedByUsCannotRestart, notStartedByUsWontStop
        case startedByUsUseNormal, notTheServiceAnymore

        // ServiceManager: port conditions
        case portAlreadyInUse, portServedByOther, portUsedByPID
        case portNowHeldByOther, portNowHeldByPID, portUsedByAnotherApp
        case portHeldNotHarness, portBusyLeftRunning

        // ServiceManager: stop outcomes
        case stillResponding, oldStillListening, externalStillListening
        case listenerNoLongerMatches, terminatedButStillServing
        case failedToStopService, failedToStopExisting, failedToStopExternal
        case launchFailed, serviceNotReady

        // ServiceManager: external stop refusals
        case processAlreadyGone, severalListeners, pidNotListener, pidNotHarness
        case pidBelongsToOtherUser, portChangedRestartToApply, portChangedAppliesLater

        // Recovery
        case stoppedUnexpectedly, recoveredAfterExit, keepsStopping, recoveryPaused
        case theService

        // Notifications
        case notifStoppedTitle, notifStoppedBody, notifRestartedTitle, notifRestartedBody
        case notifGaveUpTitle, notifGaveUpBody
        case notifAvailable, notifDenied, notifNotChecked, notifUnusable
        case notifActionSettings, notifActionEnable, notifActionFix

        // Log window
        case logsWindowTitle, logsTitle, logsFilter, logsClearView, logsRevealFile
        case logsWaiting, logsNoFileYet, logsClearedNotice, logsReadError
        case logsPause, logsResume, logsPaused

        // DSH install assistant
        case installTitle, installCopyCommand, installCopyAndOpenTerminal, installOpenNodeSite
        case installNpmMissingBody, installDshMissingBody

        // External service confirmation
        case extTitle, extStopButton, extStopExplain, extRestartExplain, extProcessLabel

        // Durations
        case durationDaysHours, durationHoursMinutes
    }

    // MARK: State

    private(set) var selected: AppLanguage = .automatic
    private(set) var effective: AppLanguage = .english

    private var observers: [UUID: () -> Void] = [:]

    private init() {
        apply(language: SettingsManager.shared.language, notify: false)
    }

    // MARK: Language resolution

    /// `automatic` resolves through the system preference list, first match wins.
    /// `en-CN` resolves to English even when Chinese is second, which is exactly
    /// why the picker offers an explicit override.
    static func resolve(_ language: AppLanguage) -> AppLanguage {
        guard language == .automatic else { return language }
        for tag in Locale.preferredLanguages {
            let lowered = tag.lowercased()
            if lowered.hasPrefix("zh") { return .chinese }
            if lowered.hasPrefix("en") { return .english }
        }
        return .english
    }

    func apply(language: AppLanguage, notify: Bool = true) {
        selected = language
        effective = Self.resolve(language)
        guard notify else { return }
        for observer in Array(observers.values) { observer() }
    }

    @discardableResult
    func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    // MARK: Lookup

    /// Looks up `key`, substituting `{name}` placeholders.
    ///
    /// Falls back to English, then to the key itself: a missing translation
    /// shows readable English rather than an opaque identifier.
    func string(_ key: Key, _ variables: [String: String] = [:]) -> String {
        let table = effective == .chinese ? Self.chinese : Self.english
        var text = table[key] ?? Self.english[key] ?? key.rawValue
        for (name, value) in variables {
            text = text.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return text
    }

    // MARK: Tables

    private static let english: [Key: String] = [
        // Generic
        .ok: "OK",
        .cancel: "Cancel",
        .copy: "Copy",
        .copied: "Copied!",
        .recording: "Recording…",
        .windowTitlePreferences: "Preferences",
        .done: "Done",
        .close: "Close",
        .reset: "Reset",
        .recheck: "Recheck",
        .restartNow: "Restart Now",
        .installEllipsis: "Install…",
        .checkingEllipsis: "Checking…",
        .defaultButton: "Default",
        .later: "Later",

        // App identity
        .appName: "DeepSeek Harness",
        .appSubtitle: "Menu Bar Companion  •  {version}",

        // Sections
        .sectionLocalConsole: "LOCAL WEB CONSOLE",
        .sectionPreferences: "PREFERENCES & CONFIGURATION",

        // Service status
        .statusChecking: "CHECKING",
        .statusStarting: "STARTING",
        .statusRunning: "RUNNING",
        .statusStopping: "STOPPING",
        .statusRestarting: "RESTARTING",
        .statusStoppedWord: "STOPPED",
        .statusPortInUse: "PORT IN USE",
        .statusError: "ERROR",
        .runningPort: "RUNNING : {port}",
        .serviceNotRunning: "Service is not running",
        .checkingServiceStatus: "Checking service status…",
        .checkingServiceDetails: "Checking service details…",
        .externalService: "External DeepSeek Harness service",
        .pidLabel: "PID {pid}",
        .upLabel: "Up {duration}",
        .dshVersionLabel: "DSH {version}",

        // Buttons / menu items
        .openWeb: "Open Web",
        .startService: "Start Service",
        .stopService: "Stop Service",
        .stopExternal: "Stop External…",
        .stopExternalMenu: "Stop External Service…",
        .retryStart: "Retry Start",
        .restart: "Restart",
        .restartServiceMenu: "Restart Service",
        .adoptRestart: "Adopt & Restart",
        .adoptRestartMenu: "Adopt & Restart Service…",
        .viewLiveLogs: "View Live Logs",
        .viewLiveLogsMenu: "View Live Logs…",
        .preferencesMenu: "Preferences…",
        .copyWebURL: "Copy Web URL",
        .quit: "Quit DSH Bar",
        .quitAndStop: "Quit & Stop Service…",

        // Tooltips
        .tipChecking: "Checking DeepSeek Harness…",
        .tipStopped: "DeepSeek Harness: Stopped ({port})",
        .tipStarting: "DeepSeek Harness: Starting…",
        .tipRunning: "DeepSeek Harness: Running ({port})",
        .tipStopping: "DeepSeek Harness: Stopping…",
        .tipRestarting: "DeepSeek Harness: Restarting…",
        .tipError: "DeepSeek Harness: Error",
        .tipPortInUse: "Port {port} Is in Use",
        .menuDshDetecting: "DSH CLI: detecting…",
        .menuDshNotInstalled: "DSH CLI: not installed",
        .menuDshPath: "DSH: {path}",

        // Preferences rows
        .serverPort: "Server Port",
        .defaultPortLabel: "Default: {port}",
        .globalShortcut: "Global Shortcut",
        .globalShortcutDesc: "Open the Web console from anywhere",
        .launchAtLogin: "Launch at Login",
        .launchAtLoginDesc: "Start quietly in the menu bar; keep the Web console closed",
        .automaticRecovery: "Automatic Recovery",
        .automaticRecoveryDesc: "Restart a service DSH Bar started if it exits unexpectedly",
        .notifications: "Notifications",
        .notificationsDesc: "Used to tell you when the service dies",
        .dshCommandLine: "DSH Command Line",
        .language: "Language",
        .languageDesc: "Applies immediately, no restart needed",
        .languageAutomatic: "Automatic",
        .searchingPath: "Searching PATH with which dsh…",
        .detectingDsh: "Detecting DSH CLI…",
        .installedAt: "Installed: {path}{version}",
        .notFoundInstallNpm: "Not found — install with npm to start the service",

        // Port change dialog
        .portUpdatedTitle: "Port Updated to {port}",
        .portUpdatedBody: "The server is currently running. Would you like to restart the service on the new port now?",

        // Alerts
        .couldNotStopService: "Could Not Stop the Service",
        .couldNotStopExternal: "Could Not Stop the External Service",
        .couldNotStartService: "Could Not Start the Service",
        .couldNotRestartService: "Could Not Restart the Service",
        .couldNotRestartExternal: "Could Not Restart the External Service",

        // ServiceManager: preflight and refusals
        .opInProgress: "A service operation is already in progress.",
        .dshMissingLeftAlone: "DeepSeek Harness CLI could not be found, so the running service was left untouched. Install it with: {command}",
        .dshNotInstalled: "DeepSeek Harness CLI is not installed. Install it with: {command}",
        .installWith: "Install it with: {command}",
        .nothingToStop: "DeepSeek Harness is not running, so there is nothing to stop.",
        .notStartedByUsCannotRestart: "This service was not started by DSH Bar, so it cannot be restarted safely.",
        .notStartedByUsWontStop: "This service was not started by DSH Bar, so it will not be stopped.",
        .startedByUsUseNormal: "This service was started by DSH Bar, so use the normal Stop and Restart actions.",
        .notTheServiceAnymore: "That process is no longer the service on this port. Refresh and try again.",

        // ServiceManager: port conditions
        .portAlreadyInUse: "Port {port} is already in use.",
        .portServedByOther: "Port {port} is already served by a different DeepSeek Harness process.",
        .portUsedByPID: "Port {port} is used by PID {pid}.",
        .portNowHeldByOther: "Port {port} is now held by another process.",
        .portNowHeldByPID: "Port {port} is now held by PID {pid}.",
        .portUsedByAnotherApp: "Port {port} is used by another application. Nothing was stopped.",
        .portHeldNotHarness: "Port {port} is held by a process that does not answer as DeepSeek Harness, so it was left alone.",
        .portBusyLeftRunning: "Port {port} is already in use. The service is still running on port {current}.",

        // ServiceManager: stop outcomes
        .stillResponding: "The DeepSeek Harness service is still responding on port {port}.",
        .oldStillListening: "The old service is still listening on port {port}; restart was cancelled.",
        .externalStillListening: "The external service is still listening on port {port}; restart was cancelled.",
        .listenerNoLongerMatches: "The listener on port {port} no longer matches the service started by DSH Bar.",
        .terminatedButStillServing: "The process was terminated but port {port} is still serving DeepSeek Harness.",
        .failedToStopService: "Failed to stop the service.",
        .failedToStopExisting: "Failed to stop the existing service.",
        .failedToStopExternal: "Failed to stop the external service.",
        .launchFailed: "Failed to launch DSH: {reason}",
        .serviceNotReady: "Service did not become ready on port {port}. Check the live logs for details.",

        // ServiceManager: external stop refusals
        .processAlreadyGone: "The process was already gone.",
        .severalListeners: "Several processes listen on port {port}, so nothing was stopped.",
        .pidNotListener: "PID {pid} no longer listens on port {port}. Nothing was stopped.",
        .pidNotHarness: "PID {pid} does not answer as DeepSeek Harness, so it was left alone.",
        .pidBelongsToOtherUser: "PID {pid} belongs to another user or a protected process.",
        .portChangedRestartToApply: "Configured port changed to {port}. Restart to apply it.",
        .portChangedAppliesLater: "Configured port changed to {port}. It will apply after the current operation.",

        // Recovery
        .stoppedUnexpectedly: "DeepSeek Harness stopped unexpectedly ({who} on port {port}).",
        .recoveredAfterExit: "Recovered after an unexpected exit at {time}",
        .keepsStopping: "DeepSeek Harness keeps stopping and was not restarted again ({attempts} attempts in {minutes} minutes).",
        .recoveryPaused: "Kept stopping, so automatic restarts were paused — start it manually to retry",
        .theService: "The service",

        // Notifications
        .notifStoppedTitle: "DeepSeek Harness stopped unexpectedly",
        .notifStoppedBody: "{who} on port {port} is no longer running.",
        .notifRestartedTitle: "DeepSeek Harness was restarted",
        .notifRestartedBody: "DSH Bar brought the service back automatically (attempt {attempt}).",
        .notifGaveUpTitle: "DeepSeek Harness keeps stopping",
        .notifGaveUpBody: "Automatic restarts were paused to avoid a loop. Start it manually to try again.",
        .notifAvailable: "On",
        .notifDenied: "Turned off in System Settings",
        .notifNotChecked: "Not checked yet",
        .notifUnusable: "Needs the installed app (not a bare binary)",
        .notifActionSettings: "Settings…",
        .notifActionEnable: "Enable…",
        .notifActionFix: "Fix…",

        // Log window
        .logsWindowTitle: "DSH Live Logs",
        .logsTitle: "Live Service Logs",
        .logsFilter: "Filter logs",
        .logsClearView: "Clear View",
        .logsRevealFile: "Reveal File",
        .logsWaiting: "Waiting for logs…",
        .logsNoFileYet: "No log file yet — it will appear after the service starts.",
        .logsClearedNotice: "View cleared — the log file was not deleted.",
        .logsReadError: "Could not read {path}",
        .logsPause: "Pause",
        .logsResume: "Resume",
        .logsPaused: "Paused",

        // DSH install assistant
        .installTitle: "DeepSeek Harness CLI Is Not Installed",
        .installCopyCommand: "Copy Command",
        .installCopyAndOpenTerminal: "Copy Command & Open Terminal",
        .installOpenNodeSite: "Open Node.js Website",
        .installNpmMissingBody: "DSH Bar could not find either ‘dsh’ or ‘npm’. Install Node.js/npm first, then run:\n\n{command}",
        .installDshMissingBody: "DSH Bar could not find the ‘dsh’ command. The official npm installation command is:\n\n{command}\n\nThe command can be copied and Terminal opened for you.",

        // External service confirmation
        .extTitle: "DeepSeek Harness Was Started Outside DSH Bar",
        .extStopButton: "Stop Process",
        .extStopExplain: "DSH Bar did not start it, so stopping it terminates that process. Your terminal will report the server as stopped.",
        .extRestartExplain: "DSH Bar will stop that process and start the service itself, so Stop and Restart work normally from now on.",
        .extProcessLabel: "Process: {command}",

        // Durations
        .durationDaysHours: "{days}d {hours}h",
        .durationHoursMinutes: "{hours}h {minutes}m"
    ]

    private static let chinese: [Key: String] = [
        // Generic
        .ok: "好",
        .cancel: "取消",
        .copy: "复制",
        .copied: "已复制！",
        .recording: "录制中…",
        .windowTitlePreferences: "偏好设置",
        .done: "完成",
        .close: "关闭",
        .reset: "恢复默认",
        .recheck: "重新检测",
        .restartNow: "立即重启",
        .installEllipsis: "安装…",
        .checkingEllipsis: "检测中…",
        .defaultButton: "默认",
        .later: "稍后",

        // App identity
        .appName: "DeepSeek Harness",
        .appSubtitle: "菜单栏伴侣  •  {version}",

        // Sections
        .sectionLocalConsole: "本地 Web 控制台",
        .sectionPreferences: "偏好设置",

        // Service status
        .statusChecking: "检查中",
        .statusStarting: "启动中",
        .statusRunning: "运行中",
        .statusStopping: "停止中",
        .statusRestarting: "重启中",
        .statusStoppedWord: "已停止",
        .statusPortInUse: "端口被占用",
        .statusError: "错误",
        .runningPort: "运行中 : {port}",
        .serviceNotRunning: "服务未运行",
        .checkingServiceStatus: "正在检查服务状态…",
        .checkingServiceDetails: "正在检查服务详情…",
        .externalService: "外部启动的 DeepSeek Harness 服务",
        .pidLabel: "PID {pid}",
        .upLabel: "已运行 {duration}",
        .dshVersionLabel: "DSH {version}",

        // Buttons / menu items
        .openWeb: "打开 Web",
        .startService: "启动服务",
        .stopService: "停止服务",
        .stopExternal: "停止外部服务…",
        .stopExternalMenu: "停止外部服务…",
        .retryStart: "重试启动",
        .restart: "重启",
        .restartServiceMenu: "重启服务",
        .adoptRestart: "接管并重启",
        .adoptRestartMenu: "接管并重启服务…",
        .viewLiveLogs: "查看实时日志",
        .viewLiveLogsMenu: "查看实时日志…",
        .preferencesMenu: "偏好设置…",
        .copyWebURL: "复制 Web 地址",
        .quit: "退出 DSH Bar",
        .quitAndStop: "退出并停止服务…",

        // Tooltips
        .tipChecking: "正在检查 DeepSeek Harness…",
        .tipStopped: "DeepSeek Harness：已停止（{port}）",
        .tipStarting: "DeepSeek Harness：启动中…",
        .tipRunning: "DeepSeek Harness：运行中（{port}）",
        .tipStopping: "DeepSeek Harness：停止中…",
        .tipRestarting: "DeepSeek Harness：重启中…",
        .tipError: "DeepSeek Harness：错误",
        .tipPortInUse: "端口 {port} 已被占用",
        .menuDshDetecting: "DSH CLI：检测中…",
        .menuDshNotInstalled: "DSH CLI：未安装",
        .menuDshPath: "DSH：{path}",

        // Preferences rows
        .serverPort: "服务端口",
        .defaultPortLabel: "默认：{port}",
        .globalShortcut: "全局快捷键",
        .globalShortcutDesc: "在任何软件中打开 Web 控制台",
        .launchAtLogin: "登录时启动",
        .launchAtLoginDesc: "安静地启动到菜单栏，不打开 Web 控制台",
        .automaticRecovery: "自动恢复",
        .automaticRecoveryDesc: "DSH Bar 启动的服务意外退出时自动重启",
        .notifications: "通知",
        .notificationsDesc: "用于在服务异常退出时提醒你",
        .dshCommandLine: "DSH 命令行",
        .language: "语言",
        .languageDesc: "立即生效，无需重启",
        .languageAutomatic: "自动",
        .searchingPath: "正在通过 which dsh 搜索 PATH…",
        .detectingDsh: "正在检测 DSH CLI…",
        .installedAt: "已安装：{path}{version}",
        .notFoundInstallNpm: "未找到 — 需用 npm 安装后才能启动服务",

        // Port change dialog
        .portUpdatedTitle: "端口已改为 {port}",
        .portUpdatedBody: "服务当前正在运行。要现在在新端口上重启服务吗？",

        // Alerts
        .couldNotStopService: "无法停止服务",
        .couldNotStopExternal: "无法停止外部服务",
        .couldNotStartService: "无法启动服务",
        .couldNotRestartService: "无法重启服务",
        .couldNotRestartExternal: "无法重启外部服务",

        // ServiceManager: preflight and refusals
        .opInProgress: "已有服务操作正在进行中。",
        .dshMissingLeftAlone: "找不到 DeepSeek Harness CLI，因此没有动正在运行的服务。请先安装：{command}",
        .dshNotInstalled: "DeepSeek Harness CLI 尚未安装。请先安装：{command}",
        .installWith: "请先安装：{command}",
        .nothingToStop: "DeepSeek Harness 未在运行，无需停止。",
        .notStartedByUsCannotRestart: "该服务不是 DSH Bar 启动的，无法安全重启。",
        .notStartedByUsWontStop: "该服务不是 DSH Bar 启动的，不会被停止。",
        .startedByUsUseNormal: "该服务由 DSH Bar 启动，请使用常规的停止与重启操作。",
        .notTheServiceAnymore: "该进程已不再是此端口上的服务。请刷新后重试。",

        // ServiceManager: port conditions
        .portAlreadyInUse: "端口 {port} 已被占用。",
        .portServedByOther: "端口 {port} 已由另一个 DeepSeek Harness 进程提供服务。",
        .portUsedByPID: "端口 {port} 正被 PID {pid} 使用。",
        .portNowHeldByOther: "端口 {port} 现已被另一个进程占用。",
        .portNowHeldByPID: "端口 {port} 现已被 PID {pid} 占用。",
        .portUsedByAnotherApp: "端口 {port} 被其他应用占用，未停止任何进程。",
        .portHeldNotHarness: "端口 {port} 被一个不响应 DeepSeek Harness 的进程占用，因此未做处理。",
        .portBusyLeftRunning: "端口 {port} 已被占用。服务仍在端口 {current} 上运行。",

        // ServiceManager: stop outcomes
        .stillResponding: "DeepSeek Harness 服务仍在端口 {port} 上响应。",
        .oldStillListening: "旧服务仍在端口 {port} 上监听，重启已取消。",
        .externalStillListening: "外部服务仍在端口 {port} 上监听，重启已取消。",
        .listenerNoLongerMatches: "端口 {port} 上的监听者已不再是 DSH Bar 启动的那个服务。",
        .terminatedButStillServing: "进程已终止，但端口 {port} 仍在提供 DeepSeek Harness 服务。",
        .failedToStopService: "停止服务失败。",
        .failedToStopExisting: "停止原有服务失败。",
        .failedToStopExternal: "停止外部服务失败。",
        .launchFailed: "启动 DSH 失败：{reason}",
        .serviceNotReady: "服务未能在端口 {port} 上就绪。请查看实时日志。",

        // ServiceManager: external stop refusals
        .processAlreadyGone: "该进程已经不存在了。",
        .severalListeners: "有多个进程在端口 {port} 上监听，因此未停止任何进程。",
        .pidNotListener: "PID {pid} 已不在端口 {port} 上监听，未停止任何进程。",
        .pidNotHarness: "PID {pid} 不响应 DeepSeek Harness，因此未做处理。",
        .pidBelongsToOtherUser: "PID {pid} 属于其他用户或受保护的进程。",
        .portChangedRestartToApply: "端口已改为 {port}。重启后生效。",
        .portChangedAppliesLater: "端口已改为 {port}。将在当前操作完成后生效。",

        // Recovery
        .stoppedUnexpectedly: "DeepSeek Harness 意外停止了（{who}，端口 {port}）。",
        .recoveredAfterExit: "已在 {time} 意外退出后自动恢复",
        .keepsStopping: "DeepSeek Harness 反复停止，已不再自动重启（{minutes} 分钟内尝试了 {attempts} 次）。",
        .recoveryPaused: "反复停止，已暂停自动重启 — 请手动启动以重试",
        .theService: "服务",

        // Notifications
        .notifStoppedTitle: "DeepSeek Harness 意外停止",
        .notifStoppedBody: "{who}（端口 {port}）已不再运行。",
        .notifRestartedTitle: "DeepSeek Harness 已重启",
        .notifRestartedBody: "DSH Bar 已自动把服务拉回（第 {attempt} 次尝试）。",
        .notifGaveUpTitle: "DeepSeek Harness 反复停止",
        .notifGaveUpBody: "为避免无限重启循环，已暂停自动重启。请手动启动以重试。",
        .notifAvailable: "已开启",
        .notifDenied: "已在系统设置中关闭",
        .notifNotChecked: "尚未检查",
        .notifUnusable: "需要安装后的应用（裸二进制不可用）",
        .notifActionSettings: "设置…",
        .notifActionEnable: "启用…",
        .notifActionFix: "修复…",

        // Log window
        .logsWindowTitle: "DSH 实时日志",
        .logsTitle: "服务实时日志",
        .logsFilter: "筛选日志",
        .logsClearView: "清空视图",
        .logsRevealFile: "在访达中显示",
        .logsWaiting: "等待日志…",
        .logsNoFileYet: "暂无日志文件 — 服务启动后会出现。",
        .logsClearedNotice: "视图已清空 — 日志文件未被删除。",
        .logsReadError: "无法读取 {path}",
        .logsPause: "暂停",
        .logsResume: "继续",
        .logsPaused: "已暂停",

        // DSH install assistant
        .installTitle: "DeepSeek Harness CLI 尚未安装",
        .installCopyCommand: "复制命令",
        .installCopyAndOpenTerminal: "复制命令并打开终端",
        .installOpenNodeSite: "打开 Node.js 官网",
        .installNpmMissingBody: "DSH Bar 既没找到 ‘dsh’ 也没找到 ‘npm’。请先安装 Node.js/npm，然后运行：\n\n{command}",
        .installDshMissingBody: "DSH Bar 没有找到 ‘dsh’ 命令。官方 npm 安装命令是：\n\n{command}\n\n可以为你复制该命令并打开终端。",

        // External service confirmation
        .extTitle: "该 DeepSeek Harness 由 DSH Bar 之外启动",
        .extStopButton: "结束进程",
        .extStopExplain: "DSH Bar 没有启动它，结束它会终止该进程。你的终端会显示服务已停止。",
        .extRestartExplain: "DSH Bar 会结束该进程并由自己重新启动服务，此后停止与重启都会正常工作。",
        .extProcessLabel: "进程：{command}",

        // Durations
        .durationDaysHours: "{days} 天 {hours} 小时",
        .durationHoursMinutes: "{hours} 小时 {minutes} 分"
    ]
}

/// Shorthand for the current language's string. Keeps call sites readable and
/// makes every user-facing string greppable as `L(.someKey)`.
func L(_ key: Localization.Key, _ variables: [String: String] = [:]) -> String {
    Localization.shared.string(key, variables)
}
