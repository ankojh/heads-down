import CoreGraphics
import Foundation

struct SegmentationInput {
    let observations: [TextObservation]
    let containers: [AXContainer]
    let visibleRect: CGRect
    let occluders: [CGRect]
    let appName: String
    let windowTitle: String
    let windowID: CGWindowID
}

struct SegmentationOutput {
    var regions: [ScreenRegion]
    var droppedTiny = 0
    var droppedOverCap = 0
    var containerGroups = 0
}

/// Small heuristic segmenter: turns text observations from one window into coherent regions.
///
/// 1. AX containers of plausible size that hold several text items (cards, rows, sidebar sections)
///    pull their text together and lend their frame to the region (covering thumbnails/backgrounds).
/// 2. Remaining text joins by proximity: same-line fragments, and stacked lines with a small gap
///    that share a column. Text in different containers never joins by proximity.
/// 3. Oversized blocks are split at their largest vertical gaps; overlapping results are merged.
///
/// Without AX containers (OCR-only), regions are text-block coverage only: they won't include
/// image/card backgrounds. All constants are heuristics, not measured thresholds.
enum Segmenter {
    static let maxRegions = 60
    static let padding: CGFloat = 4
    static let maxContainerAreaFraction: CGFloat = 0.35
    static let maxContainerHeightFraction: CGFloat = 0.45
    static let maxContainerTextGrowth: CGFloat = 6
    static let maxRegionHeightFraction: CGFloat = 0.45
    static let sameLineGap: CGFloat = 1.2
    static let stackedLineGap: CGFloat = 0.9
    static let maxLineHeightRatio: CGFloat = 2.2
    static let minAlphanumerics = 3

    private struct Group {
        var members: [Int]
        var container: AXContainer?
        var reason: String
    }

    static func segment(_ input: SegmentationInput) -> SegmentationOutput {
        let obs = input.observations
        guard !obs.isEmpty else { return SegmentationOutput(regions: []) }
        var output = SegmentationOutput(regions: [])

        // 1. Assign each observation to its largest qualifying container.
        let qualifying = qualifyingContainers(input)
        var containerOf = [Int?](repeating: nil, count: obs.count)
        for (index, item) in obs.enumerated() {
            let center = item.rect.center
            containerOf[index] = qualifying.indices
                .filter { qualifying[$0].rect.contains(center) }
                .max { qualifying[$0].rect.area < qualifying[$1].rect.area }
        }

        var sets = DisjointSet(count: obs.count)
        var byContainer: [Int: [Int]] = [:]
        for (index, container) in containerOf.enumerated() {
            if let container { byContainer[container, default: []].append(index) }
        }
        for members in byContainer.values where members.count > 1 {
            for member in members.dropFirst() { sets.union(members[0], member) }
        }

        // 2. Proximity joins, blocked across container boundaries.
        for first in 0..<obs.count {
            for second in (first + 1)..<obs.count where containerOf[first] == containerOf[second] {
                if shouldJoin(obs[first], obs[second]) { sets.union(first, second) }
            }
        }

        // 3. Build groups, attach container frames, split oversized ones.
        var groups: [Group] = []
        for members in sets.components() {
            let containerIndices = Set(members.map { containerOf[$0] })
            var container: AXContainer?
            if containerIndices.count == 1, let firstEntry = containerIndices.first, let only = firstEntry,
               byContainer[only]?.count == members.count {
                container = qualifying[only]
            }
            let textBounds = union(members.map { obs[$0].rect })
            if let candidate = container, candidate.rect.area > maxContainerTextGrowth * max(textBounds.area, 1) {
                container = nil
            }
            if let container {
                output.containerGroups += 1
                groups.append(Group(members: members, container: container, reason: "AX \(container.role) container"))
            } else if textBounds.height > maxRegionHeightFraction * input.visibleRect.height {
                groups.append(contentsOf: split(members, obs: obs, visible: input.visibleRect))
            } else {
                groups.append(Group(members: members, container: nil, reason: "text lines joined by proximity"))
            }
        }

        // 4. Merge heavily overlapping groups so the same content isn't classified twice.
        groups = mergeOverlapping(groups, obs: obs)

        // 5. Emit regions.
        var regions: [ScreenRegion] = []
        var seen: [String: Int] = [:]
        let appName = CanonicalInput.app(input.appName)
        let title = CanonicalInput.title(input.windowTitle)
        let ordered = groups.sorted { lhs, rhs in
            let left = bounds(of: lhs, obs: obs), right = bounds(of: rhs, obs: obs)
            return abs(left.minY - right.minY) > 4 ? left.minY < right.minY : left.minX < right.minX
        }
        for group in ordered {
            // The exact text the classifier will see; tracking and cache keys both derive from it.
            let text = CanonicalInput.text(readingOrderText(group.members.map { obs[$0] }))
            if text.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count < minAlphanumerics {
                output.droppedTiny += 1
                continue
            }
            if regions.count >= maxRegions {
                output.droppedOverCap += 1
                continue
            }
            let raw = bounds(of: group, obs: obs)
            var rect = raw.insetBy(dx: -padding, dy: -padding).intersection(input.visibleRect)
            var uncertain = false
            if input.occluders.contains(where: { $0.intersects(rect) }) {
                rect = raw.intersection(input.visibleRect)
                uncertain = input.occluders.contains { $0.intersects(rect) }
            }
            let sources = Set(group.members.map { obs[$0].source })
            let fingerprint = Fingerprint.of(normalized: Fingerprint.normalize(text))
            let occurrence = seen[fingerprint, default: 0]
            seen[fingerprint] = occurrence + 1
            let classifierFingerprint = CanonicalInput.key(app: appName, title: title, text: text)
            var reason = group.reason
            if uncertain { reason += "; overlaps a higher window" }
            regions.append(ScreenRegion(
                id: "\(fingerprint.prefix(10))-\(occurrence)", number: regions.count + 1, rect: rect,
                text: text, appName: appName,
                windowTitle: title, sources: sources, observationCount: group.members.count,
                reason: reason, fingerprint: fingerprint, classifierFingerprint: classifierFingerprint,
                geometryUncertain: uncertain, windowID: input.windowID))
        }
        output.regions = regions
        return output
    }

    // MARK: - Steps

    private static func qualifyingContainers(_ input: SegmentationInput) -> [AXContainer] {
        let visible = input.visibleRect
        return input.containers.filter { container in
            let rect = container.rect
            guard rect.width >= 20, rect.height >= 10,
                  rect.area <= maxContainerAreaFraction * visible.area,
                  rect.height <= maxContainerHeightFraction * visible.height
            else { return false }
            let inside = input.observations.filter { rect.contains($0.rect.center) }.count
            return inside >= 2
        }
    }

    private static func shouldJoin(_ first: TextObservation, _ second: TextObservation) -> Bool {
        let lhs = first.rect, rhs = second.rect
        let small = max(1, min(first.lineHeight, second.lineHeight))
        let large = max(first.lineHeight, second.lineHeight)
        guard large / small <= maxLineHeightRatio else { return false }

        let verticalOverlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        if verticalOverlap >= 0.5 * min(lhs.height, rhs.height) {
            let horizontalGap = max(lhs.minX, rhs.minX) - min(lhs.maxX, rhs.maxX)
            return horizontalGap <= sameLineGap * small
        }
        let upper = lhs.minY <= rhs.minY ? lhs : rhs
        let lower = lhs.minY <= rhs.minY ? rhs : lhs
        let verticalGap = lower.minY - upper.maxY
        guard verticalGap >= -0.3 * small, verticalGap <= stackedLineGap * small else { return false }
        let horizontalOverlap = min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)
        let leftAligned = abs(lhs.minX - rhs.minX) <= small
        return horizontalOverlap >= 0.3 * min(lhs.width, rhs.width) || (leftAligned && horizontalOverlap > 0)
    }

    private static func split(_ members: [Int], obs: [TextObservation], visible: CGRect) -> [Group] {
        let sorted = members.sorted { obs[$0].rect.minY < obs[$1].rect.minY }
        let limit = maxRegionHeightFraction * visible.height
        let preferredMin = 0.15 * visible.height
        var groups: [Group] = []
        var current: [Int] = []
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        for index in sorted {
            let rect = obs[index].rect
            if current.isEmpty {
                current = [index]
                top = rect.minY
                bottom = rect.maxY
                continue
            }
            let gap = rect.minY - bottom
            let bigGap = gap > 1.5 * obs[index].lineHeight
            if (bigGap && bottom - top > preferredMin) || max(bottom, rect.maxY) - top > limit {
                groups.append(Group(members: current, container: nil, reason: "split from an oversized text block"))
                current = [index]
                top = rect.minY
                bottom = rect.maxY
            } else {
                current.append(index)
                bottom = max(bottom, rect.maxY)
            }
        }
        if !current.isEmpty {
            groups.append(Group(members: current, container: nil, reason: "split from an oversized text block"))
        }
        return groups
    }

    private static func mergeOverlapping(_ input: [Group], obs: [TextObservation]) -> [Group] {
        var groups = input
        for _ in 0..<5 {
            var merged = false
            outer: for first in groups.indices {
                for second in groups.indices where second > first {
                    let lhs = bounds(of: groups[first], obs: obs), rhs = bounds(of: groups[second], obs: obs)
                    let shared = lhs.intersection(rhs).area
                    if shared >= 0.6 * min(lhs.area, rhs.area), shared > 0 {
                        let keepContainer = groups[first].container ?? groups[second].container
                        groups[first] = Group(
                            members: groups[first].members + groups[second].members,
                            container: keepContainer,
                            reason: groups[first].reason + "; merged an overlapping block")
                        groups.remove(at: second)
                        merged = true
                        break outer
                    }
                }
            }
            if !merged { break }
        }
        return groups
    }

    // MARK: - Helpers

    private static func bounds(of group: Group, obs: [TextObservation]) -> CGRect {
        let text = union(group.members.map { obs[$0].rect })
        if let container = group.container { return text.union(container.rect) }
        return text
    }

    private static func union(_ rects: [CGRect]) -> CGRect {
        rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }

    /// Rows top to bottom, fragments within a row left to right.
    static func readingOrderText(_ items: [TextObservation]) -> String {
        let sorted = items.sorted { $0.rect.midY < $1.rect.midY }
        var rows: [[TextObservation]] = []
        for item in sorted {
            if let last = rows.last?.last,
               abs(item.rect.midY - last.rect.midY) < 0.5 * min(item.lineHeight, last.lineHeight) {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows
            .map { $0.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}

/// Union-find over observation indices.
struct DisjointSet {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0..<count)
    }

    mutating func find(_ index: Int) -> Int {
        var root = index
        while parent[root] != root { root = parent[root] }
        var node = index
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        let left = find(lhs), right = find(rhs)
        if left != right { parent[right] = left }
    }

    mutating func components() -> [[Int]] {
        var byRoot: [Int: [Int]] = [:]
        for index in parent.indices { byRoot[find(index), default: []].append(index) }
        return byRoot.keys.sorted().compactMap { byRoot[$0] }
    }
}

enum Fingerprint {
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .joined(separator: " ")
    }

    /// FNV-1a 64-bit, hex. Stable across launches (unlike Swift's `Hasher`).
    static func of(normalized text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
