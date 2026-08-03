import SwiftUI
import UIKit
import UserNotifications

final class SolaceAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct SolaceApp: App {
    @UIApplicationDelegateAdaptor(SolaceAppDelegate.self) private var appDelegate
    var body: some Scene { WindowGroup { ContentView() } }
}
