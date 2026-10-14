import Foundation
import Vision
import CoreGraphics
import ImageIO

public struct ImageRecognitionResult {
    public let text: String
    public let labels: [String]

    public init(text: String, labels: [String] = []) {
        self.text = text
        self.labels = labels
    }
}

public final class ImageRecognizer {
    private let textRequest: VNRecognizeTextRequest

    public init() {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        self.textRequest = req
    }

    public func recognize(path: String, cancelled: @escaping () -> Bool = { false }) -> ImageRecognitionResult? {
        guard !cancelled() else { return nil }

        // Skip tiny files (< 10KB) or very large images (> 30MB)
        if let attr = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attr[.size] as? UInt64 {
            if size < 10_000 || size > 30_000_000 {
                return nil
            }
        }

        let url = URL(fileURLWithPath: path)
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        // Downscale images to max 1800px (optimal for Apple Vision text OCR) to prevent massive memory usage
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: 1800
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbOptions as CFDictionary) else {
            return nil
        }

        let w = cgImage.width, h = cgImage.height
        // Physical lower bound: readable text cannot fit in an image smaller than 150x150
        if w < 150 || h < 150 {
            return nil
        }
        // Aspect ratio: skip extreme thin lines/dividers/gradient bars
        if max(w, h) / min(w, h) > 20 {
            return nil
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([textRequest])
        } catch {
            return nil
        }

        guard let observations = textRequest.results else { return nil }
        var lines: [String] = []
        for obs in observations {
            if let candidate = obs.topCandidates(1).first {
                lines.append(candidate.string)
            }
        }

        let fullText = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if fullText.isEmpty {
            return nil
        }
        return ImageRecognitionResult(text: fullText, labels: [])
    }
}
