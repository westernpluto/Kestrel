// Starting from a blank slate.
//
// Deleting an app on iOS removes its settings and files, but not what it saved in the Keychain:
// iOS keeps Keychain items after an app is deleted, which is why a reinstalled Kestrel came back
// signed in to Twitch. Now a reinstall clears what the Keychain kept from before, and Settings →
// Reset Kestrel erases everything at any time.

import BackgroundTasks
import Foundation
import UIKit
import UserNotifications
import WebKit

enum AppReset {
  /// Set once Kestrel has run on this install (settings are wiped with the app, so a missing
  /// marker with no other settings means a fresh install).
  private static let marker = "kestrel.installed"

  /// Runs first thing at launch: on a fresh install, the Keychain's leftovers from an earlier
  /// install (the Twitch login, the proxy password) are removed.
  static func clearLeftoversAfterReinstall() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: marker) else { return }
    let stored = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
    // Settings already there: an update of an install from before this marker existed, not a
    // reinstall. Keep the login.
    if stored.isEmpty { SecretStore.removeAll() }
    defaults.set(true, forKey: marker)
  }

  /// Erases everything Kestrel has stored: the Twitch login and the website's cookies, follows
  /// and favorites, watch progress, search history, settings, caches, alerts.
  @MainActor
  static func eraseEverything() async {
    AppModel.shared.playing = nil
    SecretStore.removeAll()
    TwitchAuth.shared.update(nil)

    let store = WKWebsiteDataStore.default()
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { done.resume() }
    }
    HTTPCookieStorage.shared.removeCookies(since: .distantPast)
    URLCache.shared.removeAllCachedResponses()
    ImagePipeline.shared.clear()

    let notifications = UNUserNotificationCenter.current()
    notifications.removeAllPendingNotificationRequests()
    notifications.removeAllDeliveredNotifications()
    BGTaskScheduler.shared.cancelAllTaskRequests()

    if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
    UserDefaults.standard.set(true, forKey: marker)
    UserDefaults.standard.synchronize()

    // Files: caches, saved data, temporary files.
    let manager = FileManager.default
    var folders = [manager.temporaryDirectory]
    for directory in [FileManager.SearchPathDirectory.cachesDirectory, .applicationSupportDirectory, .documentDirectory] {
      folders += manager.urls(for: directory, in: .userDomainMask)
    }
    for folder in folders {
      for item in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
        try? manager.removeItem(at: item)
      }
    }
    ActivityLog.shared.add("Kestrel was reset")
  }
}
