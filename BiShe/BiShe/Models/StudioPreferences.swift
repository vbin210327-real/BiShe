import Combine
import CoreGraphics
import Foundation

/// A direction-independent photo aspect ratio.
///
/// Ratios are stored in landscape order (longer side first). A presentation
/// surface decides whether to invert the value for portrait orientation by
/// calling `displayValue(isPortrait:)`.
nonisolated struct CaptureAspectRatio: Hashable, Identifiable, RawRepresentable, Sendable {
    static let fourThree = CaptureAspectRatio(width: 4, height: 3)
    static let square = CaptureAspectRatio(width: 1, height: 1)
    static let sixteenNine = CaptureAspectRatio(width: 16, height: 9)
    static let presets: [CaptureAspectRatio] = [.fourThree, .square, .sixteenNine]

    let width: Int
    let height: Int

    var id: String { rawValue }
    var displayTitle: String { "\(width):\(height)" }
    var rawValue: String { displayTitle }

    private init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init?(rawValue: String) {
        guard let preset = Self.presets.first(where: { $0.rawValue == rawValue }) else {
            return nil
        }
        self = preset
    }

    /// Returns the viewport's width divided by height in the requested device
    /// orientation. A canonical `4:3` therefore becomes `3:4` in portrait.
    func displayValue(isPortrait: Bool) -> CGFloat {
        if isPortrait {
            return CGFloat(height) / CGFloat(width)
        }
        return CGFloat(width) / CGFloat(height)
    }
}

enum ReferenceFit: String, CaseIterable, Identifiable {
    case fill
    case fit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: "铺满"
        case .fit: "完整"
        }
    }
}

@MainActor
final class StudioPreferences: ObservableObject {
    private enum Key {
        static let referenceFit = "studio.referenceFit"
        static let captureAspectRatio = "studio.captureAspectRatio"
        static let showsGrid = "studio.showsGrid"
        static let livePhotoEnabled = "studio.livePhotoEnabled"
    }

    private let defaults: UserDefaults

    @Published var referenceFit: ReferenceFit {
        didSet { defaults.set(referenceFit.rawValue, forKey: Key.referenceFit) }
    }

    @Published var captureAspectRatio: CaptureAspectRatio {
        didSet { defaults.set(captureAspectRatio.rawValue, forKey: Key.captureAspectRatio) }
    }

    @Published var showsGrid: Bool {
        didSet { defaults.set(showsGrid, forKey: Key.showsGrid) }
    }

    /// Haptics are part of the fixed camera interaction language, not a setting.
    let haptics = true

    @Published var livePhotoEnabled: Bool {
        didSet { defaults.set(livePhotoEnabled, forKey: Key.livePhotoEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        referenceFit = ReferenceFit(rawValue: defaults.string(forKey: Key.referenceFit) ?? "") ?? .fill
        captureAspectRatio = CaptureAspectRatio(
            rawValue: defaults.string(forKey: Key.captureAspectRatio) ?? ""
        ) ?? .fourThree

        showsGrid = defaults.object(forKey: Key.showsGrid) as? Bool ?? true
        livePhotoEnabled = defaults.object(forKey: Key.livePhotoEnabled) as? Bool ?? false
    }
}
