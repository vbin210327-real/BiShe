@preconcurrency import AVFoundation
import Foundation

/// Everything that touches `AVCaptureSession`, its inputs, or its outputs lives on
/// `sessionQueue`. The class is `@unchecked Sendable` only because that invariant is
/// stronger than the Objective-C AVFoundation types can express to Swift.
nonisolated final class CameraEngine: NSObject, @unchecked Sendable {
    nonisolated struct CapturePayload: Sendable {
        let photoData: Data
        let livePhotoMovieURL: URL?
    }

    nonisolated struct Capabilities: Sendable {
        let position: CameraPosition
        let deviceUniqueID: String
        let hasFlash: Bool
        let canSwitchCamera: Bool
        let minimumZoomFactor: CGFloat
        let maximumZoomFactor: CGFloat
        let zoomFactor: CGFloat
        let zoomPresets: [CameraZoomPreset]
        let supportsLivePhoto: Bool
    }

    nonisolated enum Event: Sendable {
        case configured(Capabilities)
        case running(Bool)
        case willCapture
        case captured(CapturePayload)
        case captureFinished
        case interrupted(String)
        case interruptionEnded
        case focus(CameraFocusState)
        case issue(CameraIssue)
    }

    let previewSession = AVCaptureSession()

    private let sessionQueue = DispatchQueue(
        label: "com.linfanbin.bishe.camera.session",
        qos: .userInitiated
    )
    private let photoOutput = AVCapturePhotoOutput()

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var wantsToRun = false
    private var wantsLivePhotoAudio = false
    private var eventHandler: (@Sendable (Event) -> Void)?
    private var captureProcessors: [Int64: PhotoCaptureProcessor] = [:]
    private var activeFocusRequestID: UInt64?

    override init() {
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification,
            object: previewSession
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded(_:)),
            name: AVCaptureSession.interruptionEndedNotification,
            object: previewSession
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification,
            object: previewSession
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        sessionQueue.async { [weak self] in
            self?.eventHandler = handler
        }
    }

    func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            wantsToRun = true

            do {
                if !isConfigured {
                    try configureSession()
                } else if let device = videoInput?.device {
                    emit(.configured(capabilities(for: device)))
                }

                guard wantsToRun else { return }
                if !previewSession.isRunning {
                    previewSession.startRunning()
                }
                emit(.running(previewSession.isRunning))
            } catch let issue as CameraIssue {
                emit(.issue(issue))
            } catch {
                emit(.issue(.configurationFailed(error.localizedDescription)))
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            wantsToRun = false
            resetFocusAndExposure(emitIdle: true)
            if previewSession.isRunning {
                previewSession.stopRunning()
            }
            emit(.running(false))
        }
    }

    func focus(at devicePoint: CGPoint, mode: CameraFocusMode, requestID: UInt64) {
        sessionQueue.async { [weak self] in
            guard let self,
                  previewSession.isRunning,
                  let device = videoInput?.device else {
                self?.emit(.focus(.failed(requestID: requestID)))
                return
            }

            let point = CGPoint(
                x: min(max(devicePoint.x, 0), 1),
                y: min(max(devicePoint.y, 0), 1)
            )

            let supportsFocus = device.isFocusPointOfInterestSupported
                && (device.isFocusModeSupported(.autoFocus)
                    || device.isFocusModeSupported(.continuousAutoFocus))
            let supportsExposure = device.isExposurePointOfInterestSupported
                && (device.isExposureModeSupported(.autoExpose)
                    || device.isExposureModeSupported(.continuousAutoExposure))

            guard supportsFocus || supportsExposure else {
                emit(.focus(.unsupported(requestID: requestID)))
                return
            }

            activeFocusRequestID = requestID

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if supportsFocus {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    } else {
                        device.focusMode = .continuousAutoFocus
                    }
                }

                if supportsExposure {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    } else {
                        device.exposureMode = .continuousAutoExposure
                    }
                }

                device.isSubjectAreaChangeMonitoringEnabled = false
                emit(.focus(.adjusting(requestID: requestID, mode: mode)))
            } catch {
                activeFocusRequestID = nil
                emit(.focus(.failed(requestID: requestID)))
                return
            }

            let deadline = DispatchTime.now().uptimeNanoseconds + 1_600_000_000
            sessionQueue.asyncAfter(deadline: .now() + 0.12) { [weak self, weak device] in
                guard let self, let device else { return }
                finishFocusWhenSettled(
                    device: device,
                    requestID: requestID,
                    mode: mode,
                    supportsFocus: supportsFocus,
                    supportsExposure: supportsExposure,
                    deadline: deadline
                )
            }
        }
    }

    private func finishFocusWhenSettled(
        device: AVCaptureDevice,
        requestID: UInt64,
        mode: CameraFocusMode,
        supportsFocus: Bool,
        supportsExposure: Bool,
        deadline: UInt64
    ) {
        guard activeFocusRequestID == requestID,
              videoInput?.device.uniqueID == device.uniqueID else { return }

        let focusSettled = !supportsFocus || !device.isAdjustingFocus
        let exposureSettled = !supportsExposure || !device.isAdjustingExposure
        if (!focusSettled || !exposureSettled), DispatchTime.now().uptimeNanoseconds < deadline {
            sessionQueue.asyncAfter(deadline: .now() + 0.06) { [weak self, weak device] in
                guard let self, let device else { return }
                finishFocusWhenSettled(
                    device: device,
                    requestID: requestID,
                    mode: mode,
                    supportsFocus: supportsFocus,
                    supportsExposure: supportsExposure,
                    deadline: deadline
                )
            }
            return
        }

        switch mode {
        case .locked:
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if supportsFocus, device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                }
                if supportsExposure, device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                device.isSubjectAreaChangeMonitoringEnabled = false
                emit(.focus(
                    supportsFocus
                        ? .locked(requestID: requestID)
                        : .exposureOnly(requestID: requestID, locked: true)
                ))
            } catch {
                activeFocusRequestID = nil
                emit(.focus(.failed(requestID: requestID)))
            }

        case .transient:
            emit(.focus(
                supportsFocus
                    ? .focused(requestID: requestID)
                    : .exposureOnly(requestID: requestID, locked: false)
            ))
            sessionQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, activeFocusRequestID == requestID else { return }
                resetFocusAndExposure(emitIdle: true)
            }
        }
    }

    private func resetFocusAndExposure(emitIdle: Bool) {
        activeFocusRequestID = nil
        guard let device = videoInput?.device else {
            if emitIdle { emit(.focus(.idle)) }
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = center
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = center
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
        } catch {
            if emitIdle { emit(.focus(.idle)) }
            return
        }
        if emitIdle { emit(.focus(.idle)) }
    }

    func setZoomFactor(_ requestedFactor: CGFloat, animated: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = videoInput?.device else { return }

            let maximum = usefulMaximumZoomFactor(for: device)
            let zoom = min(max(requestedFactor, device.minAvailableVideoZoomFactor), maximum)

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if animated {
                    device.ramp(toVideoZoomFactor: zoom, withRate: 8)
                } else {
                    device.videoZoomFactor = zoom
                }

                emit(.configured(capabilities(for: device)))
            } catch {
                emit(.issue(.zoomFailed))
            }
        }
    }

    func setLivePhotoAudioEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if wantsLivePhotoAudio == enabled,
               (!enabled || audioInput != nil || !isConfigured) {
                return
            }
            wantsLivePhotoAudio = enabled
            guard isConfigured else { return }

            previewSession.beginConfiguration()
            defer { previewSession.commitConfiguration() }

            if enabled {
                addAudioInputIfPossible()
            } else if let audioInput {
                previewSession.removeInput(audioInput)
                self.audioInput = nil
            }
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self, isConfigured, let oldInput = videoInput else { return }

            resetFocusAndExposure(emitIdle: true)

            let desiredPosition: AVCaptureDevice.Position = oldInput.device.position == .back ? .front : .back
            guard let newDevice = preferredDevice(position: desiredPosition) else {
                emit(.issue(.cameraUnavailable))
                return
            }

            do {
                let newInput = try AVCaptureDeviceInput(device: newDevice)
                previewSession.beginConfiguration()
                previewSession.removeInput(oldInput)

                if previewSession.canAddInput(newInput) {
                    previewSession.addInput(newInput)
                    videoInput = newInput
                } else {
                    previewSession.addInput(oldInput)
                    previewSession.commitConfiguration()
                    emit(.issue(.configurationFailed("无法切换到这枚镜头。")))
                    return
                }

                previewSession.commitConfiguration()
                emit(.configured(capabilities(for: newDevice)))
            } catch {
                emit(.issue(.configurationFailed("切换镜头失败：\(error.localizedDescription)")))
            }
        }
    }

    func capturePhoto(
        flashMode: CameraFlashMode,
        rotationAngle: CGFloat,
        livePhotoEnabled: Bool
    ) {
        sessionQueue.async { [weak self] in
            guard let self, previewSession.isRunning, let device = videoInput?.device else {
                self?.emit(.issue(.sessionNotRunning))
                return
            }

            let settings: AVCapturePhotoSettings
            if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }

            settings.photoQualityPrioritization = .quality

            // Session reconfiguration (for example adding the microphone input
            // or switching cameras) can leave the output's Live Photo switch
            // disabled even though the device still reports support. Never
            // silently downgrade a user-requested Live Photo to a still image.
            if livePhotoEnabled {
                guard photoOutput.isLivePhotoCaptureSupported else {
                    emit(.issue(.captureFailed("当前镜头暂时无法拍摄实况照片。")))
                    emit(.captureFinished)
                    return
                }
                if !photoOutput.isLivePhotoCaptureEnabled {
                    photoOutput.isLivePhotoCaptureEnabled = true
                }
                guard photoOutput.isLivePhotoCaptureEnabled else {
                    emit(.issue(.captureFailed("实况拍摄没有成功启用，请再试一次。")))
                    emit(.captureFinished)
                    return
                }
            }

            let capturesLivePhoto = livePhotoEnabled
            if capturesLivePhoto {
                settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bishe-live-\(UUID().uuidString)")
                    .appendingPathExtension("mov")
            }
            let requestedFlashMode = flashMode.avFoundationValue
            let supportedFlashModes = photoOutput.supportedFlashModes
            if supportedFlashModes.contains(requestedFlashMode) {
                settings.flashMode = requestedFlashMode
            } else if supportedFlashModes.contains(.off) {
                settings.flashMode = .off
            } else {
                emit(.issue(.captureFailed("当前镜头无法使用闪光灯。")))
                emit(.captureFinished)
                return
            }

            if let connection = photoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = device.position == .front
                }
            }

            let processor = PhotoCaptureProcessor(
                requestedLivePhotoMovieURL: settings.livePhotoMovieFileURL
            ) { [weak self] uniqueID, result in
                guard let self else { return }
                sessionQueue.async { [weak self] in
                    guard let self else { return }
                    captureProcessors[uniqueID] = nil

                    switch result {
                    case .success(let payload):
                        emit(.captured(payload))
                    case .failure(let issue):
                        emit(.issue(issue))
                    }
                    emit(.captureFinished)
                }
            } willCapture: { [weak self] in
                self?.sessionQueue.async { [weak self] in
                    self?.emit(.willCapture)
                }
            }

            captureProcessors[settings.uniqueID] = processor
            photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func configureSession() throws {
        guard let device = preferredDevice(position: .back) ?? preferredDevice(position: .front) else {
            throw CameraIssue.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)

        previewSession.beginConfiguration()
        defer { previewSession.commitConfiguration() }

        if previewSession.canSetSessionPreset(.photo) {
            previewSession.sessionPreset = .photo
        }

        guard previewSession.canAddInput(input) else {
            throw CameraIssue.configurationFailed("无法加载相机输入。")
        }
        previewSession.addInput(input)
        videoInput = input

        guard previewSession.canAddOutput(photoOutput) else {
            previewSession.removeInput(input)
            videoInput = nil
            throw CameraIssue.configurationFailed("无法加载拍照输出。")
        }
        previewSession.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported

        if wantsLivePhotoAudio {
            addAudioInputIfPossible()
        }

        isConfigured = true
        emit(.configured(capabilities(for: device)))
    }

    private func preferredDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType]
        switch position {
        case .back:
            types = [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera
            ]
        case .front:
            types = [
                .builtInTrueDepthCamera,
                .builtInWideAngleCamera
            ]
        default:
            return nil
        }

        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) {
                return device
            }
        }
        return nil
    }

    private func capabilities(for device: AVCaptureDevice) -> Capabilities {
        Capabilities(
            position: CameraPosition(device.position),
            deviceUniqueID: device.uniqueID,
            hasFlash: device.hasFlash
                && (photoOutput.supportedFlashModes.contains(.auto)
                    || photoOutput.supportedFlashModes.contains(.on)),
            canSwitchCamera: preferredDevice(position: device.position == .back ? .front : .back) != nil,
            minimumZoomFactor: device.minAvailableVideoZoomFactor,
            maximumZoomFactor: usefulMaximumZoomFactor(for: device),
            zoomFactor: device.videoZoomFactor,
            zoomPresets: zoomPresets(for: device),
            supportsLivePhoto: photoOutput.isLivePhotoCaptureSupported
        )
    }

    private func addAudioInputIfPossible() {
        guard audioInput == nil,
              let audioDevice = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: audioDevice),
              previewSession.canAddInput(input) else { return }
        previewSession.addInput(input)
        audioInput = input
    }

    private func zoomPresets(for device: AVCaptureDevice) -> [CameraZoomPreset] {
        let minimum = device.minAvailableVideoZoomFactor
        let maximum = usefulMaximumZoomFactor(for: device)
        let switchFactors = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }

        let oneTimesFactor: CGFloat
        if device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera {
            oneTimesFactor = switchFactors.first ?? 1
        } else {
            oneTimesFactor = 1
        }

        let candidates = [minimum, oneTimesFactor]
            + switchFactors
            + [oneTimesFactor * 2, oneTimesFactor * 3]

        var uniqueFactors: [CGFloat] = []
        for factor in candidates.sorted() where factor >= minimum && factor <= maximum {
            if !uniqueFactors.contains(where: { abs($0 - factor) < 0.02 }) {
                uniqueFactors.append(factor)
            }
        }

        if uniqueFactors.isEmpty {
            uniqueFactors = [minimum]
        }

        return uniqueFactors.map { factor in
            let displayFactor = factor / oneTimesFactor
            let label: String
            if abs(displayFactor.rounded() - displayFactor) < 0.05 {
                label = "\(Int(displayFactor.rounded()))×"
            } else {
                label = String(format: "%.1f×", displayFactor)
            }
            return CameraZoomPreset(factor: factor, label: label)
        }
    }

    /// Extreme digital zoom is technically available on many devices but is not
    /// useful for matching a reference image. Ten times keeps the control precise.
    private func usefulMaximumZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        min(device.maxAvailableVideoZoomFactor, 10)
    }

    private func emit(_ event: Event) {
        eventHandler?(event)
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        let message: String
        if let number = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber,
           let reason = AVCaptureSession.InterruptionReason(rawValue: number.intValue) {
            switch reason {
            case .audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient:
                message = "相机正在被另一个 App 使用。"
            case .videoDeviceNotAvailableWithMultipleForegroundApps:
                message = "当前分屏状态下相机暂不可用。"
            case .videoDeviceNotAvailableDueToSystemPressure:
                message = "设备温度或系统压力过高，相机已暂停。"
            case .videoDeviceNotAvailableInBackground:
                message = "回到比摄后，相机会自动恢复。"
            case .sensitiveContentMitigationActivated:
                message = "系统已暂停当前相机画面。"
            @unknown default:
                message = "相机暂时中断，稍后会自动恢复。"
            }
        } else {
            message = "相机暂时中断，稍后会自动恢复。"
        }

        sessionQueue.async { [weak self] in
            self?.emit(.interrupted(message))
        }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            emit(.interruptionEnded)
            if wantsToRun, !previewSession.isRunning {
                previewSession.startRunning()
                emit(.running(previewSession.isRunning))
            }
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        let isMediaServicesReset = error?.code == .mediaServicesWereReset
        let message = error?.localizedDescription ?? "相机发生未知错误。"

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if isMediaServicesReset, wantsToRun {
                previewSession.startRunning()
                emit(.running(previewSession.isRunning))
            } else {
                emit(.issue(.runtimeError(message)))
            }
        }
    }
}

nonisolated private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Int64, Result<CameraEngine.CapturePayload, CameraIssue>) -> Void
    private let willCapture: @Sendable () -> Void
    private var photoData: Data?
    private var livePhotoMovieURL: URL?
    private let requestedLivePhotoMovieURL: URL?
    private var processingIssue: CameraIssue?

    init(
        requestedLivePhotoMovieURL: URL?,
        completion: @escaping @Sendable (Int64, Result<CameraEngine.CapturePayload, CameraIssue>) -> Void,
        willCapture: @escaping @Sendable () -> Void
    ) {
        self.requestedLivePhotoMovieURL = requestedLivePhotoMovieURL
        self.completion = completion
        self.willCapture = willCapture
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        willCapture()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            processingIssue = .captureFailed(error.localizedDescription)
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            processingIssue = .captureFailed("相机没有返回照片数据。")
            return
        }
        photoData = data
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime,
        photoDisplayTime: CMTime,
        resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error {
            processingIssue = .captureFailed(error.localizedDescription)
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }
        livePhotoMovieURL = outputFileURL
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        let result: Result<CameraEngine.CapturePayload, CameraIssue>
        if let error {
            result = .failure(.captureFailed(error.localizedDescription))
        } else if let processingIssue {
            result = .failure(processingIssue)
        } else if requestedLivePhotoMovieURL != nil, livePhotoMovieURL == nil {
            result = .failure(.captureFailed("实况视频没有处理完成，请再拍一次。"))
        } else if let photoData {
            result = .success(CameraEngine.CapturePayload(
                photoData: photoData,
                livePhotoMovieURL: livePhotoMovieURL
            ))
        } else {
            result = .failure(.captureFailed("相机没有返回照片数据。"))
        }

        if case .failure = result,
           let movieURL = livePhotoMovieURL ?? requestedLivePhotoMovieURL {
            try? FileManager.default.removeItem(at: movieURL)
        }
        completion(resolvedSettings.uniqueID, result)
    }
}
