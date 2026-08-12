import Combine
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ReferenceImageStore: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let fileURL: URL
    private let persistence = ReferenceImagePersistence()
    private var importGeneration = 0

    init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directoryURL = baseURL.appendingPathComponent("Reference", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent("current-reference.jpg")

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        isLoading = true
        Task { [weak self] in
            await self?.loadPersistedReference(generation: 0)
        }
    }

    var hasReference: Bool { image != nil }

    /// Decoding, orientation normalization,
    /// downsampling, decompression, encoding and disk I/O all happen off the
    /// main actor; only the final published image assignment is on MainActor.
    func importData(_ data: Data) async {
        let generation = beginImport()
        do {
            try await processImportedData(data, generation: generation)
            finishImport(generation: generation)
        } catch is CancellationError {
            finishImport(generation: generation)
        } catch {
            finishImport(generation: generation, error: error)
        }
    }

    func clear() {
        importGeneration &+= 1
        let generation = importGeneration

        image = nil
        isLoading = false
        errorMessage = nil

        Task { [persistence, fileURL] in
            try? await persistence.remove(at: fileURL, generation: generation)
        }
    }

    private func beginImport() -> Int {
        importGeneration &+= 1
        isLoading = true
        errorMessage = nil
        return importGeneration
    }

    private func processImportedData(_ data: Data, generation: Int) async throws {
        let prepared = try await Task.detached(priority: .userInitiated) {
            try ReferenceImageProcessor.prepare(data)
        }.value

        try Task.checkCancellation()

        let stored = try await persistence.store(
            prepared.encodedData,
            at: fileURL,
            generation: generation
        )

        try Task.checkCancellation()
        guard stored, generation == importGeneration else { return }

        // The CGImage already owns a decompressed, orientation-normalized pixel
        // buffer, so displaying or toggling it does not trigger a large decode.
        image = UIImage(cgImage: prepared.cgImage, scale: 1, orientation: .up)
    }

    private func finishImport(generation: Int, error: Error? = nil) {
        guard generation == importGeneration else { return }
        isLoading = false

        if error != nil {
            errorMessage = "这张图片没能打开，请换一张试试。"
        }
    }

    private func loadPersistedReference(generation: Int) async {
        do {
            let url = fileURL
            let prepared = try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                return try ReferenceImageProcessor.prepare(data)
            }.value

            let stored = try await persistence.store(
                prepared.encodedData,
                at: fileURL,
                generation: generation
            )

            guard stored, generation == importGeneration else { return }
            image = UIImage(cgImage: prepared.cgImage, scale: 1, orientation: .up)
            isLoading = false
        } catch {
            guard generation == importGeneration else { return }
            image = nil
            isLoading = false
            try? await persistence.remove(at: fileURL, generation: generation)
        }
    }
}

private actor ReferenceImagePersistence {
    private var latestGeneration = Int.min

    func store(_ data: Data, at url: URL, generation: Int) throws -> Bool {
        guard generation >= latestGeneration else { return false }
        latestGeneration = generation
        try data.write(to: url, options: .atomic)
        return true
    }

    func remove(at url: URL, generation: Int) throws {
        guard generation >= latestGeneration else { return }
        latestGeneration = generation

        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

private struct PreparedReference: @unchecked Sendable {
    let cgImage: CGImage
    let encodedData: Data
}

private enum ReferenceImageProcessor {
    nonisolated static let maximumPixelSize = 4_096

    nonisolated static func prepare(_ data: Data) throws -> PreparedReference {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ReferenceError.unreadableImage
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw ReferenceError.unreadableImage
        }

        let decodedImage = try makeDecodedImage(from: thumbnail)
        let encodedData = try encodeJPEG(decodedImage)
        return PreparedReference(cgImage: decodedImage, encodedData: encodedData)
    }

    nonisolated private static func makeDecodedImage(from image: CGImage) throws -> CGImage {
        guard image.width > 0, image.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ReferenceError.unreadableImage
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard let decodedImage = context.makeImage() else {
            throw ReferenceError.unreadableImage
        }
        return decodedImage
    }

    nonisolated private static func encodeJPEG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ReferenceError.encodingFailed
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ReferenceError.encodingFailed
        }
        return output as Data
    }
}

private enum ReferenceError: Error {
    case unreadableImage
    case encodingFailed
}
