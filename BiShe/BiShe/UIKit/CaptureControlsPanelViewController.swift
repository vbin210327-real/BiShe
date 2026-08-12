import UIKit

struct CaptureControlsState: Equatable {
    let aspectRatios: [CaptureAspectRatio]
    let selectedAspectRatio: CaptureAspectRatio
    let flashMode: CameraFlashMode
    let hasFlash: Bool
    let showsGrid: Bool
    let referenceFit: ReferenceFit
    let livePhotoEnabled: Bool
    let supportsLivePhoto: Bool
}

@MainActor
final class CaptureControlsPanelViewController: UIViewController {
    var onSelectAspectRatio: ((CaptureAspectRatio) -> Void)?
    var onSelectReferenceFit: ((ReferenceFit) -> Void)?
    var onCycleFlash: (() -> Void)?
    var onToggleGrid: (() -> Void)?
    var onToggleLivePhoto: (() -> Void)?

    private let ratioRow = InlineSelectionRow(title: "比例")
    private let referenceFitRow = InlineSelectionRow(title: "参考")
    private let flashButton = PanelActionButton()
    private let gridButton = PanelActionButton()
    private let livePhotoButton = PanelActionButton()

    private(set) var state: CaptureControlsState

    init(state: CaptureControlsState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        render()
    }

    func update(state: CaptureControlsState) {
        guard self.state != state else { return }
        self.state = state
        if isViewLoaded { render() }
    }

    private func configureView() {
        view.backgroundColor = StudioUIKitTheme.ink

        ratioRow.onSelect = { [weak self] index in
            guard let self, state.aspectRatios.indices.contains(index) else { return }
            onSelectAspectRatio?(state.aspectRatios[index])
        }
        referenceFitRow.onSelect = { [weak self] index in
            guard ReferenceFit.allCases.indices.contains(index) else { return }
            self?.onSelectReferenceFit?(ReferenceFit.allCases[index])
        }

        flashButton.addTarget(self, action: #selector(cycleFlash), for: .touchUpInside)
        gridButton.addTarget(self, action: #selector(toggleGrid), for: .touchUpInside)
        livePhotoButton.addTarget(self, action: #selector(toggleLivePhoto), for: .touchUpInside)

        let separator = UIView()
        separator.backgroundColor = StudioUIKitTheme.hairline
        separator.heightAnchor.constraint(equalToConstant: 0.5).isActive = true

        let actionStack = UIStackView(arrangedSubviews: [flashButton, livePhotoButton, gridButton])
        actionStack.axis = .horizontal
        actionStack.distribution = .fillEqually
        actionStack.spacing = 8
        actionStack.heightAnchor.constraint(equalToConstant: 66).isActive = true

        let stack = UIStackView(arrangedSubviews: [
            ratioRow,
            referenceFitRow,
            separator,
            actionStack
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = .clear
        scrollView.indicatorStyle = .white
        scrollView.alwaysBounceVertical = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -44)
        ])
    }

    private func render() {
        ratioRow.configure(
            items: state.aspectRatios.map(\.displayTitle),
            selectedIndex: state.aspectRatios.firstIndex(of: state.selectedAspectRatio) ?? 0,
            accessibilityLabel: "照片比例"
        )
        ratioRow.setEnabled(
            !state.livePhotoEnabled,
            disabledHint: state.livePhotoEnabled ? "关闭实况后可以更改照片比例" : nil
        )
        referenceFitRow.configure(
            items: ReferenceFit.allCases.map(\.title),
            selectedIndex: ReferenceFit.allCases.firstIndex(of: state.referenceFit) ?? 0,
            accessibilityLabel: "参考图显示"
        )

        flashButton.configure(
            title: "闪光 · \(state.flashMode.title)",
            symbol: state.flashMode.symbol,
            isActive: state.flashMode != .off,
            isEnabled: state.hasFlash
        )
        gridButton.configure(
            title: "三分线 · \(state.showsGrid ? "开" : "关")",
            symbol: "grid",
            isActive: state.showsGrid,
            isEnabled: true
        )
        livePhotoButton.configure(
            title: "实况 · \(state.livePhotoEnabled ? "开" : "关")",
            symbol: state.livePhotoEnabled ? "livephoto" : "livephoto.slash",
            isActive: state.livePhotoEnabled,
            isEnabled: state.supportsLivePhoto
        )
    }

    @objc private func cycleFlash() { onCycleFlash?() }
    @objc private func toggleGrid() { onToggleGrid?() }
    @objc private func toggleLivePhoto() { onToggleLivePhoto?() }
}

private final class InlineSelectionRow: UIView {
    var onSelect: ((Int) -> Void)?

    private let titleLabel = UILabel()
    private let optionsStack = UIStackView()

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.textColor = StudioUIKitTheme.mutedPaper
        titleLabel.font = StudioUIKitTheme.standardFont(size: 12, weight: .medium, textStyle: .footnote)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true

        optionsStack.axis = .horizontal
        optionsStack.alignment = .fill
        optionsStack.distribution = .fillEqually
        optionsStack.spacing = 5

        let stack = UIStackView(arrangedSubviews: [titleLabel, optionsStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 14
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(items: [String], selectedIndex: Int, accessibilityLabel: String) {
        optionsStack.arrangedSubviews.forEach {
            optionsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (index, title) in items.enumerated() {
            let button = InlineOptionButton()
            button.tag = index
            button.setTitle(title, for: .normal)
            button.isChosen = index == selectedIndex
            button.accessibilityLabel = "\(accessibilityLabel) \(title)"
            button.accessibilityTraits = index == selectedIndex ? [.button, .selected] : .button
            button.addTarget(self, action: #selector(selectOption(_:)), for: .touchUpInside)
            optionsStack.addArrangedSubview(button)
        }
    }

    func setEnabled(_ enabled: Bool, disabledHint: String?) {
        isUserInteractionEnabled = enabled
        alpha = enabled ? 1 : 0.38
        for case let button as UIButton in optionsStack.arrangedSubviews {
            button.isEnabled = enabled
            button.accessibilityHint = disabledHint
        }
    }

    @objc private func selectOption(_ sender: UIButton) {
        onSelect?(sender.tag)
    }
}

private final class InlineOptionButton: UIButton {
    var isChosen = false {
        didSet { updateAppearance() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel?.font = StudioUIKitTheme.monospacedFont(size: 13, weight: .semibold)
        layer.cornerRadius = 0
        layer.borderWidth = 0
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard isChosen, let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(StudioUIKitTheme.paper.cgColor)
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: rect.midX - 9, y: rect.maxY - 2))
        context.addLine(to: CGPoint(x: rect.midX + 9, y: rect.maxY - 2))
        context.strokePath()
    }

    private func updateAppearance() {
        setTitleColor(isChosen ? StudioUIKitTheme.paper : StudioUIKitTheme.mutedPaper, for: .normal)
        setNeedsDisplay()
    }
}

private final class PanelActionButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        var configuration = UIButton.Configuration.plain()
        configuration.imagePlacement = .top
        configuration.imagePadding = 7
        configuration.contentInsets = .zero
        self.configuration = configuration
        titleLabel?.font = StudioUIKitTheme.standardFont(size: 11, weight: .medium, textStyle: .caption1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, symbol: String, isActive: Bool, isEnabled: Bool) {
        configuration?.title = title
        configuration?.image = UIImage(systemName: symbol)
        configuration?.baseForegroundColor = isActive ? StudioUIKitTheme.paper : StudioUIKitTheme.mutedPaper
        self.isEnabled = isEnabled
        alpha = isEnabled ? 1 : 0.32
        accessibilityLabel = title
        accessibilityTraits = isActive ? [.button, .selected] : .button
    }
}
