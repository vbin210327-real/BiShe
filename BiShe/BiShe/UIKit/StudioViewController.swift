import Combine
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// The shooting studio is deliberately a single, long-lived UIKit view tree.
/// The AVCapture preview layer and reference CALayer stay mounted while the
/// photographer adjusts the horizontal seam.
@MainActor
final class StudioViewController: UIViewController, PHPickerViewControllerDelegate {
    private let camera = CameraModel()
    private let referenceStore = ReferenceImageStore()
    private let preferences = StudioPreferences()
    private let photoWriter = PhotoLibraryWriter()
    private let appReviewPrompt = AppReviewPromptCoordinator()
    private var cancellables = Set<AnyCancellable>()

    private let canvasView = UIView()
    private let referenceSplitView = ReferenceCanvasView(showsEmptyState: true, allowsInteraction: true)
    private let cameraContainer = UIView()
    private let cameraPreviewView = CameraPreviewView()
    private let cameraStateView = CameraStateView()
    private let gridView = RuleOfThirdsOverlayView()
    private let seamControl = SplitSeamControl()
    private let shutterFlashView = UIView()

    private let statusButton = UIButton(type: .system)
    private let bottomRail = UIView()
    private let thumbnailButton = UIButton(type: .custom)
    private let shutterControl = ShutterControl()
    private let controlsButton = StudioIconButton(
        symbol: "slider.horizontal.3",
        accessibilityLabel: "拍摄控制"
    )
    private let switchCameraButton = StudioIconButton(
        symbol: "arrow.triangle.2.circlepath.camera.fill",
        accessibilityLabel: "切换前后镜头"
    )

    private var splitFraction: CGFloat = 0.5
    private var lastLayoutSignature: LayoutSignature?
    private var isReviewPresented = false
    private var statusGeneration = 0
    private var statusOpensSettings = false
    private var pendingCapturePresentation: CapturePresentation?
    private weak var captureControlsPanel: CaptureControlsPanelViewController?

    private struct CapturePresentation {
        let displayAspectRatio: CGFloat
        let splitFraction: CGFloat
        let referencePresentation: ReferencePresentationState?
    }

    private struct CaptureDisplayGeometry {
        let width: Int
        let height: Int

        var aspectRatio: CGFloat {
            CGFloat(width) / CGFloat(height)
        }
    }

    private struct LayoutSignature: Equatable {
        let bounds: CGRect
        let safeInsets: UIEdgeInsets
        let fraction: CGFloat
        let displayAspectRatio: CGFloat
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureAppearance()
        configureHierarchy()
        configureControls()
        connectCameraPreview()
        bindState()
        registerLifecycleNotifications()
        applyReferenceImage(referenceStore.image)
        updateCameraState()
        updateCaptureControls()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startLiveServicesIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutStudio(force: false)
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        lastLayoutSignature = nil
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.layoutStudio(force: true)
        })
        super.viewWillTransition(to: size, with: coordinator)
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureAppearance() {
        view.backgroundColor = StudioUIKitTheme.ink
        view.isOpaque = true

        canvasView.backgroundColor = .black
        canvasView.clipsToBounds = true
        cameraContainer.backgroundColor = StudioUIKitTheme.ink
        cameraContainer.clipsToBounds = true

        shutterFlashView.backgroundColor = .white
        shutterFlashView.alpha = 0
        shutterFlashView.isUserInteractionEnabled = false

        bottomRail.backgroundColor = StudioUIKitTheme.ink.withAlphaComponent(0.985)
        bottomRail.layer.borderWidth = 0
        configureStatusButton()
        configureThumbnailButton()
    }

    private func configureHierarchy() {
        view.addSubview(canvasView)
        canvasView.addSubview(referenceSplitView)
        canvasView.addSubview(cameraContainer)
        cameraContainer.addSubview(cameraPreviewView)
        cameraContainer.addSubview(cameraStateView)
        canvasView.addSubview(gridView)
        canvasView.addSubview(seamControl)
        canvasView.addSubview(shutterFlashView)

        view.addSubview(statusButton)
        view.addSubview(bottomRail)
        bottomRail.addSubview(thumbnailButton)
        bottomRail.addSubview(shutterControl)
        bottomRail.addSubview(controlsButton)
        bottomRail.addSubview(switchCameraButton)

        // These views are frame-laid-out on purpose. It avoids a constraint pass
        // across the live AVCapture layer while the seam is being dragged.
        [statusButton, bottomRail, thumbnailButton,
         shutterControl, controlsButton, switchCameraButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = true
        }
    }

    private func configureControls() {
        seamControl.fraction = splitFraction
        seamControl.layout = .topBottom
        seamControl.addTarget(self, action: #selector(seamChanged), for: .valueChanged)
        seamControl.addTarget(self, action: #selector(seamInteractionEnded), for: .editingDidEnd)

        thumbnailButton.addTarget(self, action: #selector(pickReference), for: .touchUpInside)
        shutterControl.addTarget(self, action: #selector(takePhoto), for: .touchUpInside)
        controlsButton.addTarget(self, action: #selector(showCaptureControls), for: .touchUpInside)
        switchCameraButton.addTarget(self, action: #selector(switchCamera), for: .touchUpInside)
        statusButton.addTarget(self, action: #selector(statusTapped), for: .touchUpInside)

        referenceSplitView.onPickReference = { [weak self] in self?.presentRecentReferencePicker() }

        cameraStateView.onAction = { [weak self] in
            guard let self else { return }
            if self.camera.authorizationStatus == .denied || self.camera.authorizationStatus == .restricted {
                self.openSystemSettings()
            } else {
                Task { await self.camera.start() }
            }
        }
    }

    private func configureStatusButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.78)
        configuration.baseForegroundColor = StudioUIKitTheme.paper
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)
        statusButton.configuration = configuration
        statusButton.titleLabel?.font = StudioUIKitTheme.roundedFont(size: 12, weight: .semibold)
        statusButton.isHidden = true
        statusButton.layer.borderWidth = 0.5
        statusButton.layer.borderColor = StudioUIKitTheme.hairline.cgColor
    }

    private func configureThumbnailButton() {
        thumbnailButton.backgroundColor = StudioUIKitTheme.liftedInk
        thumbnailButton.layer.cornerRadius = 10
        thumbnailButton.layer.cornerCurve = .continuous
        thumbnailButton.layer.borderWidth = 0.5
        thumbnailButton.layer.borderColor = StudioUIKitTheme.paper.withAlphaComponent(0.42).cgColor
        thumbnailButton.clipsToBounds = true
        thumbnailButton.imageView?.contentMode = .scaleAspectFill
        thumbnailButton.accessibilityLabel = "选择参考图"
    }

    private func connectCameraPreview() {
        cameraPreviewView.setSession(camera.previewSession)
        cameraPreviewView.currentZoomFactor = { [weak self] in self?.camera.zoomFactor ?? 1 }
        cameraPreviewView.currentDisplayZoomFactor = { [weak self] in self?.camera.displayZoomFactor ?? 1 }
        cameraPreviewView.onZoom = { [weak self] factor in
            self?.camera.setZoomFactor(factor)
        }
        cameraPreviewView.onFocusRequest = { [weak self] point, mode in
            guard let self, camera.isRunning else { return nil }
            return camera.focus(at: point, mode: mode)
        }
        cameraPreviewView.onCaptureRotationChange = { [weak self] angle in
            self?.camera.updateCaptureRotationAngle(angle)
        }
    }

    private func bindState() {
        referenceStore.$image
            .removeDuplicates(by: { $0 === $1 })
            .sink { [weak self] in self?.applyReferenceImage($0) }
            .store(in: &cancellables)

        referenceStore.$isLoading
            .removeDuplicates()
            .sink { [weak self] loading in self?.referenceSplitView.setLoading(loading) }
            .store(in: &cancellables)

        referenceStore.$errorMessage
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.showStatus(message, symbol: "exclamationmark.triangle.fill", color: StudioUIKitTheme.warning)
            }
            .store(in: &cancellables)

        preferences.$referenceFit
            .removeDuplicates()
            .sink { [weak self] fit in
                self?.referenceSplitView.setFit(fit)
                DispatchQueue.main.async { [weak self] in
                    self?.refreshCaptureControlsPanel()
                }
            }
            .store(in: &cancellables)

        preferences.$captureAspectRatio
            .removeDuplicates()
            .sink { [weak self] _ in
                // @Published emits before didSet. Defer one run-loop turn so
                // layout reads the newly persisted ratio rather than the old one.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    refreshCaptureControlsPanel()
                    lastLayoutSignature = nil
                    UIView.performWithoutAnimation { self.layoutStudio(force: true) }
                }
            }
            .store(in: &cancellables)

        preferences.$showsGrid
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.updateCompositionTools()
                    self?.refreshCaptureControlsPanel()
                }
            }
            .store(in: &cancellables)

        preferences.$livePhotoEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled, preferences.captureAspectRatio != .fourThree {
                    preferences.captureAspectRatio = .fourThree
                }
                DispatchQueue.main.async { [weak self] in
                    self?.refreshCaptureControlsPanel()
                }
                Task { [weak self] in
                    guard let self else { return }
                    _ = await camera.setLivePhotoAudioEnabled(enabled)
                }
            }
            .store(in: &cancellables)

        camera.$authorizationStatus
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.updateCameraState() }
            }
            .store(in: &cancellables)

        camera.$sessionState
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.updateCameraState()
                    self?.updateCompositionTools()
                }
            }
            .store(in: &cancellables)

        camera.$activeDeviceUniqueID
            .removeDuplicates()
            .sink { [weak self] uniqueID in self?.cameraPreviewView.setActiveDevice(uniqueID: uniqueID) }
            .store(in: &cancellables)

        camera.$flashMode
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.refreshCaptureControlsPanel() }
            }
            .store(in: &cancellables)

        camera.$hasFlash
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.refreshCaptureControlsPanel() }
            }
            .store(in: &cancellables)

        camera.$supportsLivePhoto
            .removeDuplicates()
            .sink { [weak self] supported in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    refreshCaptureControlsPanel()
                    if supported, preferences.livePhotoEnabled {
                        Task { [weak self] in
                            guard let self else { return }
                            _ = await camera.setLivePhotoAudioEnabled(true)
                        }
                    }
                }
            }
            .store(in: &cancellables)

        camera.$focusState
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                cameraPreviewView.renderFocusState(state)
                if case .adjusting = state {
                    StudioHaptics.alignment(enabled: preferences.haptics)
                }
            }
            .store(in: &cancellables)

        camera.$canSwitchCamera
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.updateCaptureControls() }
            }
            .store(in: &cancellables)

        camera.$isSwitchingCamera
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.updateCaptureControls() }
            }
            .store(in: &cancellables)

        camera.$isRunning
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.updateCameraState()
                    self?.updateCaptureControls()
                    self?.updateCompositionTools()
                }
            }
            .store(in: &cancellables)

        camera.$isCapturing
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.updateCaptureControls() }
            }
            .store(in: &cancellables)

        camera.$isProcessingPhoto
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.updateCaptureControls() }
            }
            .store(in: &cancellables)

        camera.$isCaptureGeometryReady
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.updateCaptureControls() }
            }
            .store(in: &cancellables)

        camera.$shutterPulse
            .dropFirst()
            .sink { [weak self] _ in self?.playShutterFlash() }
            .store(in: &cancellables)

        camera.$capturedImage
            .compactMap { $0 }
            .sink { [weak self] image in
                guard let self, let data = camera.capturedPhotoData else { return }
                let livePhotoMovieURL = camera.detachCapturedLivePhotoMovieURL()
                let presentation = pendingCapturePresentation ?? CapturePresentation(
                    displayAspectRatio: currentDisplayAspectRatio,
                    splitFraction: splitFraction,
                    referencePresentation: referenceSplitView.presentationState
                )
                pendingCapturePresentation = nil
                receiveCapturedPhoto(
                    image: image,
                    data: data,
                    livePhotoMovieURL: livePhotoMovieURL,
                    presentation: presentation
                )
            }
            .store(in: &cancellables)

        camera.$issue
            .compactMap { $0 }
            .sink { [weak self] issue in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.camera.isRunning else { return }
                    self.pendingCapturePresentation = nil
                    self.showStatus(issue.message, symbol: "exclamationmark.triangle.fill", color: StudioUIKitTheme.warning)
                }
            }
            .store(in: &cancellables)

        photoWriter.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.handleSaveState(state) }
            .store(in: &cancellables)
    }

    private func registerLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    private func layoutStudio(force: Bool) {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let safe = view.safeAreaInsets
        let landscape = bounds.width > bounds.height
        let railContentHeight: CGFloat = landscape ? 80 : 102
        let railHeight = railContentHeight + safe.bottom
        let railTop = bounds.maxY - railHeight
        canvasView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: railTop)
        bottomRail.frame = CGRect(x: 0, y: railTop, width: bounds.width, height: railHeight)

        let signature = LayoutSignature(
            bounds: bounds,
            safeInsets: safe,
            fraction: splitFraction,
            displayAspectRatio: currentDisplayAspectRatio
        )
        guard force || signature != lastLayoutSignature else { return }
        lastLayoutSignature = signature

        layoutCanvas()
        layoutBottomRail(contentHeight: railContentHeight)
        layoutFloatingStatus()
    }

    private func layoutCanvas() {
        let bounds = canvasView.bounds
        let allowedRange: ClosedRange<CGFloat> = bounds.height < 500 ? 0.45...0.55 : 0.24...0.64
        seamControl.allowedRange = allowedRange
        if abs(seamControl.fraction - splitFraction) > 0.0005 {
            seamControl.fraction = splitFraction
        }
        // A rotation can narrow the valid range. Keep the model and the drawn
        // seam on the exact same clamped value.
        splitFraction = seamControl.fraction

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let seamY = (bounds.height * splitFraction).rounded(.toNearestOrAwayFromZero)
        referenceSplitView.frame = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: seamY
        )
        let cameraStage = CGRect(
            x: bounds.minX,
            y: bounds.minY + seamY,
            width: bounds.width,
            height: bounds.height - seamY
        )
        cameraContainer.frame = aspectFitRect(
            aspectRatio: currentDisplayAspectRatio,
            inside: cameraStage
        )

        cameraPreviewView.frame = cameraContainer.bounds
        cameraStateView.frame = cameraContainer.bounds
        gridView.frame = cameraContainer.frame
        seamControl.frame = bounds
        shutterFlashView.frame = bounds
        CATransaction.commit()
    }

    private func layoutBottomRail(contentHeight: CGFloat) {
        let width = bottomRail.bounds.width
        let centerY = contentHeight / 2
        let shutterX = width / 2

        thumbnailButton.frame = CGRect(x: 22, y: centerY - 25, width: 50, height: 50)
        shutterControl.frame = CGRect(x: shutterX - 38, y: centerY - 38, width: 76, height: 76)
        switchCameraButton.frame = CGRect(x: width - 58, y: centerY - 22, width: 44, height: 44)
        controlsButton.frame = CGRect(x: width - 110, y: centerY - 22, width: 44, height: 44)
    }

    private func layoutFloatingStatus() {
        let railTop = bottomRail.frame.minY
        let statusWidth = min(max(statusButton.intrinsicContentSize.width, 150), view.bounds.width - 36)
        statusButton.frame = CGRect(
            x: (view.bounds.width - statusWidth) / 2,
            y: railTop - 50,
            width: statusWidth,
            height: 38
        )
    }

    private func applyReferenceImage(_ image: UIImage?) {
        referenceSplitView.setImage(image)
        updateThumbnail(image)
        refreshCaptureControlsPanel()
        lastLayoutSignature = nil
        layoutStudio(force: true)
    }

    private func updateThumbnail(_ image: UIImage?) {
        if let image {
            thumbnailButton.setImage(image, for: .normal)
            thumbnailButton.imageView?.contentMode = .scaleAspectFill
            thumbnailButton.accessibilityLabel = "更换参考图"
        } else {
            let configuration = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
            thumbnailButton.setImage(UIImage(systemName: "photo.badge.plus", withConfiguration: configuration), for: .normal)
            thumbnailButton.tintColor = StudioUIKitTheme.registration
            thumbnailButton.imageView?.contentMode = .center
            thumbnailButton.accessibilityLabel = "选择参考图"
        }
    }

    private func updateCameraState() {
        let state: CameraStateView.State?
        switch camera.authorizationStatus {
        case .notDetermined:
            state = .permission
        case .requesting:
            state = .opening
        case .denied, .restricted:
            state = .denied
        case .authorized:
            switch camera.sessionState {
            case .running:
                state = nil
            case .interrupted(let message):
                state = .interrupted(message)
            case .failed:
                state = camera.issue == .cameraUnavailable
                    ? .unavailable
                    : .interrupted(camera.issue?.message ?? "请重试。")
            case .idle, .configuring:
                state = .opening
            }
        }

        if let state {
            cameraStateView.displayState = state
            cameraStateView.isHidden = false
        } else {
            cameraStateView.isHidden = true
        }
    }

    private func updateCaptureControls() {
        shutterControl.isBusy = camera.isCapturing || camera.isProcessingPhoto
        shutterControl.isEnabled = camera.canCapture && !isReviewPresented
        switchCameraButton.isEnabled = camera.canSwitchCamera && !camera.isSwitchingCamera && !camera.isCapturing
        controlsButton.isEnabled = !camera.isCapturing && !camera.isProcessingPhoto && !isReviewPresented
    }

    private var currentDisplayAspectRatio: CGFloat {
        currentDisplayGeometry.aspectRatio
    }

    private var currentDisplayGeometry: CaptureDisplayGeometry {
        let isPortrait: Bool
        if let orientation = view.window?.windowScene?.interfaceOrientation,
           orientation != .unknown {
            isPortrait = orientation.isPortrait
        } else {
            isPortrait = view.bounds.height >= view.bounds.width
        }
        let selected = preferences.captureAspectRatio
        return isPortrait
            ? CaptureDisplayGeometry(width: selected.height, height: selected.width)
            : CaptureDisplayGeometry(width: selected.width, height: selected.height)
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

    private func updateCompositionTools() {
        gridView.isHidden = !preferences.showsGrid || !camera.isRunning
    }

    private var captureControlsState: CaptureControlsState {
        let livePhotoActive = preferences.livePhotoEnabled && camera.supportsLivePhoto
        return CaptureControlsState(
            aspectRatios: CaptureAspectRatio.presets,
            selectedAspectRatio: preferences.captureAspectRatio,
            flashMode: camera.flashMode,
            hasFlash: camera.hasFlash,
            showsGrid: preferences.showsGrid,
            referenceFit: preferences.referenceFit,
            livePhotoEnabled: livePhotoActive,
            supportsLivePhoto: camera.supportsLivePhoto
        )
    }

    private func refreshCaptureControlsPanel() {
        captureControlsPanel?.update(state: captureControlsState)
    }

    private func startLiveServicesIfNeeded() {
        guard !isReviewPresented,
              UIApplication.shared.applicationState == .active else { return }
        if camera.authorizationStatus == .authorized {
            Task { await camera.start() }
        }
    }

    private func stopLiveServices() {
        camera.stop()
    }

    private func receiveCapturedPhoto(
        image: UIImage,
        data: Data,
        livePhotoMovieURL: URL?,
        presentation: CapturePresentation
    ) {
        guard !isReviewPresented else {
            if let livePhotoMovieURL {
                try? FileManager.default.removeItem(at: livePhotoMovieURL)
            }
            return
        }
        photoWriter.reset()
        camera.clearCapturedPhoto()
        presentReview(
            image: image,
            data: data,
            livePhotoMovieURL: livePhotoMovieURL,
            presentation: presentation
        )
    }

    private func presentReview(
        image: UIImage,
        data: Data,
        livePhotoMovieURL: URL?,
        presentation: CapturePresentation
    ) {
        guard !isReviewPresented else { return }
        isReviewPresented = true
        stopLiveServices()
        updateCaptureControls()

        let controller = CaptureReviewViewController(
            capturedImage: image,
            capturedData: data,
            livePhotoMovieURL: livePhotoMovieURL,
            captureAspectRatio: presentation.displayAspectRatio,
            initialSplitFraction: presentation.splitFraction,
            referenceImage: referenceStore.image,
            referencePresentation: presentation.referencePresentation,
            preferences: preferences,
            photoWriter: photoWriter
        )
        controller.modalPresentationStyle = .fullScreen
        controller.onRetake = { [weak self, weak controller] in
            controller?.dismiss(animated: true) { self?.finishReview() }
        }
        controller.onFinish = { [weak self, weak controller] in
            controller?.dismiss(animated: true) { self?.finishReview() }
        }
        present(controller, animated: true) { [weak self, weak controller] in
            self?.appReviewPrompt.registerSuccessfulCapture(
                in: controller?.view.window?.windowScene
            )
        }
    }

    private func finishReview() {
        isReviewPresented = false
        photoWriter.reset()
        updateCaptureControls()
        startLiveServicesIfNeeded()
    }

    private func playShutterFlash() {
        shutterFlashView.layer.removeAllAnimations()
        shutterFlashView.alpha = 0.70
        UIView.animate(
            withDuration: 0.18,
            delay: 0.045,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            self.shutterFlashView.alpha = 0
        }
    }

    private func handleSaveState(_ state: PhotoSaveState) {
        switch state {
        case .denied:
            showStatus("无法保存·前往设置", symbol: "exclamationmark.triangle.fill", color: StudioUIKitTheme.warning, duration: nil, opensSettings: true)
        case .failed(let message):
            showStatus(message, symbol: "exclamationmark.triangle.fill", color: StudioUIKitTheme.warning)
        case .idle, .saving, .saved:
            break
        }
    }

    private func showStatus(
        _ text: String,
        symbol: String,
        color: UIColor,
        duration: TimeInterval? = 1.8,
        opensSettings: Bool = false
    ) {
        statusGeneration &+= 1
        let generation = statusGeneration
        statusOpensSettings = opensSettings
        statusButton.configuration?.title = text
        statusButton.configuration?.image = UIImage(systemName: symbol)
        statusButton.configuration?.imagePadding = 7
        statusButton.configuration?.baseForegroundColor = color
        statusButton.isHidden = false
        layoutFloatingStatus()
        statusButton.alpha = 0
        statusButton.transform = CGAffineTransform(translationX: 0, y: 7)
        UIView.animate(withDuration: 0.18) {
            self.statusButton.alpha = 1
            self.statusButton.transform = .identity
        }

        guard let duration else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, statusGeneration == generation else { return }
            UIView.animate(withDuration: 0.18) {
                self.statusButton.alpha = 0
            } completion: { _ in
                guard self.statusGeneration == generation else { return }
                self.statusButton.isHidden = true
                self.statusOpensSettings = false
            }
        }
    }

    private func presentRecentReferencePicker() {
        guard presentedViewController == nil else { return }

        let controller = ReferencePhotoDrawerViewController()
        controller.onSelectAsset = { [weak self, weak controller] asset in
            controller?.dismiss(animated: true) {
                self?.importReference(from: asset)
            }
        }
        controller.onOpenAllPhotos = { [weak self, weak controller] in
            controller?.dismiss(animated: true) {
                self?.presentPhotoPicker()
            }
        }

        if traitCollection.horizontalSizeClass == .regular {
            controller.modalPresentationStyle = .formSheet
            controller.preferredContentSize = CGSize(width: 520, height: 520)
        } else if let sheet = controller.sheetPresentationController {
            let identifier = UISheetPresentationController.Detent.Identifier("recent-photos")
            sheet.detents = [
                .custom(identifier: identifier) { context in
                    min(context.maximumDetentValue, min(470, max(360, context.maximumDetentValue * 0.56)))
                }
            ]
            sheet.selectedDetentIdentifier = identifier
            sheet.prefersGrabberVisible = false
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.preferredCornerRadius = 30
            sheet.largestUndimmedDetentIdentifier = identifier
        }
        present(controller, animated: true)
    }

    private func presentPhotoPicker() {
        guard presentedViewController == nil else { return }
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        picker.modalPresentationStyle = .fullScreen
        present(picker, animated: true)
    }

    private func importReference(from asset: PHAsset) {
        referenceSplitView.setLoading(true)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { [weak self] data, _, _, info in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let error = info?[PHImageErrorKey] as? Error
                await finishReferenceImport(data: data, error: error)
            }
        }
    }

    private func finishReferenceImport(data: Data?, error: Error?) async {
        if let data {
            await referenceStore.importData(data)
            if referenceStore.hasReference {
                StudioHaptics.alignment(enabled: preferences.haptics)
                UIAccessibility.post(notification: .announcement, argument: "参考图已更新")
            }
        } else {
            referenceSplitView.setLoading(false)
            showStatus(
                error?.localizedDescription ?? "这张图片没能打开。",
                symbol: "exclamationmark.triangle.fill",
                color: StudioUIKitTheme.warning
            )
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        referenceSplitView.setLoading(true)
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await finishReferenceImport(data: data, error: error)
            }
        }
    }

    @objc private func pickReference() { presentRecentReferencePicker() }

    @objc private func seamChanged() {
        splitFraction = seamControl.fraction
        lastLayoutSignature = nil
        // The top chrome and bottom rail do not depend on a vertical split.
        // Relayout only the canvas to keep live dragging lightweight.
        UIView.performWithoutAnimation { layoutCanvas() }
    }

    @objc private func seamInteractionEnded() {
        // Commit the final fixed-ratio preview frame before a quick shutter tap.
        cameraPreviewView.setNeedsLayout()
        cameraPreviewView.layoutIfNeeded()
    }

    @objc private func cycleFlash() {
        camera.cycleFlashMode()
        StudioHaptics.alignment(enabled: preferences.haptics)
    }

    @objc private func toggleGrid() {
        preferences.showsGrid.toggle()
        StudioHaptics.alignment(enabled: preferences.haptics)
    }

    @objc private func showCaptureControls() {
        guard presentedViewController == nil else { return }

        let controller = CaptureControlsPanelViewController(state: captureControlsState)
        captureControlsPanel = controller

        controller.onSelectAspectRatio = { [weak self] ratio in
            guard let self else { return }
            preferences.captureAspectRatio = ratio
            StudioHaptics.alignment(enabled: preferences.haptics)
            refreshCaptureControlsPanel()
        }
        controller.onCycleFlash = { [weak self] in self?.cycleFlash() }
        controller.onToggleGrid = { [weak self] in self?.toggleGrid() }
        controller.onSelectReferenceFit = { [weak self] fit in
            guard let self else { return }
            preferences.referenceFit = fit
            StudioHaptics.alignment(enabled: preferences.haptics)
            refreshCaptureControlsPanel()
        }
        controller.onToggleLivePhoto = { [weak self] in
            guard let self, camera.supportsLivePhoto else { return }
            let enablesLivePhoto = !preferences.livePhotoEnabled
            if enablesLivePhoto {
                preferences.captureAspectRatio = .fourThree
            }
            preferences.livePhotoEnabled = enablesLivePhoto
            StudioHaptics.alignment(enabled: preferences.haptics)
            refreshCaptureControlsPanel()

            Task { [weak self] in
                guard let self else { return }
                let hasAudio = await camera.setLivePhotoAudioEnabled(enablesLivePhoto)
                if enablesLivePhoto, !hasAudio {
                    showStatus(
                        "麦克风未授权，实况将不包含声音",
                        symbol: "mic.slash",
                        color: StudioUIKitTheme.mutedPaper
                    )
                }
            }
        }
        if traitCollection.horizontalSizeClass == .regular {
            controller.modalPresentationStyle = .formSheet
            controller.preferredContentSize = CGSize(width: 420, height: 240)
        } else if let sheet = controller.sheetPresentationController {
            let identifier = UISheetPresentationController.Detent.Identifier("capture-controls")
            sheet.detents = [
                .custom(identifier: identifier) { context in min(240, context.maximumDetentValue) },
                .large()
            ]
            sheet.selectedDetentIdentifier = identifier
            sheet.prefersGrabberVisible = false
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.preferredCornerRadius = 28
        }
        present(controller, animated: true)
    }

    @objc private func takePhoto() {
        guard shutterControl.isEnabled else { return }
        StudioHaptics.shutter(enabled: preferences.haptics)
        let geometry = currentDisplayGeometry
        let presentation = CapturePresentation(
            displayAspectRatio: geometry.aspectRatio,
            splitFraction: splitFraction,
            referencePresentation: referenceSplitView.presentationState
        )
        pendingCapturePresentation = presentation
        camera.capturePhoto(
            displayAspectWidth: geometry.width,
            displayAspectHeight: geometry.height,
            livePhotoEnabled: preferences.livePhotoEnabled && camera.supportsLivePhoto
        )
    }

    @objc private func switchCamera() {
        camera.switchCamera()
        StudioHaptics.alignment(enabled: preferences.haptics)
    }

    @objc private func statusTapped() {
        if statusOpensSettings { openSystemSettings() }
    }

    @objc private func applicationDidBecomeActive() {
        startLiveServicesIfNeeded()
    }

    @objc private func applicationWillResignActive() {
        stopLiveServices()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
