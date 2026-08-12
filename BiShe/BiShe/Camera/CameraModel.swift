@preconcurrency import AVFoundation
import Combine
import UIKit

nonisolated enum CameraAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case requesting
    case authorized
    case denied
    case restricted
}

nonisolated enum CameraSessionState: Equatable, Sendable {
    case idle
    case configuring
    case running
    case interrupted(String)
    case failed
}

nonisolated enum CameraPosition: String, CaseIterable, Sendable {
    case back
    case front

    init(_ position: AVCaptureDevice.Position) {
        self = position == .front ? .front : .back
    }

    var symbol: String {
        switch self {
        case .back: "camera"
        case .front: "person.crop.rectangle"
        }
    }
}

nonisolated enum CameraFlashMode: String, CaseIterable, Sendable {
    case off
    case auto
    case on

    var title: String {
        switch self {
        case .off: "关"
        case .auto: "自动"
        case .on: "开"
        }
    }

    var symbol: String {
        switch self {
        case .off: "bolt.slash.fill"
        case .auto: "bolt.badge.automatic.fill"
        case .on: "bolt.fill"
        }
    }

    var avFoundationValue: AVCaptureDevice.FlashMode {
        switch self {
        case .off: .off
        case .auto: .auto
        case .on: .on
        }
    }
}

nonisolated struct CameraZoomPreset: Identifiable, Hashable, Sendable {
    let factor: CGFloat
    let label: String

    var id: String { "\(factor)-\(label)" }
}

nonisolated enum CameraFocusMode: Equatable, Sendable {
    case transient
    case locked
}

nonisolated enum CameraFocusState: Equatable, Sendable {
    case idle
    case adjusting(requestID: UInt64, mode: CameraFocusMode)
    case focused(requestID: UInt64)
    case locked(requestID: UInt64)
    case exposureOnly(requestID: UInt64, locked: Bool)
    case unsupported(requestID: UInt64)
    case failed(requestID: UInt64)

    var requestID: UInt64? {
        switch self {
        case .idle: nil
        case .adjusting(let requestID, _),
             .focused(let requestID),
             .locked(let requestID),
             .exposureOnly(let requestID, _),
             .unsupported(let requestID),
             .failed(let requestID): requestID
        }
    }
}

nonisolated enum CameraIssue: Error, Identifiable, Equatable, Sendable {
    case permissionDenied
    case cameraUnavailable
    case configurationFailed(String)
    case sessionNotRunning
    case focusFailed
    case zoomFailed
    case captureFailed(String)
    case runtimeError(String)

    var id: String {
        switch self {
        case .permissionDenied: "permission-denied"
        case .cameraUnavailable: "camera-unavailable"
        case .configurationFailed(let detail): "configuration-\(detail)"
        case .sessionNotRunning: "session-not-running"
        case .focusFailed: "focus-failed"
        case .zoomFailed: "zoom-failed"
        case .captureFailed(let detail): "capture-\(detail)"
        case .runtimeError(let detail): "runtime-\(detail)"
        }
    }

    var title: String {
        switch self {
        case .permissionDenied: "需要相机权限"
        case .cameraUnavailable: "没有可用镜头"
        case .configurationFailed: "相机打开失败"
        case .sessionNotRunning: "相机还没准备好"
        case .focusFailed: "对焦失败"
        case .zoomFailed: "变焦失败"
        case .captureFailed: "拍摄失败"
        case .runtimeError: "相机暂不可用"
        }
    }

    var message: String {
        switch self {
        case .permissionDenied:
            "请在系统设置中允许“比摄”使用相机。"
        case .cameraUnavailable:
            "没有找到可用的相机。模拟器无法完整测试拍照，请使用真机。"
        case .configurationFailed(let detail), .captureFailed(let detail), .runtimeError(let detail):
            detail
        case .sessionNotRunning:
            "等取景画面出现后再拍一次。"
        case .focusFailed:
            "镜头无法在这个位置对焦。"
        case .zoomFailed:
            "镜头无法切换到这个焦段。"
        }
    }
}

@MainActor
final class CameraModel: ObservableObject {
    private struct PendingDisplayAspect: Sendable {
        let width: Int
        let height: Int
    }

    @Published private(set) var authorizationStatus: CameraAuthorizationStatus
    @Published private(set) var sessionState: CameraSessionState = .idle
    @Published private(set) var issue: CameraIssue?

    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isProcessingPhoto = false
    @Published private(set) var isSwitchingCamera = false
    @Published private(set) var isCaptureGeometryReady = false

    @Published private(set) var cameraPosition: CameraPosition = .back
    @Published private(set) var activeDeviceUniqueID: String?
    @Published private(set) var hasFlash = false
    @Published private(set) var canSwitchCamera = false
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var minimumZoomFactor: CGFloat = 1
    @Published private(set) var maximumZoomFactor: CGFloat = 1
    @Published private(set) var zoomPresets: [CameraZoomPreset] = [
        CameraZoomPreset(factor: 1, label: "1×")
    ]
    @Published private(set) var flashMode: CameraFlashMode = .off
    @Published private(set) var supportsLivePhoto = false

    /// The decoded image drives the review surface. The original encoded data remains
    /// available separately so PhotoKit and sharing do not recompress it.
    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var capturedPhotoData: Data?
    @Published private(set) var capturedLivePhotoMovieURL: URL?
    @Published private(set) var shutterPulse = 0
    @Published private(set) var focusState: CameraFocusState = .idle

    let previewSession: AVCaptureSession

    private let engine: CameraEngine
    private var captureRotationAngle: CGFloat?
    private var pendingDisplayAspect: PendingDisplayAspect?
    private var focusRequestID: UInt64 = 0

    init() {
        let engine = CameraEngine()
        self.engine = engine
        previewSession = engine.previewSession
        authorizationStatus = Self.authorizationStatus(for: AVCaptureDevice.authorizationStatus(for: .video))

        engine.setEventHandler { [weak self] event in
            // CameraEngine emits exclusively from one serial queue. Dispatching
            // directly onto the main queue preserves that FIFO order.
            DispatchQueue.main.async { [weak self] in
                self?.handle(event)
            }
        }
    }

    deinit {
        engine.stop()
    }

    var canCapture: Bool {
        authorizationStatus == .authorized
            && isRunning
            && !isCapturing
            && !isProcessingPhoto
            && !isSwitchingCamera
            && isCaptureGeometryReady
            && capturedPhotoData == nil
    }

    func start() async {
        clearIssue()

        let systemStatus = AVCaptureDevice.authorizationStatus(for: .video)
        authorizationStatus = Self.authorizationStatus(for: systemStatus)

        switch systemStatus {
        case .authorized:
            beginSession()
        case .notDetermined:
            authorizationStatus = .requesting
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorizationStatus = granted ? .authorized : .denied
            if granted {
                beginSession()
            } else {
                sessionState = .failed
                issue = .permissionDenied
            }
        case .denied:
            sessionState = .failed
            issue = .permissionDenied
        case .restricted:
            sessionState = .failed
            issue = .permissionDenied
        @unknown default:
            authorizationStatus = .denied
            sessionState = .failed
            issue = .permissionDenied
        }
    }

    func stop() {
        focusState = .idle
        engine.stop()
    }

    /// Captures a photo and crops it to an explicit integer ratio expressed in
    /// display orientation. Integer components keep custom ratios exact at the
    /// final pixel level.
    func capturePhoto(
        displayAspectWidth: Int,
        displayAspectHeight: Int,
        livePhotoEnabled: Bool
    ) {
        guard canCapture else {
            if authorizationStatus == .authorized {
                issue = .sessionNotRunning
            }
            return
        }
        guard displayAspectWidth > 0, displayAspectHeight > 0 else {
            issue = .captureFailed("照片比例无效，请重新选择。")
            return
        }

        isCapturing = true
        pendingDisplayAspect = PendingDisplayAspect(
            width: displayAspectWidth,
            height: displayAspectHeight
        )
        engine.capturePhoto(
            flashMode: flashMode,
            rotationAngle: captureRotationAngle ?? 90,
            livePhotoEnabled: livePhotoEnabled && supportsLivePhoto
        )
    }

    func clearCapturedPhoto() {
        capturedImage = nil
        capturedPhotoData = nil
        if let capturedLivePhotoMovieURL {
            try? FileManager.default.removeItem(at: capturedLivePhotoMovieURL)
        }
        capturedLivePhotoMovieURL = nil
    }

    func detachCapturedLivePhotoMovieURL() -> URL? {
        defer { capturedLivePhotoMovieURL = nil }
        return capturedLivePhotoMovieURL
    }

    func switchCamera() {
        guard canSwitchCamera, !isCapturing, !isSwitchingCamera else { return }
        focusState = .idle
        isSwitchingCamera = true
        captureRotationAngle = nil
        refreshCaptureGeometryReadiness()
        flashMode = .off
        engine.switchCamera()
    }

    func cycleFlashMode() {
        guard hasFlash else {
            flashMode = .off
            return
        }

        switch flashMode {
        case .off: flashMode = .auto
        case .auto: flashMode = .on
        case .on: flashMode = .off
        }
    }

    func setFlashMode(_ mode: CameraFlashMode) {
        flashMode = hasFlash ? mode : .off
    }

    @discardableResult
    func focus(at devicePoint: CGPoint, mode: CameraFocusMode) -> UInt64 {
        focusRequestID &+= 1
        let requestID = focusRequestID
        engine.focus(at: devicePoint, mode: mode, requestID: requestID)
        return requestID
    }

    func setZoomFactor(_ factor: CGFloat, animated: Bool = false) {
        let clamped = min(max(factor, minimumZoomFactor), maximumZoomFactor)
        zoomFactor = clamped
        engine.setZoomFactor(clamped, animated: animated)
    }

    func selectZoomPreset(_ preset: CameraZoomPreset) {
        setZoomFactor(preset.factor, animated: true)
    }

    var displayZoomFactor: CGFloat {
        let oneTimesHardwareFactor = zoomPresets.first(where: { $0.label == "1×" })?.factor ?? 1
        return zoomFactor / max(oneTimesHardwareFactor, 0.01)
    }

    func setLivePhotoAudioEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            engine.setLivePhotoAudioEnabled(false)
            return true
        }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let authorized: Bool
        switch status {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            authorized = false
        @unknown default:
            authorized = false
        }
        engine.setLivePhotoAudioEnabled(authorized)
        return authorized
    }

    func clearIssue() {
        issue = nil
    }

    func updateCaptureRotationAngle(_ angle: CGFloat) {
        guard angle.isFinite else { return }
        if let captureRotationAngle, abs(captureRotationAngle - angle) < 0.01 { return }
        captureRotationAngle = angle
        refreshCaptureGeometryReadiness()
    }

    private func beginSession() {
        guard sessionState != .configuring else { return }
        sessionState = .configuring
        engine.configureAndStart()
    }

    private func handle(_ event: CameraEngine.Event) {
        switch event {
        case .configured(let capabilities):
            if activeDeviceUniqueID != capabilities.deviceUniqueID {
                captureRotationAngle = nil
                refreshCaptureGeometryReadiness()
            }
            cameraPosition = capabilities.position
            activeDeviceUniqueID = capabilities.deviceUniqueID
            hasFlash = capabilities.hasFlash
            canSwitchCamera = capabilities.canSwitchCamera
            minimumZoomFactor = capabilities.minimumZoomFactor
            maximumZoomFactor = capabilities.maximumZoomFactor
            zoomFactor = capabilities.zoomFactor
            zoomPresets = capabilities.zoomPresets
            supportsLivePhoto = capabilities.supportsLivePhoto
            isSwitchingCamera = false
            if !hasFlash {
                flashMode = .off
            }

        case .running(let running):
            isRunning = running
            sessionState = running ? .running : .idle
            if !running { focusState = .idle }

        case .focus(let state):
            focusState = state

        case .willCapture:
            shutterPulse &+= 1

        case .captured(let payload):
            isProcessingPhoto = true
            let displayAspect = pendingDisplayAspect
            Task.detached(priority: .userInitiated) { [weak self] in
                let processedData: Data?
                if payload.livePhotoMovieURL != nil {
                    // The photo and movie carry matching asset identifiers. Keep
                    // the photo bytes untouched or PhotoKit can no longer form a
                    // real Live Photo asset.
                    processedData = payload.photoData
                } else if let displayAspect {
                    processedData = try? PhotoCropper.crop(
                        payload.photoData,
                        displayAspectWidth: displayAspect.width,
                        displayAspectHeight: displayAspect.height
                    )
                } else {
                    processedData = nil
                }
                let reviewImage = processedData.flatMap(CapturePreviewDecoder.makePreview)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard let processedData, let reviewImage else {
                        if let movieURL = payload.livePhotoMovieURL {
                            try? FileManager.default.removeItem(at: movieURL)
                        }
                        issue = .captureFailed("照片没有按所选比例处理成功，请再拍一次。")
                        isProcessingPhoto = false
                        pendingDisplayAspect = nil
                        return
                    }
                    capturedPhotoData = processedData
                    capturedLivePhotoMovieURL = payload.livePhotoMovieURL
                    capturedImage = reviewImage
                    isProcessingPhoto = false
                    pendingDisplayAspect = nil
                }
            }

        case .captureFinished:
            isCapturing = false

        case .interrupted(let message):
            isRunning = false
            sessionState = .interrupted(message)

        case .interruptionEnded:
            if sessionState != .running {
                sessionState = .configuring
            }

        case .issue(let issue):
            self.issue = issue
            isCapturing = false
            isProcessingPhoto = false
            isSwitchingCamera = false
            pendingDisplayAspect = nil
            if let capturedLivePhotoMovieURL {
                try? FileManager.default.removeItem(at: capturedLivePhotoMovieURL)
                self.capturedLivePhotoMovieURL = nil
            }
            if !isRunning {
                sessionState = .failed
            }
        }
    }

    private func refreshCaptureGeometryReadiness() {
        let ready = captureRotationAngle != nil
        if isCaptureGeometryReady != ready {
            isCaptureGeometryReady = ready
        }
    }

    private static func authorizationStatus(for status: AVAuthorizationStatus) -> CameraAuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .denied
        }
    }
}

private nonisolated enum CapturePreviewDecoder {
    private static let maximumPixelSize: CGFloat = 2_560

    /// Builds a screen-sized, orientation-normalized image from the exact bytes
    /// used for saving and sharing. UIImageReader preserves the encoded color
    /// space/HDR preference instead of forcing P3/HDR captures through an 8-bit
    /// sRGB context, which made review differ visibly from Photos.
    static func makePreview(from data: Data) -> UIImage? {
        autoreleasepool {
            var configuration = UIImageReader.Configuration()
            configuration.preferredThumbnailSize = CGSize(
                width: maximumPixelSize,
                height: maximumPixelSize
            )
            configuration.preparesImagesForDisplay = true
            configuration.prefersHighDynamicRange = true
            return UIImageReader(configuration: configuration).image(data: data)
        }
    }
}
