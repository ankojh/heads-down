import SwiftUI

/// Debug inspector: what is covered, what was skipped, per-region text/source/bounds/grouping,
/// score, policy verdict versus what was actually rendered, and timings. In memory only.
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
                RegionRow(
                    region: region, decision: controller.decisions[region.id],
                    rendered: renderedStatus(controller, region))
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

/// What is actually on screen for a region, as opposed to the policy's intent.
@MainActor
private func renderedStatus(_ controller: SessionController, _ region: ScreenRegion) -> String {
    if !controller.isActive { return "not shown" }
    if controller.mode == .observe { return "not covered (Observe)" }
    if controller.visibleRegionIDs.contains(region.id) { return "visible" }
    if controller.changedRegionIDs.contains(region.id) { return "covered: changed since read" }
    return "covered"
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
                    Text("Cover: \(controller.renderedCover) · policy \(Policy.version(controller.strictness)) · "
                         + "\(controller.controlCount) controls kept visible · chrome: \(coverage.chromeNote)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("AX: \(coverage.axStatus)").font(.caption).foregroundStyle(.secondary)
                    Text("Scroll: \(controller.scrollStatus)").font(.caption).foregroundStyle(.secondary)
                    Text("Cover image: \(controller.coverStatus)").font(.caption).foregroundStyle(.secondary)
                    ForEach(coverage.skippedAreas, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    ForEach(coverage.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let timings = controller.lastTimings {
                Text("Last cycle #\(timings.cycleID) [\(timings.trigger)]: \(timings.summary)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("\(timings.regionCount) regions · \(timings.cacheHits) cached · "
                     + "OCR \(timings.ocrFresh) new / \(timings.ocrReused) reused lines")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            CalendarInspector(controller: controller, calendar: CalendarAutomation.shared)
            UsagePanel(usage: controller.usage, classifierName: controller.classifierName,
                       rate: controller.classifier.usdPerMillionInputTokens)
            HStack {
                Toggle("Write local timing log (no screen text)", isOn: $controller.diagnosticsEnabled)
                    .font(.caption)
                Button("Delete log") { controller.deleteDiagnostics() }.controlSize(.small)
                Text(controller.diagnosticsPath).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

/// Per-session classifier usage. Tokens are what the provider reported; cost is an estimate from
/// the published rate, not an invoice.
private struct UsagePanel: View {
    let usage: ClassificationStats
    let classifierName: String
    let rate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(classifierName)\(usage.lastModel.map { " → \($0)" } ?? ""): \(usage.httpRequests) requests · "
                 + "\(usage.inputTokens.formatted()) reported input tokens"
                 + (rate > 0 ? String(format: " · ~$%.4f est.", Double(usage.inputTokens) / 1_000_000 * rate) : " · local, free")
                 + " · \(usage.retries) retries · \(usage.failures) failed")
            Text("Decisions: \(usage.decisions) new · \(usage.cacheHits) cache hits · \(usage.inFlightShares) in-flight shares · "
                 + "\(usage.obsoleteDropped) obsolete skipped · \(usage.pending) pending · \(usage.inFlight) in flight · "
                 + "\(usage.rounds) dispatch rounds")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

private struct RegionRow: View {
    let region: ScreenRegion
    let decision: RegionDecision?
    let rendered: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("#\(region.number)").font(.body.monospacedDigit().weight(.semibold))
                Text(region.sourceLabel).font(.caption2).padding(.horizontal, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                Spacer()
                Text(scoreText).font(.caption.monospacedDigit())
                Text(rendered).font(.caption2).foregroundStyle(rendered == "visible" ? .green : .secondary)
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
                    row("Geometry", region.geometryUncertain ? "Partly under a higher window (that part stays visible)" : "OK")
                    row("Context sent", "app: \(region.appName) · title: \(region.windowTitle)")
                    row("Score", decision?.pDistracting.map { String(format: "P(distracting) = %.3f", $0) }
                        ?? "No valid score (unknown)")
                    row("Verdict", "\(decision?.verdict.rawValue ?? "unknown") — \(decision?.policyNote ?? "")")
                    row("On screen", renderedStatus(controller, region))
                    row("Provider", "\(decision?.providerID ?? "—") · \(decision?.questionVersion ?? "—") · "
                        + (decision?.policyVersion ?? Policy.version(controller.strictness)))
                    row("Tracking ID", region.id)
                }
                Text("Scores are a model's distraction probability, not a guarantee or an explanation. "
                     + "\(controller.strictness.label): \(controller.strictness.explanation) Controls always stay visible.")
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
                Text("Text sent to the classifier").font(.headline)
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

/// Calendar provenance and freshness. Event text appears only here and in the panel, never in logs.
private struct CalendarInspector: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var calendar: CalendarAutomation

    var body: some View {
        if calendar.connected {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar: \(calendar.status.label) · task source "
                     + (controller.taskSource == .manual ? "you" : "calendar (event-owned)"))
                if let brief = calendar.brief {
                    Text("Brief [\(brief.compressorID), \(brief.activity.rawValue), \(brief.fingerprint.prefix(8))]: "
                         + (brief.insufficientReason.map { "not used — \($0)" } ?? brief.text))
                        .lineLimit(3)
                }
                Text("Last check: " + (calendar.lastPollAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "never")
                     + " · \(Int(calendar.lastPollMs)) ms · \(calendar.stats.polls) checks, \(calendar.stats.failures) failed · "
                     + "briefs \(calendar.stats.briefsPrepared) prepared, \(calendar.stats.briefCacheHits) reused · "
                     + (calendar.agentEnabled
                        ? "agent \(calendar.agentModel) via Ollama, \(calendar.stats.agentRuns) runs"
                        : "no model calls for calendar data"))
                if let run = calendar.lastAgentRun {
                    Text("Last agent run: \(run.outcome) · \(run.turns) turns, \(run.fetches) link fetches"
                         + (run.usedHistory ? ", read recent tasks" : "") + (run.asked ? ", asked a question" : "")
                         + " · \(Int(run.ms)) ms")
                }
                if calendar.agentEnabled {
                    Button("Clear agent task history (\(TaskHistory.shared.entries.count))") { TaskHistory.shared.clear() }
                        .controlSize(.small)
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
