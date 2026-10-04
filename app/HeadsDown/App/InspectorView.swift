import SwiftUI

/// Debug inspector: what is covered, what was skipped, per-region text/source/bounds/grouping,
/// scores and policy, timings. Everything shown is in memory only.
struct InspectorView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoveragePanel(controller: controller)
                .padding(12)
            Divider()
            HSplitView {
                regionList
                    .frame(minWidth: 280, idealWidth: 320)
                RegionDetail(controller: controller)
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    private var regionList: some View {
        List(selection: $controller.selectedRegionID) {
            ForEach(controller.regions) { region in
                RegionRow(region: region, decision: controller.decisions[region.id],
                          stale: controller.staleRegionIDs.contains(region.id))
                    .tag(region.id)
            }
        }
        .overlay {
            if controller.regions.isEmpty {
                Text(controller.isActive ? "No regions yet" : "Start a task from the menu bar")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CoveragePanel: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(controller.runState.label).font(.headline)
                Text("· \(controller.activity)").foregroundStyle(.secondary).lineLimit(1)
            }
            if let coverage = controller.coverage {
                if let skip = coverage.skipReason {
                    Text(skip).foregroundStyle(.orange)
                } else {
                    Text("Covering \(coverage.appName ?? "?") — \"\(coverage.windowTitle ?? "")\" "
                         + "(window \(coverage.windowID.map(String.init) ?? "?")) on \(coverage.displayName). "
                         + "Front window only; other windows are not analyzed.")
                        .font(.callout)
                    if let bounds = coverage.bounds {
                        Text("Analyzed area: \(bounds.shortDescription) · \(coverage.readMode)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("AX: \(coverage.axStatus)").font(.caption).foregroundStyle(.secondary)
                    ForEach(coverage.skippedAreas, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    ForEach(coverage.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let timings = controller.lastTimings {
                Text("Last cycle #\(timings.cycleID): \(timings.summary) · \(timings.regionCount) regions, "
                     + "\(timings.classifiedCount) classified, \(timings.cachedCount) cached")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Write local timing log (no screen text)", isOn: $controller.diagnosticsEnabled)
                    .font(.caption)
                Button("Delete log") { controller.deleteDiagnostics() }.controlSize(.small)
                Text(controller.diagnosticsPath).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

private struct RegionRow: View {
    let region: ScreenRegion
    let decision: RegionDecision?
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("#\(region.number)").font(.body.monospacedDigit().weight(.semibold))
                Text(region.sourceLabel).font(.caption2).padding(.horizontal, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                Spacer()
                if stale { Text("changed").font(.caption2).foregroundStyle(.orange) }
                Text(scoreText).font(.caption.monospacedDigit())
                Text(decision?.action.rawValue ?? "leave").font(.caption2).foregroundStyle(.secondary)
            }
            Text(region.text.replacingOccurrences(of: "\n", with: " "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var scoreText: String {
        guard let score = decision?.pDistracting else { return "—" }
        return String(format: "%.2f", score)
    }
}

private struct RegionDetail: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        if let id = controller.selectedRegionID, let region = controller.regions.first(where: { $0.id == id }) {
            detail(region, decision: controller.decisions[region.id])
        } else {
            Text("Select a region to see its text, source, bounds, and grouping.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detail(_ region: ScreenRegion, decision: RegionDecision?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Region #\(region.number)").font(.title3.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Source", "\(region.sourceLabel) · \(region.observationCount) text items")
                    row("Grouping", region.reason)
                    row("Bounds", "\(region.rect.shortDescription) (Quartz global points)")
                    row("Geometry", region.geometryUncertain ? "Uncertain — overlaps a higher window" : "OK")
                    row("Context sent", "app: \(region.appName) · title: \(region.windowTitle)")
                    row("Score", decision?.pDistracting.map { String(format: "P(distracting) = %.3f", $0) }
                        ?? "No valid score (unknown)")
                    row("Score tier", decision?.tier.rawValue ?? "leave")
                    row("Applied", "\(decision?.action.rawValue ?? "leave") — \(decision?.policyNote ?? "")")
                    row("Provider", "\(decision?.providerID ?? "—") · \(decision?.questionVersion ?? "—")")
                    row("Tracking ID", region.id)
                    if controller.staleRegionIDs.contains(region.id) {
                        row("Status", "Content changed since capture — hidden until re-read")
                    }
                }
                Text("Scores are a model's distraction probability, not a guarantee or an explanation.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    if decision?.overridden == true {
                        Button("Cover again") { controller.unreveal(regionID: region.id) }
                        if let expiry = controller.revealExpiry(for: region) {
                            Text("Revealed until \(expiry.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                        }
                    } else {
                        Button("Reveal for 10 min") { controller.reveal(regionID: region.id) }
                    }
                }
                Divider()
                Text("Extracted text").font(.headline)
                Text(region.text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }
}
