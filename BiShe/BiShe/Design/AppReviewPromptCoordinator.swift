import StoreKit
import UIKit

@MainActor
final class AppReviewPromptCoordinator {
    private enum Key {
        static let successfulCaptureCount = "appReview.successfulCaptureCount"
        static let didRequestReview = "appReview.didRequestReview"
    }

    private let defaults: UserDefaults
    private let captureThreshold = 5

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func registerSuccessfulCapture(in scene: UIWindowScene?) {
        guard !defaults.bool(forKey: Key.didRequestReview) else { return }

        let captureCount = defaults.integer(forKey: Key.successfulCaptureCount) + 1
        defaults.set(captureCount, forKey: Key.successfulCaptureCount)

        guard captureCount >= captureThreshold, let scene else { return }
        defaults.set(true, forKey: Key.didRequestReview)
        AppStore.requestReview(in: scene)
    }
}
