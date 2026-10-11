//
//  UpdateManager.swift
//  DSHBar
//
//  Thin owner of Sparkle's standard updater. UI code goes through this
//  wrapper and never touches framework types, so a future framework swap
//  stays contained to one file.
//

import Cocoa
import Sparkle

@MainActor
final class UpdateManager: NSObject, NSMenuItemValidation, SPUUpdaterDelegate {
    static let shared = UpdateManager()

    // Lazy construction permits self as delegate after NSObject initialization.
    private(set) lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private override init() {
        super.init()
    }

    /// Drives the enabled state of the "Check for Updates…" menu item.
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    /// Read by the preferences row on load; written only when the user
    /// toggles the checkbox, per Sparkle's settings guidance.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(sender)
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate update: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard ServiceManager.shared.snapshot.phase.isBusy else { return false }
        ServiceManager.shared.performWhenLifecycleIdle(installHandler)
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        canCheckForUpdates
    }
}
