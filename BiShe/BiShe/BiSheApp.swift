import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UIView.appearance().tintColor = StudioUIKitTheme.registration
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = StudioUIKitTheme.ink
        window.rootViewController = StudioViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
