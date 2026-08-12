import UIKit

final class StudioSegmentedControl: UISegmentedControl {
    private var spokenLabel = ""

    override init(items: [Any]?) {
        super.init(items: items)
        isAccessibilityElement = true
        accessibilityTraits = [.adjustable]
        addTarget(self, action: #selector(selectionDidChange), for: .valueChanged)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configureAccessibility(label: String, hint: String? = nil) {
        spokenLabel = label
        accessibilityLabel = label
        accessibilityHint = hint ?? "上下滑动切换选项"
        refreshAccessibilityValue()
    }

    func refreshAccessibilityValue() {
        guard selectedSegmentIndex >= 0,
              selectedSegmentIndex < numberOfSegments else {
            accessibilityValue = nil
            return
        }
        accessibilityValue = titleForSegment(at: selectedSegmentIndex)
    }

    override func accessibilityIncrement() {
        selectForAccessibility(min(selectedSegmentIndex + 1, numberOfSegments - 1))
    }

    override func accessibilityDecrement() {
        selectForAccessibility(max(selectedSegmentIndex - 1, 0))
    }

    private func selectForAccessibility(_ index: Int) {
        guard index >= 0, index < numberOfSegments, index != selectedSegmentIndex else { return }
        selectedSegmentIndex = index
        refreshAccessibilityValue()
        sendActions(for: .valueChanged)
        UISelectionFeedbackGenerator().selectionChanged()
        UIAccessibility.post(
            notification: .announcement,
            argument: "\(spokenLabel)：\(accessibilityValue ?? "")"
        )
    }

    @objc private func selectionDidChange() {
        refreshAccessibilityValue()
    }
}

final class StudioIconButton: UIButton {
    var isEmphasized = false {
        didSet { updateAppearance() }
    }

    init(symbol: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 44).isActive = true
        heightAnchor.constraint(equalToConstant: 44).isActive = true
        self.accessibilityLabel = accessibilityLabel
        accessibilityTraits = .button
        setImage(UIImage(systemName: symbol), for: .normal)
        imageView?.contentMode = .scaleAspectFit
        layer.cornerRadius = 0
        layer.borderWidth = 0
        updateAppearance()

        addTarget(self, action: #selector(pressDown), for: [.touchDown, .touchDragEnter])
        addTarget(self, action: #selector(pressUp), for: [.touchUpInside, .touchCancel, .touchDragExit])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSymbol(_ name: String) {
        setImage(UIImage(systemName: name), for: .normal)
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.42
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    private func updateAppearance() {
        backgroundColor = .clear
        tintColor = isEmphasized ? StudioUIKitTheme.paper : StudioUIKitTheme.mutedPaper
    }

    @objc private func pressDown() {
        UIView.animate(withDuration: 0.11) { self.transform = CGAffineTransform(scaleX: 0.90, y: 0.90) }
    }

    @objc private func pressUp() {
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            usingSpringWithDamping: 0.64,
            initialSpringVelocity: 0.6,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) { self.transform = .identity }
    }
}

final class ShutterControl: UIControl {
    private let outer = CAShapeLayer()
    private let inner = CAShapeLayer()
    private let spinner = UIActivityIndicatorView(style: .medium)

    var isBusy = false {
        didSet { updateAppearance(animated: true) }
    }

    override var isEnabled: Bool {
        didSet { updateAppearance(animated: true) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 76).isActive = true
        heightAnchor.constraint(equalToConstant: 76).isActive = true
        layer.addSublayer(outer)
        layer.addSublayer(inner)
        spinner.color = StudioUIKitTheme.ink
        spinner.hidesWhenStopped = true
        addSubview(spinner)
        isAccessibilityElement = true
        accessibilityLabel = "拍照"
        accessibilityTraits = .button
        addTarget(self, action: #selector(touchDown), for: .touchDown)
        addTarget(self, action: #selector(touchUp), for: [.touchUpInside, .touchCancel, .touchDragExit])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).cgPath
        let innerSize: CGFloat = isBusy ? 48 : 58
        inner.path = UIBezierPath(
            ovalIn: CGRect(
                x: bounds.midX - innerSize / 2,
                y: bounds.midY - innerSize / 2,
                width: innerSize,
                height: innerSize
            )
        ).cgPath
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func updateAppearance(animated: Bool) {
        let changes = {
            self.outer.fillColor = UIColor.clear.cgColor
            self.outer.strokeColor = StudioUIKitTheme.paper.withAlphaComponent(self.isEnabled ? 0.78 : 0.24).cgColor
            self.outer.lineWidth = 2
            self.inner.fillColor = (self.isEnabled ? StudioUIKitTheme.registration : StudioUIKitTheme.mutedPaper.withAlphaComponent(0.30)).cgColor
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.18, animations: changes)
        } else {
            changes()
        }
        isBusy ? spinner.startAnimating() : spinner.stopAnimating()
        accessibilityLabel = isBusy ? "正在拍照" : "拍照"
        accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        accessibilityHint = isEnabled ? "轻点拍摄照片" : "相机准备好后可以拍摄"
    }

    @objc private func touchDown() {
        guard isEnabled else { return }
        UIView.animate(withDuration: 0.08) { self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92) }
    }

    @objc private func touchUp() {
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            usingSpringWithDamping: 0.60,
            initialSpringVelocity: 0.8,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) { self.transform = .identity }
    }
}
