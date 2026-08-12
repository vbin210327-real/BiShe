import UIKit

@MainActor
enum StudioHaptics {
    static func shutter(enabled: Bool) {
        guard enabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.82)
    }

    static func alignment(enabled: Bool) {
        guard enabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success(enabled: Bool) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning(enabled: Bool) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
