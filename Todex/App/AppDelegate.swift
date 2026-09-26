import UIKit
import UserNotifications

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool { true }
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?
    private let session = AppSession()
    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let home = HomeViewController(session: self.session)
        let navigation = UINavigationController(rootViewController: home)
        window.rootViewController = navigation
        self.window = window
        Theme.applyAppearance(to: window)
        window.makeKeyAndVisible()
        UNUserNotificationCenter.current().delegate = self
        if self.session.connection != nil { Task { await self.session.connect() } }
        if let response = connectionOptions.notificationResponse {
            routeNotificationResponse(response)
        }
    }
    /// Completion alerts also fire in the foreground for conversations that are
    /// not on screen; show them as banners instead of dropping them silently.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
    /// Tapping a completion alert opens the conversation it refers to.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        routeNotificationResponse(response)
        completionHandler()
    }
    private func routeNotificationResponse(_ response: UNNotificationResponse) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let id = response.notification.request.content
                .userInfo[CompletionNotifications.conversationIdKey] as? String,
            !id.isEmpty,
            let navigation = window?.rootViewController as? UINavigationController,
            let home = navigation.viewControllers.first as? HomeViewController
        else { return }
        navigation.dismiss(animated: false)
        navigation.popToRootViewController(animated: false)
        home.openConversation(id: id)
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        session.setForeground(true)
        Theme.applyAppearance(to: window)
    }
    func sceneWillResignActive(_ scene: UIScene) { session.persist() }
    func sceneDidEnterBackground(_ scene: UIScene) { session.setForeground(false) }
    func sceneDidDisconnect(_ scene: UIScene) { session.disconnect() }
}
