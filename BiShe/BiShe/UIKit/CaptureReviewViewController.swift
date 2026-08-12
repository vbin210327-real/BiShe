import Combine
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// A lightweight, full-screen review surface whose image views stay mounted for
/// the controller's lifetime. With a reference, review is always reference above
/// and captured photo below; no image is decoded or assigned again during layout.
@MainActor
final class CaptureReviewViewController: UIViewController {
    var onFinish: (() -> Void)?
    var onRetake: (() -> Void)?

    private let capturedData: Data
    private let capturedImage: UIImage
    private let livePhotoMovieURL: URL?
    private let captureAspectRatio: CGFloat
    private let referencePresentation: ReferencePresentationState?
    private let preferences: StudioPreferences
    private let photoWriter: PhotoLibraryWriter

    private let canvasView = UIView()
    private let capturedSurface: ReviewImageSurfaceView
    private let referenceSurface: ReviewImageSurfaceView?
    private let splitSeam = SplitSeamControl()
    private let capturedTag = ReviewEdgeTag(text: "成片")
    private let livePlaybackButton = ReviewLivePlaybackButton()
    private let referenceTag = ReviewEdgeTag(text: "参考")

    private let shareButton = StudioIconButton(symbol: "square.and.arrow.up", accessibilityLabel: "分享照片")
    private let statusButton = UIButton(type: .system)
    private let bottomRail = UIView()
    private let retakeButton = UIButton(type: .system)
    private let primaryButton = UIButton(type: .system)

    private var saveTask: Task<Void, Never>?
    private var shareTask: Task<Void, Never>?
    private var shareFileURL: URL?
    private var livePhotoImageFileURL: URL?
    private var livePhotoRequestID = PHLivePhotoRequestIDInvalid
    private var cancellables = Set<AnyCancellable>()
    private var didComplete = false

    init(
        capturedImage: UIImage,
        capturedData: Data,
        livePhotoMovieURL: URL?,
        captureAspectRatio: CGFloat,
        initialSplitFraction _: CGFloat,
        referenceImage: UIImage?,
        referencePresentation: ReferencePresentationState?,
        preferences: StudioPreferences,
        photoWriter: PhotoLibraryWriter
    ) {
        self.capturedData = capturedData
        self.capturedImage = capturedImage
        self.livePhotoMovieURL = livePhotoMovieURL
        let imageAspectRatio = capturedImage.size.height > 0
            ? capturedImage.size.width / capturedImage.size.height
            : 1
        self.captureAspectRatio = captureAspectRatio.isFinite && captureAspectRatio > 0
            ? captureAspectRatio
            : imageAspectRatio
        self.referencePresentation = referencePresentation
        self.preferences = preferences
        self.photoWriter = photoWriter
        capturedSurface = ReviewImageSurfaceView(
            image: capturedImage,
            fit: .fit,
            presentationState: nil,
            accessibilityLabel: "拍摄照片",
            allowsZoom: true
        )
        referenceSurface = referenceImage.map {
            ReviewImageSurfaceView(
                image: $0,
                fit: preferences.referenceFit,
                presentationState: referencePresentation,
                accessibilityLabel: "参考照片",
                allowsZoom: false
            )
        }
        super.init(nibName: nil, bundle: nil)
        if livePhotoMovieURL != nil {
            capturedTag.text = "成片 ·"
        }
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        saveTask?.cancel()
        shareTask?.cancel()
        if livePhotoRequestID != PHLivePhotoRequestIDInvalid {
            PHLivePhoto.cancelRequest(withRequestID: livePhotoRequestID)
        }
        if let shareFileURL {
            try? FileManager.default.removeItem(at: shareFileURL)
        }
        if let livePhotoImageFileURL {
            try? FileManager.default.removeItem(at: livePhotoImageFileURL)
        }
        if let livePhotoMovieURL {
            try? FileManager.default.removeItem(at: livePhotoMovieURL)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        configureCanvas()
        configureTopChrome()
        configureBottomRail()
        configureStatusControl()
        bindState()
        renderSaveState(photoWriter.state, announce: false)
        loadLivePhotoIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: referenceSurface ?? capturedSurface)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCanvas()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { false }

    private func configureView() {
        view.backgroundColor = StudioUIKitTheme.ink
        view.isOpaque = true
        view.accessibilityViewIsModal = true
    }

    private func configureCanvas() {
        canvasView.backgroundColor = .black
        canvasView.clipsToBounds = true
        canvasView.isOpaque = true
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: view.topAnchor)
        ])

        canvasView.addSubview(capturedSurface)
        if let referenceSurface {
            canvasView.addSubview(referenceSurface)
        }

        splitSeam.layout = .topBottom
        splitSeam.allowedRange = 0.5...0.5
        // The review is a fresh comparison surface. Its starting composition
        // must not inherit however the live-view seam happened to be positioned.
        splitSeam.fraction = 0.5
        splitSeam.isUserInteractionEnabled = false
        splitSeam.isAccessibilityElement = false
        canvasView.addSubview(splitSeam)
        canvasView.addSubview(referenceTag)
        canvasView.addSubview(capturedTag)
        livePlaybackButton.isHidden = livePhotoMovieURL == nil
        livePlaybackButton.isEnabled = false
        livePlaybackButton.addTarget(self, action: #selector(playLivePhotoFromTag), for: .touchUpInside)
        canvasView.addSubview(livePlaybackButton)
    }

    private func configureTopChrome() {
        shareButton.addTarget(self, action: #selector(sharePhoto), for: .touchUpInside)
        view.addSubview(shareButton)

        NSLayoutConstraint.activate([
            shareButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            shareButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)
        ])
    }

    private func configureBottomRail() {
        bottomRail.translatesAutoresizingMaskIntoConstraints = false
        bottomRail.backgroundColor = StudioUIKitTheme.ink.withAlphaComponent(0.97)
        view.addSubview(bottomRail)

        let hairline = UIView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.backgroundColor = StudioUIKitTheme.hairline
        bottomRail.addSubview(hairline)

        configureRetakeButton()
        configurePrimaryButton()

        let actionStack = UIStackView(arrangedSubviews: [retakeButton, primaryButton])
        actionStack.axis = .horizontal
        actionStack.spacing = 12
        actionStack.distribution = .fillEqually
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        bottomRail.addSubview(actionStack)

        NSLayoutConstraint.activate([
            bottomRail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomRail.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomRail.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvasView.bottomAnchor.constraint(equalTo: bottomRail.topAnchor),

            hairline.leadingAnchor.constraint(equalTo: bottomRail.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: bottomRail.trailingAnchor),
            hairline.topAnchor.constraint(equalTo: bottomRail.topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),

            actionStack.leadingAnchor.constraint(equalTo: bottomRail.leadingAnchor, constant: 18),
            actionStack.trailingAnchor.constraint(equalTo: bottomRail.trailingAnchor, constant: -18),
            actionStack.topAnchor.constraint(equalTo: bottomRail.topAnchor, constant: 14),
            actionStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            actionStack.heightAnchor.constraint(equalToConstant: 54)
        ])
    }

    private func configureRetakeButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.title = "重拍"
        configuration.image = UIImage(systemName: "arrow.counterclockwise")
        configuration.imagePadding = 8
        configuration.baseForegroundColor = StudioUIKitTheme.paper
        configuration.cornerStyle = .fixed
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var result = incoming
            result.font = StudioUIKitTheme.roundedFont(size: 15, weight: .semibold, textStyle: .body)
            return result
        }
        retakeButton.configuration = configuration
        retakeButton.layer.cornerRadius = 14
        retakeButton.addTarget(self, action: #selector(retakePhoto), for: .touchUpInside)
        retakeButton.accessibilityHint = "放弃这张照片并返回取景"
    }

    private func configurePrimaryButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.title = livePhotoMovieURL == nil ? "保存并继续" : "保存实况并继续"
        configuration.image = UIImage(systemName: "checkmark")
        configuration.imagePadding = 8
        configuration.baseBackgroundColor = StudioUIKitTheme.registration
        configuration.baseForegroundColor = StudioUIKitTheme.ink
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 14
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var result = incoming
            result.font = StudioUIKitTheme.roundedFont(size: 15, weight: .bold, textStyle: .body)
            return result
        }
        primaryButton.configuration = configuration
        primaryButton.addTarget(self, action: #selector(saveAndContinue), for: .touchUpInside)
    }

    private func configureStatusControl() {
        statusButton.translatesAutoresizingMaskIntoConstraints = false
        statusButton.configuration = .plain()
        statusButton.configuration?.cornerStyle = .capsule
        statusButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        statusButton.titleLabel?.font = StudioUIKitTheme.roundedFont(size: 12, weight: .semibold, textStyle: .footnote)
        statusButton.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        statusButton.layer.cornerRadius = 17
        statusButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        statusButton.isHidden = true
        view.addSubview(statusButton)

        NSLayoutConstraint.activate([
            statusButton.heightAnchor.constraint(equalToConstant: 34),
            statusButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusButton.bottomAnchor.constraint(equalTo: bottomRail.topAnchor, constant: -12),
            statusButton.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 18),
            statusButton.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18)
        ])
    }

    private func bindState() {
        photoWriter.$state
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.renderSaveState(state, announce: true)
            }
            .store(in: &cancellables)
    }

    private func layoutCanvas() {
        let bounds = canvasView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        splitSeam.allowedRange = 0.5...0.5
        splitSeam.fraction = 0.5
        splitSeam.frame = bounds

        guard let referenceSurface else {
            let photoFrame = aspectFitRect(aspectRatio: captureAspectRatio, inside: bounds)
            capturedSurface.frame = photoFrame
            capturedTag.frame = edgeTagFrame(
                capturedTag,
                x: photoFrame.minX + 10,
                y: max(photoFrame.minY + 10, tagTop)
            )
            layoutLivePlaybackButton()
            referenceTag.isHidden = true
            splitSeam.isHidden = true
            canvasView.bringSubviewToFront(capturedTag)
            canvasView.bringSubviewToFront(livePlaybackButton)
            return
        }

        referenceSurface.isHidden = false
        referenceTag.isHidden = false
        capturedTag.isHidden = false

        let pairedFrames = PairedCompositionGeometry.frames(
            in: bounds,
            splitFraction: splitSeam.fraction,
            aspectRatio: captureAspectRatio
        )
        referenceSurface.frame = pairedFrames.reference
        capturedSurface.frame = pairedFrames.capture

        // Keep each label inside its own half, including compact landscape layouts.
        let referenceTagY = min(
            max(tagTop, pairedFrames.reference.minY + 8),
            max(pairedFrames.reference.maxY - 36, pairedFrames.reference.minY + 8)
        )
        referenceTag.frame = edgeTagFrame(
            referenceTag,
            x: pairedFrames.reference.minX + 10,
            y: referenceTagY
        )
        capturedTag.frame = edgeTagFrame(
            capturedTag,
            x: pairedFrames.capture.minX + 10,
            y: pairedFrames.capture.minY + 10
        )
        layoutLivePlaybackButton()
        referenceSurface.alpha = 1
        splitSeam.isHidden = false
        referenceTag.text = "参考"

        canvasView.bringSubviewToFront(splitSeam)
        canvasView.bringSubviewToFront(referenceTag)
        canvasView.bringSubviewToFront(capturedTag)
        canvasView.bringSubviewToFront(livePlaybackButton)
    }

    private var tagTop: CGFloat {
        view.safeAreaInsets.top + 12
    }

    private func edgeTagFrame(_ tag: UIView, x: CGFloat, y: CGFloat) -> CGRect {
        let size = tag.sizeThatFits(CGSize(width: 120, height: 22))
        return CGRect(x: x, y: y, width: min(size.width, 96), height: 22)
    }

    private func layoutLivePlaybackButton() {
        guard !livePlaybackButton.isHidden else { return }
        let size = livePlaybackButton.sizeThatFits(CGSize(width: 96, height: 22))
        livePlaybackButton.frame = CGRect(
            x: capturedTag.frame.maxX + 3,
            y: capturedTag.frame.minY,
            width: min(size.width, 96),
            height: 22
        )
    }

    private func aspectFitRect(aspectRatio: CGFloat, inside container: CGRect) -> CGRect {
        guard container.width > 0,
              container.height > 0,
              aspectRatio.isFinite,
              aspectRatio > 0 else { return container }

        let containerAspectRatio = container.width / container.height
        let size: CGSize
        if containerAspectRatio > aspectRatio {
            size = CGSize(width: container.height * aspectRatio, height: container.height)
        } else {
            size = CGSize(width: container.width, height: container.width / aspectRatio)
        }
        return CGRect(
            x: container.midX - size.width / 2,
            y: container.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func renderSaveState(_ state: PhotoSaveState, announce: Bool) {
        let saving = state == .saving
        retakeButton.isEnabled = !saving
        primaryButton.isEnabled = !saving
        primaryButton.configuration?.showsActivityIndicator = saving

        switch state {
        case .idle:
            primaryButton.configuration?.title = livePhotoMovieURL == nil ? "保存并继续" : "保存实况并继续"
            primaryButton.configuration?.image = UIImage(systemName: "checkmark")
            statusButton.isHidden = true

        case .saving:
            primaryButton.configuration?.title = livePhotoMovieURL == nil ? "正在保存" : "正在保存实况"
            primaryButton.configuration?.image = nil
            statusButton.isHidden = true

        case .saved:
            primaryButton.configuration?.title = "继续拍摄"
            primaryButton.configuration?.image = UIImage(systemName: "arrow.right")
            configureStatus(title: "已存入照片", symbol: "checkmark.circle.fill", color: StudioUIKitTheme.registration, interactive: false)
            if announce { UIAccessibility.post(notification: .announcement, argument: "照片已保存") }

        case .denied:
            primaryButton.configuration?.title = "重试保存"
            primaryButton.configuration?.image = UIImage(systemName: "arrow.clockwise")
            configureStatus(title: "无法保存 · 前往设置", symbol: "exclamationmark.triangle.fill", color: StudioUIKitTheme.warning, interactive: true)
            if announce { UIAccessibility.post(notification: .announcement, argument: "没有照片保存权限") }

        case .failed(let message):
            primaryButton.configuration?.title = "重试保存"
            primaryButton.configuration?.image = UIImage(systemName: "arrow.clockwise")
            configureStatus(title: message, symbol: "exclamationmark.circle.fill", color: StudioUIKitTheme.warning, interactive: false)
            if announce { UIAccessibility.post(notification: .announcement, argument: "照片保存失败") }
        }
    }

    private func configureStatus(title: String, symbol: String, color: UIColor, interactive: Bool) {
        statusButton.configuration?.title = title
        statusButton.configuration?.image = UIImage(systemName: symbol)
        statusButton.configuration?.imagePadding = 7
        statusButton.configuration?.baseForegroundColor = color
        statusButton.isUserInteractionEnabled = interactive
        statusButton.accessibilityHint = interactive ? "打开系统设置以允许保存照片" : nil
        statusButton.isHidden = false
    }

    private func loadLivePhotoIfNeeded() {
        guard let livePhotoMovieURL,
              let imageFileURL = CapturedPhotoShareFile.write(capturedData) else { return }
        livePhotoImageFileURL = imageFileURL
        livePhotoRequestID = PHLivePhoto.request(
            withResourceFileURLs: [imageFileURL, livePhotoMovieURL],
            placeholderImage: capturedImage,
            targetSize: .zero,
            contentMode: .aspectFit
        ) { [weak self] livePhoto, info in
            guard let self else { return }
            if let livePhoto {
                capturedSurface.setLivePhoto(livePhoto)
                let isDegraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true
                livePlaybackButton.isEnabled = !isDegraded
                livePlaybackButton.accessibilityValue = isDegraded ? "正在准备" : "已就绪"
            } else if (info[PHLivePhotoInfoCancelledKey] as? Bool) != true {
                livePlaybackButton.isEnabled = false
                livePlaybackButton.accessibilityValue = "无法播放"
            }
        }
    }

    @objc private func playLivePhotoFromTag() {
        StudioHaptics.alignment(enabled: preferences.haptics)
        capturedSurface.playLivePhotoFromBeginning()
    }

    private func finishReview() {
        guard !didComplete else { return }
        didComplete = true
        if let onFinish {
            onFinish()
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func sharePhoto() {
        StudioHaptics.alignment(enabled: preferences.haptics)
        guard shareTask == nil else { return }
        shareButton.isEnabled = false
        let data = capturedData
        shareTask = Task { [weak self] in
            let fileURL = await Task.detached(priority: .userInitiated) {
                CapturedPhotoShareFile.write(data)
            }.value
            guard !Task.isCancelled else {
                if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
                return
            }
            guard let self else {
                if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
                return
            }
            self.shareTask = nil
            self.shareButton.isEnabled = true
            if let previousURL = self.shareFileURL {
                try? FileManager.default.removeItem(at: previousURL)
            }
            self.shareFileURL = fileURL
            let item: Any = fileURL ?? data
            let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = self.shareButton
                popover.sourceRect = self.shareButton.bounds
            }
            self.present(activity, animated: true)
        }
    }

    @objc private func retakePhoto() {
        guard photoWriter.state != .saving, !didComplete else { return }
        StudioHaptics.alignment(enabled: preferences.haptics)
        photoWriter.reset()
        didComplete = true
        if let onRetake {
            onRetake()
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func saveAndContinue() {
        guard photoWriter.state != .saving, !didComplete else { return }
        if photoWriter.state == .saved {
            finishReview()
            return
        }

        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let self else { return }
            let saved = await self.photoWriter.save(
                self.capturedData,
                livePhotoMovieURL: self.livePhotoMovieURL
            )
            guard !Task.isCancelled else { return }
            if saved {
                StudioHaptics.success(enabled: self.preferences.haptics)
                try? await Task.sleep(for: .milliseconds(520))
                guard !Task.isCancelled else { return }
                self.finishReview()
            } else {
                StudioHaptics.warning(enabled: self.preferences.haptics)
            }
        }
    }

    @objc private func openSettings() {
        guard photoWriter.state == .denied,
              let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private nonisolated enum CapturedPhotoShareFile {
    static func write(_ data: Data) -> URL? {
        let fileExtension: String
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let type = CGImageSourceGetType(source),
           let uniformType = UTType(type as String),
           let preferredExtension = uniformType.preferredFilenameExtension {
            fileExtension = preferredExtension
        } else {
            fileExtension = "jpg"
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("比摄-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

private final class ReviewImageSurfaceView: UIView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private let presentationState: ReferencePresentationState?
    private let allowsZoom: Bool
    private var zoomScrollView: UIScrollView?
    private var zoomDoubleTapGestureRecognizer: UITapGestureRecognizer?
    private var livePhotoView: PHLivePhotoView?
    private var lastLayoutSize: CGSize = .zero

    init(
        image: UIImage,
        fit: ReferenceFit,
        presentationState: ReferencePresentationState?,
        accessibilityLabel: String,
        allowsZoom: Bool
    ) {
        self.presentationState = presentationState
        self.allowsZoom = allowsZoom
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = true
        isOpaque = false
        isAccessibilityElement = !allowsZoom
        self.accessibilityLabel = accessibilityLabel
        accessibilityHint = allowsZoom ? "双指缩放，拖动查看细节，双击放大或还原" : nil

        imageView.image = image
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = false
        imageView.isAccessibilityElement = false

        if allowsZoom {
            let scrollView = UIScrollView()
            scrollView.backgroundColor = .clear
            scrollView.clipsToBounds = true
            scrollView.delegate = self
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = 6
            scrollView.bouncesZoom = true
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.showsVerticalScrollIndicator = false
            scrollView.decelerationRate = .fast
            scrollView.accessibilityLabel = accessibilityLabel
            scrollView.accessibilityHint = accessibilityHint
            addSubview(scrollView)
            scrollView.addSubview(imageView)
            zoomScrollView = scrollView

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            scrollView.addGestureRecognizer(doubleTap)
            zoomDoubleTapGestureRecognizer = doubleTap
        } else {
            addSubview(imageView)
        }
        setFit(fit)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let zoomScrollView {
            zoomScrollView.frame = bounds
            guard bounds.size != lastLayoutSize else { return }
            lastLayoutSize = bounds.size
            zoomScrollView.setZoomScale(1, animated: false)
            zoomScrollView.contentInset = .zero
            imageView.transform = .identity
            imageView.frame = zoomScrollView.bounds
            livePhotoView?.frame = imageView.bounds
            zoomScrollView.contentSize = imageView.bounds.size
            return
        }

        imageView.transform = .identity
        imageView.frame = bounds
        livePhotoView?.frame = imageView.bounds
        guard let presentationState else { return }
        imageView.transform = CGAffineTransform(
            translationX: presentationState.normalizedOffset.x * bounds.width,
            y: presentationState.normalizedOffset.y * bounds.height
        ).scaledBy(x: presentationState.scale, y: presentationState.scale)
    }

    func setFit(_ fit: ReferenceFit) {
        let contentMode: UIView.ContentMode = fit == .fill ? .scaleAspectFill : .scaleAspectFit
        imageView.contentMode = contentMode
        livePhotoView?.contentMode = contentMode
    }

    func setLivePhoto(_ livePhoto: PHLivePhoto) {
        let liveView: PHLivePhotoView
        if let livePhotoView {
            liveView = livePhotoView
        } else {
            liveView = PHLivePhotoView(frame: imageView.bounds)
            liveView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            liveView.contentMode = imageView.contentMode
            liveView.isMuted = false
            liveView.accessibilityLabel = "实况成片"
            liveView.accessibilityHint = "轻点或长按播放，双指缩放查看细节"

            let tap = UITapGestureRecognizer(target: self, action: #selector(playLivePhoto))
            if let zoomDoubleTapGestureRecognizer {
                tap.require(toFail: zoomDoubleTapGestureRecognizer)
            }
            liveView.addGestureRecognizer(tap)
            imageView.isUserInteractionEnabled = true
            imageView.addSubview(liveView)
            self.livePhotoView = liveView

            zoomScrollView?.accessibilityLabel = "实况成片"
            zoomScrollView?.accessibilityHint = "轻点或长按播放，双指缩放，双击放大或还原"
        }
        liveView.livePhoto = livePhoto
    }

    func playLivePhotoFromBeginning() {
        guard livePhotoView?.livePhoto != nil else { return }
        livePhotoView?.stopPlayback()
        livePhotoView?.startPlayback(with: .full)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        allowsZoom ? imageView : nil
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let verticalInset = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let scrollView = zoomScrollView else { return }
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }

        let targetScale = min(3, scrollView.maximumZoomScale)
        let point = gesture.location(in: imageView)
        let width = scrollView.bounds.width / targetScale
        let height = scrollView.bounds.height / targetScale
        let zoomRect = CGRect(
            x: point.x - width / 2,
            y: point.y - height / 2,
            width: width,
            height: height
        )
        scrollView.zoom(to: zoomRect, animated: true)
    }

    @objc private func playLivePhoto() {
        playLivePhotoFromBeginning()
        UIAccessibility.post(notification: .announcement, argument: "正在播放实况照片")
    }
}

private final class ReviewLivePlaybackButton: UIButton {
    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.38
        }
    }

    init() {
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.plain()
        configuration.title = "实况"
        configuration.image = UIImage(systemName: "livephoto")
        configuration.imagePadding = 4
        configuration.baseForegroundColor = StudioUIKitTheme.paper.withAlphaComponent(0.92)
        configuration.contentInsets = .zero
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var result = incoming
            result.font = StudioUIKitTheme.monospacedFont(size: 11, weight: .semibold)
            return result
        }
        self.configuration = configuration
        accessibilityLabel = "播放实况照片"
        accessibilityHint = "从头播放一次完整实况"
        imageView?.layer.shadowColor = UIColor.black.cgColor
        imageView?.layer.shadowOpacity = 0.55
        imageView?.layer.shadowRadius = 2
        imageView?.layer.shadowOffset = .zero
        titleLabel?.layer.shadowColor = UIColor.black.cgColor
        titleLabel?.layer.shadowOpacity = 0.55
        titleLabel?.layer.shadowRadius = 2
        titleLabel?.layer.shadowOffset = .zero
        alpha = 0.38
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitted = super.sizeThatFits(size)
        return CGSize(width: fitted.width, height: 22)
    }
}

private final class ReviewEdgeTag: UIView {
    private let label = UILabel()

    var text: String {
        get { label.text ?? "" }
        set { label.text = newValue }
    }

    init(text: String) {
        super.init(frame: .zero)
        self.text = text
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false

        label.textColor = StudioUIKitTheme.paper.withAlphaComponent(0.92)
        label.font = StudioUIKitTheme.monospacedFont(size: 11, weight: .semibold)
        label.textAlignment = .left
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.55
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        label.layer.masksToBounds = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textSize = label.sizeThatFits(size)
        return CGSize(width: textSize.width + 2, height: 22)
    }
}
