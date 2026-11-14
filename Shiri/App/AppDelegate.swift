import UIKit
import CloudKit
import UserNotifications
import ShiriCore

@MainActor
final class AppInvitationRouter {
    static let shared = AppInvitationRouter()
    var onInvitation: ((CKShare.Metadata) -> Void)?
    var pending: CKShare.Metadata?
    func receive(_ metadata: CKShare.Metadata) { if let onInvitation { onInvitation(metadata) } else { pending = metadata } }
}
@MainActor
final class AppNotificationRouter {
    static let shared = AppNotificationRouter()
    var onResponse: ((UNNotificationResponse) async -> Void)?
    var pending: UNNotificationResponse?
}
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationAdapter.registerActions()
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completion: @escaping () -> Void) {
        Task { @MainActor in
            if let handler = AppNotificationRouter.shared.onResponse { await handler(response) }
            else if ["COMPLETE", "SNOOZE", "STOP"].contains(response.actionIdentifier) {
                do { try await SystemActionHandler.handle(response) }
                catch { if let repo = try? await ExtensionStore.open(author: "NotificationError") { try? await repo.setDeviceValue(error.localizedDescription, key: "pending-action-error") } }
            } else { AppNotificationRouter.shared.pending = response }
            completion()
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) { completion([.banner, .sound, .list]) }

    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) { AppInvitationRouter.shared.receive(cloudKitShareMetadata) }
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ShiriSceneDelegate.self; return configuration
    }
}
final class ShiriSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) { if let metadata = connectionOptions.cloudKitShareMetadata { AppInvitationRouter.shared.receive(metadata) } }
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) { AppInvitationRouter.shared.receive(cloudKitShareMetadata) }
}
