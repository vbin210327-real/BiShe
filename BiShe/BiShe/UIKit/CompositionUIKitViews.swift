import UIKit

nonisolated struct PairedCompositionFrames: Equatable, Sendable {
    let reference: CGRect
    let capture: CGRect
}

/// Gives the reference and capture surfaces one shared horizontal coordinate
/// system. Both frames always have the same size and center X, even when the
/// adjustable split leaves one stage shorter than the other.
nonisolated enum PairedCompositionGeometry {
    static func frames(
        in bounds: CGRect,
        splitFraction: CGFloat,
        aspectRatio: CGFloat
    ) -> PairedCompositionFrames {
        guard bounds.width > 0,
              bounds.height > 0,
              aspectRatio.isFinite,
              aspectRatio > 0 else {
            return PairedCompositionFrames(reference: bounds, capture: bounds)
        }

        let fraction = min(max(splitFraction, 0), 1)
        let seamY = (bounds.height * fraction).rounded(.toNearestOrAwayFromZero)
        let referenceStage = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: seamY)
        let captureStage = CGRect(
            x: bounds.minX,
            y: bounds.minY + seamY,
            width: bounds.width,
            height: bounds.height - seamY
        )

        let availableWidth = min(referenceStage.width, captureStage.width)
        let availableHeight = min(referenceStage.height, captureStage.height)
        let commonSize: CGSize
        if availableWidth / max(availableHeight, 1) > aspectRatio {
            commonSize = CGSize(width: availableHeight * aspectRatio, height: availableHeight)
        } else {
            commonSize = CGSize(width: availableWidth, height: availableWidth / aspectRatio)
        }

        return PairedCompositionFrames(
            reference: centeredRect(size: commonSize, in: referenceStage),
            capture: centeredRect(size: commonSize, in: captureStage)
        )
    }

    private static func centeredRect(size: CGSize, in container: CGRect) -> CGRect {
        CGRect(
            x: container.midX - size.width / 2,
            y: container.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

final class CameraStateView: UIControl {
    enum State: Equatable {
        case permission
        case opening
        case denied
        case unavailable
        case interrupted(String)
    }

    var displayState: State = .opening {
        didSet { guard displayState != oldValue else { return }; updateContent() }
    }
    var onAction: (() -> Void)?

    private let mark = RegistrationMarkView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let copyStack = UIStackView()
    private let stack = UIStackView()
    private var markSizeConstraints: [NSLayoutConstraint] = []
    private var usesCompactLayout = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = StudioUIKitTheme.ink
        isOpaque = true

        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.showsCenterDot = true
        markSizeConstraints = [
            mark.widthAnchor.constraint(equalToConstant: 58),
            mark.heightAnchor.constraint(equalToConstant: 58)
        ]
        NSLayoutConstraint.activate(markSizeConstraints)

        titleLabel.textColor = StudioUIKitTheme.paper
        titleLabel.font = StudioUIKitTheme.roundedFont(size: 18, weight: .semibold, textStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        detailLabel.textColor = StudioUIKitTheme.mutedPaper
        detailLabel.font = StudioUIKitTheme.roundedFont(size: 12, weight: .medium, textStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 3

        actionButton.configuration = .filled()
        actionButton.configuration?.baseBackgroundColor = StudioUIKitTheme.registration
        actionButton.configuration?.baseForegroundColor = StudioUIKitTheme.ink
        actionButton.configuration?.cornerStyle = .capsule
        actionButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 21, bottom: 12, trailing: 21)
        actionButton.titleLabel?.font = StudioUIKitTheme.roundedFont(size: 14, weight: .bold, textStyle: .body)
        actionButton.addTarget(self, action: #selector(runAction), for: .touchUpInside)

        copyStack.addArrangedSubview(titleLabel)
        copyStack.addArrangedSubview(detailLabel)
        copyStack.axis = .vertical
        copyStack.spacing = 8
        copyStack.alignment = .center

        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(mark)
        stack.addArrangedSubview(copyStack)
        stack.addArrangedSubview(actionButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 230)
        ])
        updateContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let compact = bounds.height < 220
        guard compact != usesCompactLayout else { return }
        usesCompactLayout = compact
        let markSize: CGFloat = compact ? 38 : 58
        markSizeConstraints.forEach { $0.constant = markSize }
        stack.spacing = compact ? 10 : 20
        detailLabel.isHidden = compact || (detailLabel.text?.isEmpty ?? true)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(StudioUIKitTheme.hairline.cgColor)
        context.setLineWidth(0.5)
        context.setLineDash(phase: 0, lengths: [3, 7])
        context.move(to: CGPoint(x: rect.midX, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        context.strokePath()
    }

    private func updateContent() {
        let title: String
        let detail: String
        let action: String?
        let showsMark: Bool
        switch displayState {
        case .permission:
            title = ""
            detail = ""
            action = "打开相机"
            showsMark = true
            mark.color = StudioUIKitTheme.registration
        case .opening:
            title = "正在打开镜头"
            detail = ""
            action = nil
            showsMark = true
            mark.color = StudioUIKitTheme.registration
        case .denied:
            title = "相机还没打开"
            detail = "在系统设置中允许比摄使用相机"
            action = "前往设置"
            showsMark = true
            mark.color = StudioUIKitTheme.warning
        case .unavailable:
            title = "这台设备没有可用镜头"
            detail = "请在 iPhone 或 iPad 真机上使用"
            action = nil
            showsMark = true
            mark.color = StudioUIKitTheme.warning
        case .interrupted(let message):
            title = "镜头暂时不可用"
            detail = message
            action = "重试"
            showsMark = true
            mark.color = StudioUIKitTheme.warning
        }

        mark.isHidden = !showsMark
        titleLabel.text = title
        titleLabel.isHidden = title.isEmpty
        detailLabel.text = detail
        detailLabel.isHidden = usesCompactLayout || detail.isEmpty
        copyStack.isHidden = title.isEmpty && detail.isEmpty
        actionButton.setTitle(action, for: .normal)
        actionButton.isHidden = action == nil
        isAccessibilityElement = action == nil
        accessibilityLabel = action == nil ? (detail.isEmpty ? title : "\(title)，\(detail)") : nil
        actionButton.accessibilityHint = detail.isEmpty ? nil : detail
    }

    @objc private func runAction() {
        onAction?()
    }
}

final class RuleOfThirdsOverlayView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), rect.width > 0, rect.height > 0 else { return }
        let xs = [rect.width / 3, rect.width * 2 / 3]
        let ys = [rect.height / 3, rect.height * 2 / 3]

        context.setLineWidth(1.8)
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.40).cgColor)
        drawGrid(context: context, xs: xs, ys: ys, rect: rect)
        context.setLineWidth(0.55)
        context.setStrokeColor(StudioUIKitTheme.paper.withAlphaComponent(0.53).cgColor)
        drawGrid(context: context, xs: xs, ys: ys, rect: rect)

        context.setFillColor(StudioUIKitTheme.registration.withAlphaComponent(0.92).cgColor)
        for x in xs {
            for y in ys {
                context.fillEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
            }
        }
    }

    private func drawGrid(context: CGContext, xs: [CGFloat], ys: [CGFloat], rect: CGRect) {
        for x in xs {
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for y in ys {
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.strokePath()
    }
}

final class SplitSeamControl: UIControl {
    enum Layout: Equatable {
        /// Two regions sit beside each other and the seam moves left/right.
        case leftRight
        /// The reference sits above the live/captured image and the seam moves up/down.
        case topBottom
    }

    var layout: Layout = .leftRight {
        didSet {
            guard layout != oldValue else { return }
            updateAccessibilityDescription()
            updateAccessibilityValue()
            setNeedsDisplay()
        }
    }

    var fraction: CGFloat = 0.5 {
        didSet {
            let next = clamp(fraction)
            if next != fraction { fraction = next; return }
            setNeedsDisplay()
            updateAccessibilityValue()
        }
    }
    var allowedRange: ClosedRange<CGFloat> = 0.22...0.52 {
        didSet {
            guard allowedRange != oldValue else { return }
            fraction = clamp(fraction)
        }
    }
    private var feedbackFraction: CGFloat = 0.5
    private var isDragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = [.adjustable]
        accessibilityHint = "滑动调节两个区域的大小"
        updateAccessibilityDescription()
        updateAccessibilityValue()
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        switch layout {
        case .leftRight:
            return abs(point.x - bounds.width * fraction) <= 34
        case .topBottom:
            return abs(point.y - bounds.height * fraction) <= 34
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        context.setStrokeColor(
            StudioUIKitTheme.paper.withAlphaComponent(isDragging ? 0.78 : 0.36).cgColor
        )
        context.setLineWidth(1 / max(scale, 1))
        switch layout {
        case .leftRight:
            let x = (rect.width * fraction * scale).rounded() / scale
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
        case .topBottom:
            let y = (rect.height * fraction * scale).rounded() / scale
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.strokePath()
    }

    override func accessibilityIncrement() {
        fraction = clamp(fraction + 0.05)
        sendActions(for: .valueChanged)
    }

    override func accessibilityDecrement() {
        fraction = clamp(fraction - 0.05)
        sendActions(for: .valueChanged)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            isDragging = true
            setNeedsDisplay()
            sendActions(for: .editingDidBegin)
        }

        let location = gesture.location(in: self)
        switch layout {
        case .leftRight:
            guard bounds.width > 0 else { return }
            fraction = clamp(location.x / bounds.width)
        case .topBottom:
            guard bounds.height > 0 else { return }
            fraction = clamp(location.y / bounds.height)
        }
        if abs(fraction - feedbackFraction) >= 0.05 {
            feedbackFraction = fraction
            UISelectionFeedbackGenerator().selectionChanged()
        }
        sendActions(for: .valueChanged)

        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            isDragging = false
            setNeedsDisplay()
            sendActions(for: .editingDidEnd)
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
    }

    private func updateAccessibilityDescription() {
        accessibilityLabel = layout == .topBottom ? "调整上下分割线" : "调整左右分割线"
    }

    private func updateAccessibilityValue() {
        if layout == .topBottom {
            accessibilityValue = String(
                format: "上方 %.0f%%，下方 %.0f%%",
                fraction * 100,
                (1 - fraction) * 100
            )
        } else {
            accessibilityValue = String(
                format: "左侧 %.0f%%，右侧 %.0f%%",
                fraction * 100,
                (1 - fraction) * 100
            )
        }
    }
}
