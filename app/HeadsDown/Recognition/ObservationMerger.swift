import CoreGraphics
import Foundation

struct MergeStats {
    var axInput = 0
    var axKept = 0
    var axUnconfirmed = 0
    var ocrInput = 0
    var ocrKept = 0
    var ocrDuplicates = 0
    var occludedDropped = 0
}

/// Combines accessibility and OCR text for one frame.
///
/// - Drops anything outside the visible window area or under a higher window.
/// - Keeps an AX text element only if OCR found visible text overlapping it, because AX can expose
///   content that isn't actually on screen (scrolled away, hidden panes, occluded areas).
/// - Drops OCR lines whose words are already covered by overlapping AX text, so the same words
///   aren't counted twice. AX text is preferred where both exist; OCR fills the gaps.
enum ObservationMerger {
    static func merge(
        accessibility: [TextObservation], ocr: [TextObservation], visibleRect: CGRect, occluders: [CGRect]
    ) -> ([TextObservation], MergeStats) {
        var stats = MergeStats(axInput: accessibility.count, ocrInput: ocr.count)

        func isVisible(_ obs: TextObservation) -> Bool {
            let center = obs.rect.center
            return visibleRect.contains(center) && !occluders.contains { $0.contains(center) }
        }
        let visibleOCR = ocr.filter { obs in
            isVisible(obs) && obs.text.contains { $0.isLetter || $0.isNumber }
        }
        var keptAX: [TextObservation] = []
        for var obs in accessibility where isVisible(obs) {
            let overlapping = visibleOCR.filter { line in
                let shared = line.rect.intersection(obs.rect).area
                return shared > 0.2 * min(line.rect.area, obs.rect.area)
            }
            guard !overlapping.isEmpty else {
                stats.axUnconfirmed += 1
                continue
            }
            let heights = overlapping.map(\.rect.height).sorted()
            obs.lineHeight = min(obs.rect.height, heights[heights.count / 2])
            keptAX.append(obs)
        }
        stats.occludedDropped = (accessibility.count + ocr.count)
            - accessibility.filter(isVisible).count - ocr.filter(isVisible).count

        let axTokens = keptAX.map { tokens($0.text) }
        var keptOCR: [TextObservation] = []
        for line in visibleOCR {
            let lineTokens = tokens(line.text)
            var covered = Set<String>()
            for (index, axObs) in keptAX.enumerated() {
                let shared = line.rect.intersection(axObs.rect).area
                if shared > 0.3 * min(line.rect.area, axObs.rect.area) {
                    covered.formUnion(axTokens[index])
                }
            }
            let found = lineTokens.filter { covered.contains($0) }.count
            if !lineTokens.isEmpty, Double(found) / Double(lineTokens.count) >= 0.6 {
                stats.ocrDuplicates += 1
            } else {
                keptOCR.append(line)
            }
        }
        stats.axKept = keptAX.count
        stats.ocrKept = keptOCR.count
        return (keptAX + keptOCR, stats)
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { $0.count >= 2 })
    }
}
