import QuartzCore
import UIKit

private struct ReferenceTransform: Equatable {
    var scale: CGFloat = 1
    var offset: CGPoint = .zero
}

nonisolated struct ReferencePresentationState: Equatable, Sendable {
    let scale: CGFloat
    let normalizedOffset: CGPoint
}

/// A Core Animation-backed reference renderer. The decoded CGImage is assigned
/// once to a CALayer; fitting, resizing and gestures only mutate layer geometry,
/// so no image decode or view-tree reconstruction occurs.
final class ReferenceCanvasView: UIView, UIGestureRecognizerDelegate {
    var onPickReference: (() -> Void)?

    private let imageLayer = CALayer()
    private let emptyState = UIView()
    private let emptyButton = UIButton(type: .custom)
    private let loadingScrim = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private(set) var image: UIImage?
    private(set) var fit: ReferenceFit = .fill
    private var transformState = ReferenceTransform()
    private var pinchStartScale: CGFloat = 1
    private var panStartOffset: CGPoint = .zero
    private let showsEmptyState: Bool

    var presentationState: ReferencePresentationState? {
        guard image != nil, bounds.width > 0, bounds.height > 0 else { return nil }
        return ReferencePresentationState(
            scale: transformState.scale,
            normalizedOffset: CGPoint(
                x: transformState.offset.x / bounds.width,
                y: transformState.offset.y / bounds.height
            )
        )
    }

    init(showsEmptyState: Bool = true, allowsInteraction: Bool = true) {
        self.showsEmptyState = showsEmptyState
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = StudioUIKitTheme.ink
        clipsToBounds = true

        imageLayer.contentsScale = UIScreen.main.scale
        imageLayer.masksToBounds = true
        imageLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(imageLayer)

        if showsEmptyState {
            configureEmptyState()
            configureLoadingState()
        }

        if allowsInteraction {
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 2
            pan.delegate = self
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(pinch)
            addGestureRecognizer(pan)
            addGestureRecognizer(doubleTap)
        }

        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = bounds
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        emptyState.frame = bounds
        loadingScrim.frame = bounds
        clampAndApplyTransform()
    }

    func setImage(_ image: UIImage?) {
        guard self.image !== image else { return }
        self.image = image

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image?.cgImage
        imageLayer.isHidden = image == nil
        CATransaction.commit()

        transformState = ReferenceTransform()
        applyTransform()
        updateEmptyVisibility()
        updateAccessibility()
    }

    func setFit(_ fit: ReferenceFit) {
        guard self.fit != fit else { return }
        self.fit = fit
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contentsGravity = fit == .fill ? .resizeAspectFill : .resizeAspect
        CATransaction.commit()
        clampAndApplyTransform()
    }

    func setLoading(_ loading: Bool) {
        guard showsEmptyState else { return }
        loadingScrim.isHidden = !loading
        loading ? spinner.startAnimating() : spinner.stopAnimating()
    }

    func resetTransform(animated: Bool = true) {
        transformState = ReferenceTransform()
        if animated {
            UIView.animate(
                withDuration: 0.30,
                delay: 0,
                usingSpringWithDamping: 0.78,
                initialSpringVelocity: 0.4,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.imageLayer.setAffineTransform(.identity)
            } completion: { _ in
                self.applyTransform()
            }
        } else {
            applyTransform()
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    private func configureEmptyState() {
        emptyState.backgroundColor = StudioUIKitTheme.ink
        addSubview(emptyState)

        let mark = RegistrationMarkView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.showsCenterDot = true

        let title = UILabel()
        title.text = "从照片中选择参考"
        title.textColor = StudioUIKitTheme.paper
        title.font = StudioUIKitTheme.roundedFont(size: 17, weight: .semibold, textStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [mark, title])
        stack.axis = .vertical
        stack.spacing = 18
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addSubview(stack)

        mark.widthAnchor.constraint(equalToConstant: 62).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 62).isActive = true
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: emptyState.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: emptyState.trailingAnchor, constant: -14)
        ])

        emptyButton.frame = emptyState.bounds
        emptyButton.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        emptyButton.backgroundColor = .clear
        emptyButton.accessibilityLabel = "选择参考图"
        emptyButton.addTarget(self, action: #selector(pickReference), for: .touchUpInside)
        emptyState.addSubview(emptyButton)
    }

    private func configureLoadingState() {
        loadingScrim.backgroundColor = UIColor.black.withAlphaComponent(0.52)
        loadingScrim.isHidden = true
        loadingScrim.isUserInteractionEnabled = true
        addSubview(loadingScrim)
        spinner.color = StudioUIKitTheme.registration
        spinner.translatesAutoresizingMaskIntoConstraints = false
        loadingScrim.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: loadingScrim.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: loadingScrim.centerYAnchor)
        ])
        loadingScrim.accessibilityLabel = "正在载入参考图"
    }

    private func updateEmptyVisibility() {
        guard showsEmptyState else { return }
        emptyState.isHidden = image != nil
    }

    private func updateAccessibility() {
        if image == nil {
            isAccessibilityElement = false
            accessibilityCustomActions = nil
        } else {
            isAccessibilityElement = true
            accessibilityLabel = "参考图"
            accessibilityHint = "可拖动和缩放，双击复位"
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "放大", target: self, selector: #selector(performAccessibilityZoomIn)),
                UIAccessibilityCustomAction(name: "缩小", target: self, selector: #selector(performAccessibilityZoomOut)),
                UIAccessibilityCustomAction(name: "复位", target: self, selector: #selector(performAccessibilityReset))
            ]
        }
    }

    @objc private func pickReference() {
        onPickReference?()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard image != nil else { return }
        switch gesture.state {
        case .began:
            pinchStartScale = transformState.scale
        case .changed:
            transformState.scale = min(max(pinchStartScale * gesture.scale, 1), 5)
            clampAndApplyTransform()
        default:
            clampAndApplyTransform()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard image != nil else { return }
        switch gesture.state {
        case .began:
            panStartOffset = transformState.offset
        case .changed:
            let translation = gesture.translation(in: self)
            transformState.offset = CGPoint(
                x: panStartOffset.x + translation.x,
                y: panStartOffset.y + translation.y
            )
            clampAndApplyTransform()
        default:
            clampAndApplyTransform()
        }
    }

    @objc private func handleDoubleTap() {
        guard image != nil else { return }
        resetTransform()
    }

    @objc private func performAccessibilityZoomIn() -> Bool {
        transformState.scale = min(transformState.scale + 0.5, 5)
        clampAndApplyTransform()
        return true
    }

    @objc private func performAccessibilityZoomOut() -> Bool {
        transformState.scale = max(transformState.scale - 0.5, 1)
        clampAndApplyTransform()
        return true
    }

    @objc private func performAccessibilityReset() -> Bool {
        resetTransform()
        return true
    }

    private func clampAndApplyTransform() {
        guard let image, bounds.width > 0, bounds.height > 0 else {
            applyTransform()
            return
        }

        let imageSize = CGSize(
            width: CGFloat(image.cgImage?.width ?? Int(image.size.width)),
            height: CGFloat(image.cgImage?.height ?? Int(image.size.height))
        )
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let widthRatio = bounds.width / imageSize.width
        let heightRatio = bounds.height / imageSize.height
        let baseScale = fit == .fill ? max(widthRatio, heightRatio) : min(widthRatio, heightRatio)
        let renderedWidth = imageSize.width * baseScale * transformState.scale
        let renderedHeight = imageSize.height * baseScale * transformState.scale
        let maximumX = max((renderedWidth - bounds.width) / 2, 0)
        let maximumY = max((renderedHeight - bounds.height) / 2, 0)
        transformState.offset.x = min(max(transformState.offset.x, -maximumX), maximumX)
        transformState.offset.y = min(max(transformState.offset.y, -maximumY), maximumY)
        applyTransform()
    }

    private func applyTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let affine = CGAffineTransform(
            translationX: transformState.offset.x,
            y: transformState.offset.y
        ).scaledBy(x: transformState.scale, y: transformState.scale)
        imageLayer.setAffineTransform(affine)
        CATransaction.commit()
    }
}
