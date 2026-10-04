import CoreGraphics
import CoreText
import Foundation
import Vision

/// Vision text recognition over one captured frame, keeping a box per recognized line.
///
/// Configuration: `.accurate` level, en-US, language correction on. Chosen for small English UI
/// text; revisit only if measured OCR time is the bottleneck. A running Vision request can't be
/// interrupted; callers discard late results instead.
enum OCRRecognizer {
    static let minimumConfidence: Float = 0.3

    static func recognize(
        image: CGImage, geometry: CaptureGeometry, windowID: CGWindowID, generation: UInt64
    ) throws -> [TextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence
            else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let rect = geometry.quartzRect(fromVisionNormalized: observation.boundingBox)
            return TextObservation(
                text: text, rect: rect, source: .ocr, ocrConfidence: candidate.confidence,
                axRole: nil, lineHeight: rect.height, windowID: windowID, generation: generation)
        }
    }

    /// Recognizes only horizontal bands (Quartz rects) of a frame. Lines whose center falls in a
    /// band are returned; callers keep their previous observations elsewhere.
    static func recognize(
        bands: [CGRect], image: CGImage, geometry: CaptureGeometry, windowID: CGWindowID, generation: UInt64
    ) throws -> [TextObservation] {
        var lines: [TextObservation] = []
        for band in bands {
            let pixels = geometry.pixelRect(fromQuartz: band)
            guard !pixels.isNull, pixels.width >= 8, pixels.height >= 8, let crop = image.cropping(to: pixels)
            else { continue }
            let sub = geometry.subGeometry(pixelRect: pixels)
            let found = try recognize(image: crop, geometry: sub, windowID: windowID, generation: generation)
            lines += found.filter { band.contains($0.rect.center) }
        }
        return lines
    }

    /// Runs one small recognition so Vision loads its models before the first real cycle.
    /// (The first logged cycle once took ~27 s in OCR; warm-up is a guess at that cause, not a proven fix.)
    static func prewarm() {
        let width = 320, height = 64
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "Heads Down warm up", attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
        ctx.textPosition = CGPoint(x: 10, y: 20)
        CTLineDraw(line, ctx)
        guard let image = ctx.makeImage() else { return }
        let geometry = CaptureGeometry(
            displayID: 0, displayBounds: .zero, cropRect: CGRect(x: 0, y: 0, width: width, height: height),
            pixelWidth: width, pixelHeight: height)
        _ = try? recognize(image: image, geometry: geometry, windowID: 0, generation: 0)
    }
}
