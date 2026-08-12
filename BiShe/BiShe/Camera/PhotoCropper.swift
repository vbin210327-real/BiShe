import CoreGraphics
import Foundation
import ImageIO

/// Produces a centered, full-resolution crop in the photo's raw pixel space.
/// The requested width and height are expressed in intended display orientation;
/// EXIF orientation determines whether those axes must be swapped for the raw
/// sensor buffer.
nonisolated enum PhotoCropper {
    enum CropError: Error {
        case invalidAspectRatio
        case unreadableSource
        case cropCannotRepresentRatio
        case cropFailed
        case unsupportedDestination
        case destinationFailed
        case outputValidationFailed
    }

    /// Returns encoded image data whose displayed pixel dimensions exactly
    /// represent `displayAspectWidth : displayAspectHeight`.
    ///
    /// Failure is explicit. Callers must never save the unprocessed input as if
    /// the selected crop had succeeded.
    static func crop(
        _ data: Data,
        displayAspectWidth: Int,
        displayAspectHeight: Int
    ) throws -> Data {
        guard displayAspectWidth > 0, displayAspectHeight > 0 else {
            throw CropError.invalidAspectRatio
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CropError.unreadableSource
        }

        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let orientation = imageOrientation(from: properties)
        let normalizedDisplayRatio = normalizedRatio(
            width: displayAspectWidth,
            height: displayAspectHeight
        )
        let rawRatio = orientationSwapsAxes(orientation)
            ? (width: normalizedDisplayRatio.height, height: normalizedDisplayRatio.width)
            : normalizedDisplayRatio

        guard rawRatio.width <= 999,
              rawRatio.height <= 999,
              let cropPlan = centeredCropPlan(
            pixelWidth: sourceImage.width,
            pixelHeight: sourceImage.height,
            ratioWidth: rawRatio.width,
            ratioHeight: rawRatio.height
        ) else {
            throw CropError.cropCannotRepresentRatio
        }

        let imageBounds = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        if cropPlan.sourceRect == imageBounds,
           cropPlan.outputWidth == sourceImage.width,
           cropPlan.outputHeight == sourceImage.height {
            guard validatesOutput(
                data,
                rawRatioWidth: rawRatio.width,
                rawRatioHeight: rawRatio.height,
                expectedOrientation: orientation
            ) else {
                throw CropError.outputValidationFailed
            }
            return data
        }

        guard let croppedImage = sourceImage.cropping(to: cropPlan.sourceRect),
              let outputImage = resizedImage(
                croppedImage,
                width: cropPlan.outputWidth,
                height: cropPlan.outputHeight
              ) else {
            throw CropError.cropFailed
        }
        guard let sourceType = CGImageSourceGetType(source) else {
            throw CropError.unsupportedDestination
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            sourceType,
            1,
            nil
        ) else {
            throw CropError.unsupportedDestination
        }

        properties[kCGImagePropertyPixelWidth] = outputImage.width
        properties[kCGImagePropertyPixelHeight] = outputImage.height
        properties[kCGImageDestinationLossyCompressionQuality] = 0.97

        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = outputImage.width
            exif[kCGImagePropertyExifPixelYDimension] = outputImage.height
            properties[kCGImagePropertyExifDictionary] = exif
        }

        CGImageDestinationAddImage(destination, outputImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CropError.destinationFailed
        }

        let outputData = output as Data
        guard validatesOutput(
            outputData,
            rawRatioWidth: rawRatio.width,
            rawRatioHeight: rawRatio.height,
            expectedOrientation: orientation
        ) else {
            throw CropError.outputValidationFailed
        }
        return outputData
    }

    private static func normalizedRatio(width: Int, height: Int) -> (width: Int, height: Int) {
        let divisor = greatestCommonDivisor(width, height)
        return (width / divisor, height / divisor)
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var first = lhs
        var second = rhs
        while second != 0 {
            (first, second) = (second, first % second)
        }
        return first
    }

    private static func imageOrientation(
        from properties: [CFString: Any]
    ) -> CGImagePropertyOrientation {
        guard let value = properties[kCGImagePropertyOrientation] as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value) else {
            return .up
        }
        return orientation
    }

    private static func orientationSwapsAxes(_ orientation: CGImagePropertyOrientation) -> Bool {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            true
        case .up, .upMirrored, .down, .downMirrored:
            false
        }
    }

    private struct CropPlan {
        let sourceRect: CGRect
        let outputWidth: Int
        let outputHeight: Int
    }

    /// First chooses the nearest integer-pixel crop to the preview's continuous
    /// center crop. If those dimensions cannot express a custom ratio exactly,
    /// the whole crop is resized to the largest exact multiple. Resizing keeps
    /// the field of view unchanged; it never tightens the crop a second time.
    private static func centeredCropPlan(
        pixelWidth: Int,
        pixelHeight: Int,
        ratioWidth: Int,
        ratioHeight: Int
    ) -> CropPlan? {
        guard pixelWidth > 0,
              pixelHeight > 0,
              ratioWidth > 0,
              ratioHeight > 0 else { return nil }

        let sourceComparison = Int64(pixelWidth) * Int64(ratioHeight)
        let targetComparison = Int64(pixelHeight) * Int64(ratioWidth)
        let cropWidth: Int
        let cropHeight: Int
        if sourceComparison > targetComparison {
            cropWidth = roundedProductDivision(
                pixelHeight,
                multipliedBy: ratioWidth,
                dividedBy: ratioHeight
            )
            cropHeight = pixelHeight
        } else if sourceComparison < targetComparison {
            cropWidth = pixelWidth
            cropHeight = roundedProductDivision(
                pixelWidth,
                multipliedBy: ratioHeight,
                dividedBy: ratioWidth
            )
        } else {
            cropWidth = pixelWidth
            cropHeight = pixelHeight
        }

        let boundedCropWidth = min(max(cropWidth, 1), pixelWidth)
        let boundedCropHeight = min(max(cropHeight, 1), pixelHeight)
        let scale = min(boundedCropWidth / ratioWidth, boundedCropHeight / ratioHeight)
        guard scale > 0 else { return nil }

        let outputWidth = ratioWidth * scale
        let outputHeight = ratioHeight * scale
        let originX = (pixelWidth - boundedCropWidth) / 2
        let originY = (pixelHeight - boundedCropHeight) / 2
        return CropPlan(
            sourceRect: CGRect(
                x: originX,
                y: originY,
                width: boundedCropWidth,
                height: boundedCropHeight
            ),
            outputWidth: outputWidth,
            outputHeight: outputHeight
        )
    }

    private static func roundedProductDivision(
        _ value: Int,
        multipliedBy multiplier: Int,
        dividedBy divisor: Int
    ) -> Int {
        let numerator = Int64(value) * Int64(multiplier)
        return Int((numerator + Int64(divisor / 2)) / Int64(divisor))
    }

    private static func resizedImage(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard image.width != width || image.height != height else { return image }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: image.bitmapInfo.rawValue
        ) ?? CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Re-opens the finalized bytes without decoding all pixels and verifies
    /// both the exact raw ratio and retained EXIF orientation.
    private static func validatesOutput(
        _ data: Data,
        rawRatioWidth: Int,
        rawRatioHeight: Int,
        expectedOrientation: CGImagePropertyOrientation
    ) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else { return false }

        let orientation = imageOrientation(from: properties)
        guard orientation == expectedOrientation else { return false }
        guard width.isMultiple(of: rawRatioWidth),
              height.isMultiple(of: rawRatioHeight) else { return false }
        return width / rawRatioWidth == height / rawRatioHeight
    }
}
