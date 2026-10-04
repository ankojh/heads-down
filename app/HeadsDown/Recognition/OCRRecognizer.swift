import CoreGraphics
import Foundation
import Vision

/// Vision text recognition over one captured frame, keeping a box per recognized line.
///
/// Configuration: `.accurate` level, en-US, language correction on. Chosen for small English UI
/// text; revisit only if measured OCR time is the bottleneck.
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
}
