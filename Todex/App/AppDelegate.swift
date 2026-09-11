import UIKit

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

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
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
        if self.session.connection != nil { Task { await self.session.connect() } }
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        session.setForeground(true)
        Theme.applyAppearance(to: window)
    }
    func sceneWillResignActive(_ scene: UIScene) { session.persist() }
    func sceneDidEnterBackground(_ scene: UIScene) { session.setForeground(false) }
    func sceneDidDisconnect(_ scene: UIScene) { session.disconnect() }
}
