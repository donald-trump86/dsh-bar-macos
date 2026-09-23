import Cocoa
import UserNotifications

/// Delivers the notifications DSH Bar relies on to tell the user that a service
/// it started has died.
///
/// Notifications are treated as a *bonus* channel, never the only one. macOS
/// ties notification authorization to the code signature, and an ad-hoc signed
/// build gets a new signature on every rebuild, so authorization can be lost
/// without any visible error. Whenever delivery is impossible this class says
/// so through `availability`, and the panel falls back to showing the condition
/// itself instead of staying silent.
final class ServiceNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ServiceNotifier()

    enum Availability: Equatable {
        /// Not asked yet.
        case unknown
        case available
        case denied
        /// The API cannot be used at all (for example when the sources are run
        /// as a bare binary with no bundle identifier), or delivery failed.
        case unusable(String)

        var isUsable: Bool { self == .available }

        var shortDescription: String {
            switch self {
            case .unknown: return L(.notifNotChecked)
            case .available: return L(.notifAvailable)
            case .denied: return L(.notifDenied)
            case let .unusable(reason): return reason
            }
        }
    }

    private(set) var availability: Availability = .unknown {
        didSet {
            guard availability != oldValue else { return }
            DispatchQueue.main.async { self.notifyObservers() }
        }
    }

    // Multiple components care about this (menu bar and preferences panel). A
    // single callback slot would let one silently overwrite the other, which is
    // the same bug the service status observers were split up to avoid.
    private var observers: [UUID: () -> Void] = [:]

    @discardableResult
    func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        DispatchQueue.main.async { observer() }
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    private func notifyObservers() {
        for observer in Array(observers.values) {
            observer()
        }
    }

    private var hasRequestedAuthorization = false

    /// `UNUserNotificationCenter.current()` must only be touched by a real app
    /// bundle. Without a bundle identifier the whole notification stack is
    /// meaningless, so every call site goes through here.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    private override init() {
        super.init()
    }

    /// Installs the delegate so banners still appear while the panel is open.
    func activate() {
        guard let center else { return }
        center.delegate = self
    }

    // MARK: - Authorization

    /// Requests permission the first time a service is started, which is the
    /// moment the feature becomes relevant. Asking on launch instead would
    /// prompt users who never start a service.
    func requestAuthorizationIfNeeded(completion: (() -> Void)? = nil) {
        guard let center else {
            availability = .unusable(L(.notifUnusable))
            completion?()
            return
        }
        guard !hasRequestedAuthorization else {
            refreshAvailability(completion: completion)
            return
        }
        hasRequestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard let self else { return }
            if let error {
                self.availability = .unusable(error.localizedDescription)
            } else {
                self.availability = granted ? .available : .denied
            }
            self.refreshAvailability(completion: completion)
        }
    }

    func refreshAvailability(completion: (() -> Void)? = nil) {
        guard let center else {
            availability = .unusable(L(.notifUnusable))
            completion?()
            return
        }
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.availability = .available
            case .denied:
                self.availability = .denied
            case .notDetermined:
                self.availability = .unknown
            default:
                self.availability = .denied
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Opens the exact System Settings pane where notifications are granted.
    func openSystemNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Delivery

    func notifyUnexpectedExit(pid: Int32?, port: Int) {
        let who = pid.map { L(.pidLabel, ["pid": "\($0)"]) } ?? L(.theService)
        post(
            identifier: "dsh-bar.unexpected-exit",
            title: L(.notifStoppedTitle),
            body: L(.notifStoppedBody, ["who": who, "port": "\(port)"])
        )
    }

    func notifyAutoRestarted(attempt: Int) {
        post(
            identifier: "dsh-bar.auto-restarted",
            title: L(.notifRestartedTitle),
            body: L(.notifRestartedBody, ["attempt": "\(attempt)"])
        )
    }

    func notifyGaveUp() {
        post(
            identifier: "dsh-bar.recovery-gave-up",
            title: L(.notifGaveUpTitle),
            body: L(.notifGaveUpBody)
        )
    }

    private func post(identifier: String, title: String, body: String) {
        guard let center else {
            availability = .unusable(L(.notifUnusable))
            return
        }
        guard availability.isUsable else {
            // Authorization is missing. The caller has already surfaced the
            // condition in the panel, so there is nothing more to do here than
            // make sure the user can see why nothing popped up.
            refreshAvailability()
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Group crash reports so a flapping service does not fill the list.
        content.threadIdentifier = identifier

        let request = UNNotificationRequest(
            identifier: "\(identifier).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { [weak self] error in
            guard let self, let error else { return }
            self.availability = .unusable(error.localizedDescription)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The app is an accessory with no always-visible window, so a banner is
        // the whole point even when the panel happens to be open.
        completionHandler([.banner, .sound])
    }
}
