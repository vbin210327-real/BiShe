import UIKit

enum StudioUIKitTheme {
    static let ink = UIColor(white: 0.025, alpha: 1)
    static let liftedInk = UIColor(white: 0.095, alpha: 1)
    static let paper = UIColor(white: 0.98, alpha: 1)
    static let mutedPaper = UIColor(white: 0.64, alpha: 1)
    static let registration = UIColor.white
    static let warning = UIColor(white: 0.78, alpha: 1)
    static let hairline = UIColor.white.withAlphaComponent(0.17)

    static func roundedFont(
        size: CGFloat,
        weight: UIFont.Weight,
        textStyle: UIFont.TextStyle? = nil
    ) -> UIFont {
        standardFont(size: size, weight: weight, textStyle: textStyle)
    }

    static func standardFont(
        size: CGFloat,
        weight: UIFont.Weight,
        textStyle: UIFont.TextStyle? = nil
    ) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let textStyle else { return base }
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base)
    }

    static func monospacedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

extension UIView {
    func pinEdges(to other: UIView, insets: UIEdgeInsets = .zero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom)
        ])
    }
}

final class RegistrationMarkView: UIView {
    var color: UIColor = StudioUIKitTheme.registration {
        didSet { setNeedsDisplay() }
    }
    var lineWidth: CGFloat = 1.5 {
        didSet { setNeedsDisplay() }
    }
    var showsCenterDot = false {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.square)

        let inset = lineWidth / 2
        let arm = min(rect.width, rect.height) * 0.29
        let minX = rect.minX + inset
        let minY = rect.minY + inset
        let maxX = rect.maxX - inset
        let maxY = rect.maxY - inset

        context.move(to: CGPoint(x: minX, y: minY + arm))
        context.addLine(to: CGPoint(x: minX, y: minY))
        context.addLine(to: CGPoint(x: minX + arm, y: minY))
        context.move(to: CGPoint(x: maxX - arm, y: minY))
        context.addLine(to: CGPoint(x: maxX, y: minY))
        context.addLine(to: CGPoint(x: maxX, y: minY + arm))
        context.move(to: CGPoint(x: maxX, y: maxY - arm))
        context.addLine(to: CGPoint(x: maxX, y: maxY))
        context.addLine(to: CGPoint(x: maxX - arm, y: maxY))
        context.move(to: CGPoint(x: minX + arm, y: maxY))
        context.addLine(to: CGPoint(x: minX, y: maxY))
        context.addLine(to: CGPoint(x: minX, y: maxY - arm))
        context.strokePath()

        if showsCenterDot {
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: rect.midX - 2, y: rect.midY - 2, width: 4, height: 4))
        }
    }
}
