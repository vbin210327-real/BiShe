@preconcurrency import AVFoundation
import UIKit

/// UIKit camera surface backed directly by `AVCaptureVideoPreviewLayer`.
/// Tap-to-focus and pinch-to-zoom remain entirely inside the view so camera
/// gestures never trigger a root-controller reconciliation or layout pass.
@MainActor
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    var onFocusRequest: ((CGPoint, CameraFocusMode) -> UInt64?)?
    var onZoom: ((CGFloat) -> Void)?
    var currentZoomFactor: (() -> CGFloat)?
    var currentDisplayZoomFactor: (() -> CGFloat)?
    var onCaptureRotationChange: ((CGFloat) -> Void)?

    private var activeDeviceUniqueID: String?
    // RotationCoordinator intentionally keeps only a weak device reference.
    private var rotationDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var captureRotationObservation: NSKeyValueObservation?
    private var pinchStartingZoomFactor: CGFloat = 1
    private let focusIndicator = CAShapeLayer()
    private let focusStatusLabel = UILabel()
    private let zoomStatusLabel = UILabel()
    private var activeFocusRequestID: UInt64?
    private var activeFocusPoint: CGPoint?
    private var lastPreviewRotationAngle: CGFloat?
    private var lastCaptureRotationAngle: CGFloat?
    private var shouldMirrorPreview = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        clipsToBounds = true
        previewLayer.videoGravity = .resizeAspectFill

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.allowableMovement = 18
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: longPress)
        addGestureRecognizer(tap)
        addGestureRecognizer(longPress)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        configureFocusIndicator()
        configureZoomIndicator()

        accessibilityLabel = "相机取景"
        accessibilityHint = "轻点对焦，长按锁定曝光和焦点，双指开合调整焦距"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        focusIndicator.bounds = CGRect(x: 0, y: 0, width: 66, height: 66)
        focusIndicator.path = focusPath(in: focusIndicator.bounds).cgPath
        if let activeFocusPoint {
            layoutFocusStatusLabel(near: activeFocusPoint)
        }
        zoomStatusLabel.frame = CGRect(
            x: bounds.midX - 40,
            y: max(bounds.maxY - 40, bounds.minY),
            width: 80,
            height: 24
        )
        applyCurrentPreviewRotation()
    }

    func setSession(_ session: AVCaptureSession) {
        guard previewLayer.session !== session else {
            applyCurrentPreviewRotation()
            return
        }
        previewLayer.session = session
        applyCurrentPreviewRotation()
    }

    func setActiveDevice(uniqueID: String?) {
        guard activeDeviceUniqueID != uniqueID else {
            applyCurrentPreviewRotation()
            return
        }
        activeDeviceUniqueID = uniqueID
        shouldMirrorPreview = false

        previewRotationObservation = nil
        captureRotationObservation = nil
        rotationCoordinator = nil
        rotationDevice = nil
        lastPreviewRotationAngle = nil
        lastCaptureRotationAngle = nil

        guard let uniqueID, let device = Self.device(uniqueID: uniqueID) else {
            applyCurrentPreviewRotation()
            return
        }
        shouldMirrorPreview = device.position == .front
        rotationDevice = device
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] _, change in
            let angle = change.newValue ?? 0
            Task { @MainActor [weak self] in
                self?.applyPreviewRotation(angle)
            }
        }

        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] _, change in
            let angle = change.newValue ?? 90
            Task { @MainActor [weak self] in
                self?.reportCaptureRotation(angle)
            }
        }

        applyCurrentPreviewRotation()
    }

    private func configureFocusIndicator() {
        focusIndicator.fillColor = UIColor.clear.cgColor
        focusIndicator.strokeColor = StudioUIKitTheme.paper.cgColor
        focusIndicator.lineWidth = 1.5
        focusIndicator.lineCap = .square
        focusIndicator.opacity = 0
        focusIndicator.shadowColor = UIColor.black.cgColor
        focusIndicator.shadowOpacity = 0.36
        focusIndicator.shadowRadius = 2
        layer.addSublayer(focusIndicator)

        focusStatusLabel.textColor = StudioUIKitTheme.paper
        focusStatusLabel.font = StudioUIKitTheme.standardFont(size: 10, weight: .semibold, textStyle: .caption2)
        focusStatusLabel.textAlignment = .center
        focusStatusLabel.alpha = 0
        focusStatusLabel.isAccessibilityElement = false
        addSubview(focusStatusLabel)
    }

    private func configureZoomIndicator() {
        zoomStatusLabel.backgroundColor = .clear
        zoomStatusLabel.textColor = StudioUIKitTheme.paper
        zoomStatusLabel.font = StudioUIKitTheme.monospacedFont(size: 14, weight: .semibold)
        zoomStatusLabel.textAlignment = .center
        zoomStatusLabel.layer.shadowColor = UIColor.black.cgColor
        zoomStatusLabel.layer.shadowOpacity = 0.58
        zoomStatusLabel.layer.shadowRadius = 2
        zoomStatusLabel.layer.shadowOffset = CGSize(width: 0, height: 1)
        zoomStatusLabel.layer.masksToBounds = false
        zoomStatusLabel.alpha = 0
        zoomStatusLabel.isUserInteractionEnabled = false
        zoomStatusLabel.isAccessibilityElement = false
        addSubview(zoomStatusLabel)
    }

    private func focusPath(in rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let arm: CGFloat = 15

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
        return path
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let viewPoint = recognizer.location(in: self)
        requestFocus(at: viewPoint, mode: .transient)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        requestFocus(at: recognizer.location(in: self), mode: .locked)
    }

    private func requestFocus(at viewPoint: CGPoint, mode: CameraFocusMode) {
        guard bounds.contains(viewPoint) else { return }
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        guard let onFocusRequest,
              let requestID = onFocusRequest(devicePoint, mode) else { return }
        activeFocusRequestID = requestID
        activeFocusPoint = viewPoint
        showFocusIndicator(at: viewPoint, opacity: 0.52, animated: true)
        setFocusStatus(nil)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchStartingZoomFactor = currentZoomFactor?() ?? 1
            showZoomIndicator()
        case .changed:
            onZoom?(pinchStartingZoomFactor * recognizer.scale)
            showZoomIndicator()
        case .ended, .cancelled, .failed:
            showZoomIndicator(fadeAfter: 0.5)
        default:
            break
        }
    }

    private func showZoomIndicator(fadeAfter delay: TimeInterval? = nil) {
        let factor = max(currentDisplayZoomFactor?() ?? currentZoomFactor?() ?? 1, 0.1)
        if abs(factor.rounded() - factor) < 0.04 {
            zoomStatusLabel.text = "\(Int(factor.rounded()))×"
        } else {
            zoomStatusLabel.text = String(format: "%.1f×", factor)
        }

        zoomStatusLabel.layer.removeAllAnimations()
        UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            self.zoomStatusLabel.alpha = 1
        }
        guard let delay else { return }
        UIView.animate(
            withDuration: 0.24,
            delay: delay,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            self.zoomStatusLabel.alpha = 0
        }
    }

    func renderFocusState(_ state: CameraFocusState) {
        if case .idle = state {
            activeFocusRequestID = nil
            fadeFocusIndicator(after: 0)
            return
        }

        guard let requestID = state.requestID,
              requestID == activeFocusRequestID,
              let point = activeFocusPoint else { return }

        switch state {
        case .adjusting:
            showFocusIndicator(at: point, opacity: 1, animated: false)
            setFocusStatus(nil)
        case .focused:
            showFocusIndicator(at: point, opacity: 1, animated: false)
            setFocusStatus(nil)
            fadeFocusIndicator(after: 1.2)
        case .locked:
            showFocusIndicator(at: point, opacity: 1, animated: false)
            setFocusStatus("AE/AF 锁定")
            UIAccessibility.post(notification: .announcement, argument: "自动曝光和自动聚焦已锁定")
        case .exposureOnly(_, let locked):
            showFocusIndicator(at: point, opacity: 0.72, animated: false)
            setFocusStatus(locked ? "曝光锁定" : "仅调整曝光")
            if !locked { fadeFocusIndicator(after: 1.2) }
        case .unsupported:
            focusIndicator.strokeColor = StudioUIKitTheme.mutedPaper.cgColor
            showFocusIndicator(at: point, opacity: 0.58, animated: false)
            setFocusStatus("固定焦点")
            fadeFocusIndicator(after: 1.0)
        case .failed:
            focusIndicator.strokeColor = StudioUIKitTheme.mutedPaper.cgColor
            showFocusIndicator(at: point, opacity: 0.45, animated: false)
            setFocusStatus("无法聚焦")
            fadeFocusIndicator(after: 0.8)
        case .idle:
            break
        }
    }

    private func showFocusIndicator(at point: CGPoint, opacity: Float, animated: Bool) {
        focusIndicator.removeAllAnimations()
        focusIndicator.strokeColor = StudioUIKitTheme.paper.cgColor
        focusIndicator.position = point
        focusIndicator.opacity = opacity
        activeFocusPoint = point
        layoutFocusStatusLabel(near: point)

        if animated {
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [1.22, 0.94, 1]
            scale.keyTimes = [0, 0.72, 1]
            scale.duration = 0.26
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            focusIndicator.add(scale, forKey: "focus-scale")
        }
    }

    private func fadeFocusIndicator(after delay: CFTimeInterval) {
        focusIndicator.removeAnimation(forKey: "focus-fade")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = focusIndicator.presentation()?.opacity ?? focusIndicator.opacity
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + delay
        fade.duration = 0.28
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        focusIndicator.add(fade, forKey: "focus-fade")

        UIView.animate(
            withDuration: 0.24,
            delay: delay,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            self.focusStatusLabel.alpha = 0
        }
    }

    private func setFocusStatus(_ text: String?) {
        focusStatusLabel.text = text
        layoutFocusStatusLabel(near: activeFocusPoint ?? .zero)
        UIView.animate(withDuration: 0.16) {
            self.focusStatusLabel.alpha = text == nil ? 0 : 1
        }
    }

    private func layoutFocusStatusLabel(near point: CGPoint) {
        focusStatusLabel.sizeToFit()
        let width = max(focusStatusLabel.bounds.width + 12, 58)
        let height: CGFloat = 20
        let centerX = min(max(point.x, width / 2 + 8), bounds.width - width / 2 - 8)
        let proposedY = point.y + 43
        let y = proposedY + height <= bounds.height - 6 ? proposedY : point.y - 43 - height
        focusStatusLabel.frame = CGRect(x: centerX - width / 2, y: max(y, 6), width: width, height: height)
    }

    private func applyCurrentPreviewRotation() {
        applyPreviewMirroring()
        guard let coordinator = rotationCoordinator else { return }
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        reportCaptureRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        applyPreviewMirroring()
        guard let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        if lastPreviewRotationAngle.map({ abs($0 - angle) > 0.01 }) ?? true {
            connection.videoRotationAngle = angle
            lastPreviewRotationAngle = angle
        }
    }

    /// Match CameraEngine's photo-output policy exactly: the front camera is
    /// mirrored and the back camera is not. The preview connection can be
    /// created after the active-device event, so every geometry update retries
    /// this idempotently until the connection is ready.
    private func applyPreviewMirroring() {
        guard let connection = previewLayer.connection,
              connection.isVideoMirroringSupported else { return }

        if connection.automaticallyAdjustsVideoMirroring {
            connection.automaticallyAdjustsVideoMirroring = false
        }
        if connection.isVideoMirrored != shouldMirrorPreview {
            connection.isVideoMirrored = shouldMirrorPreview
        }
    }

    private func reportCaptureRotation(_ angle: CGFloat) {
        guard angle.isFinite,
              lastCaptureRotationAngle.map({ abs($0 - angle) > 0.01 }) ?? true else { return }
        lastCaptureRotationAngle = angle
        onCaptureRotationChange?(angle)
    }

    private static func device(uniqueID: String) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInTrueDepthCamera,
                .builtInWideAngleCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first { $0.uniqueID == uniqueID }
    }
}
