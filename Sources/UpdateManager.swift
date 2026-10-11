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
final class UpdateManager: NSObject, NSMenuItemValidation {
    static let shared = UpdateManager()

    let controller: SPUStandardUpdaterController

    private override init() {
        // startingUpdater: true — SPUStandardUpdaterController schedules the
        // background checks itself from the Info.plist SU* settings.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
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
        controller.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        canCheckForUpdates
    }
}
