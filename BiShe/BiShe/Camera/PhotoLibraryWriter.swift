@preconcurrency import Photos
import Combine
import Foundation

enum PhotoSaveState: Equatable {
    case idle
    case saving
    case saved
    case denied
    case failed(String)
}

@MainActor
final class PhotoLibraryWriter: ObservableObject {
    @Published private(set) var state: PhotoSaveState = .idle
    private var activeOperationID: UUID?

    func save(_ data: Data, livePhotoMovieURL: URL? = nil) async -> Bool {
        guard state != .saving else { return false }
        let operationID = UUID()
        activeOperationID = operationID
        state = .saving

        let authorization = await authorizationStatus()
        guard activeOperationID == operationID else { return false }
        guard authorization == .authorized || authorization == .limited else {
            state = .denied
            return false
        }

        do {
            try await writePhoto(data, livePhotoMovieURL: livePhotoMovieURL)
            guard activeOperationID == operationID else { return false }
            state = .saved
            return true
        } catch {
            guard activeOperationID == operationID else { return false }
            state = .failed("保存失败，请稍后再试。")
            return false
        }
    }

    func reset() {
        guard state != .saving else { return }
        activeOperationID = nil
        state = .idle
    }

    private func authorizationStatus() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    private func writePhoto(_ data: Data, livePhotoMovieURL: URL?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                if let livePhotoMovieURL {
                    request.addResource(with: .pairedVideo, fileURL: livePhotoMovieURL, options: nil)
                }
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: PhotoLibraryError.unknown)
                }
            }
        }
    }
}

private enum PhotoLibraryError: Error {
    case unknown
}
