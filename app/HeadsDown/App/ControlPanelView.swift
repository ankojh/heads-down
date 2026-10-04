import AppKit
import SwiftUI

/// Menu-bar panel: task, start/pause/stop, mode, status, permissions, classifier, shortcuts.
struct ControlPanelView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var calendar = CalendarAutomation.shared
    @Environment(\.openWindow) private var openWindow

    private var startTitle: String {
        switch controller.runState {
        case .stopped, .requestingPermissions: return "Start"
        default: return controller.taskSource == .manual ? "Update task" : "Use my typed task"
        }
    }

    private var startDisabled: Bool {
        let draft = controller.taskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty || controller.runState == .requestingPermissions { return true }
        return controller.runState != .stopped && draft == controller.currentTask && controller.taskSource == .manual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            taskSection
            controls
            modeSection
            Divider()
            CalendarSection(controller: controller, calendar: calendar)
            Divider()
            statusSection
            Divider()
            permissionsSection
            classifierSection
            Divider()
            shortcutsSection
            footer
        }
        .padding(14)
        .frame(width: 380)
        .onAppear {
            controller.refreshPermissions()
            if controller.classifierStatus == "Not checked" { controller.refreshClassifierHealth() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image("BrandIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text("Heads Down").font(.headline)
            Spacer()
            Text(controller.runState.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(stateColor.opacity(0.2), in: Capsule())
                .foregroundStyle(stateColor)
        }
    }

    private var stateColor: Color {
        switch controller.runState {
        case .observing, .processing: return .green
        case .paused, .requestingPermissions: return .orange
        case .degraded: return .red
        case .stopped: return .secondary
        }
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What are you working on?").font(.caption).foregroundStyle(.secondary)
            TextField("e.g. Studying prioritization frameworks for my PM quiz", text: $controller.taskDraft, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            if let task = controller.currentTask, controller.runState != .stopped {
                Text("Current task: \(task)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Text(controller.taskSource == .manual ? "Task source: You" : "Task source: Google Calendar")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(startTitle) { controller.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(startDisabled)
                Spacer()
                Button("Stop") { controller.stop() }
                    .disabled(controller.runState == .stopped)
            }
            if controller.isActive {
                HStack {
                    Button("Pause for 3 min") { controller.pause(minutes: 3) }
                        .buttonStyle(.borderedProminent)
                    Button("2 min") { controller.pause(minutes: 2) }
                    Button("Pause") { controller.pause() }
                        .help("Pause until you resume (\(HotKeys.pause.display))")
                }
            } else if controller.runState == .paused {
                pausedControls
            }
        }
    }

    /// Countdown is derived from the deadline once a second; it never triggers OCR or overlay work.
    private var pausedControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(pauseText).font(.callout.monospacedDigit().weight(.semibold))
            }
            HStack {
                Button("Resume now") { controller.resume() }
                    .buttonStyle(.borderedProminent)
                if controller.pauseDeadline != nil {
                    Button("Stay paused") { controller.stayPaused() }
                }
                Spacer()
                Menu("Pause again") {
                    ForEach(SessionController.timedPauseChoices, id: \.self) { minutes in
                        Button("\(minutes) min") { controller.pause(minutes: minutes) }
                    }
                }
                .fixedSize()
            }
        }
    }

    private var pauseText: String {
        guard let remaining = controller.pauseRemaining else { return "Paused · until you resume" }
        let seconds = Int(remaining.components.seconds)
        return String(format: "Paused · resumes in %d:%02d", seconds / 60, seconds % 60)
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Mode", selection: $controller.mode) {
                ForEach(CoverMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(controller.mode.explanation).font(.caption2).foregroundStyle(.secondary)
            if controller.mode != .observe {
                Picker("Hiding", selection: $controller.strictness) {
                    ForEach(Strictness.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("\(controller.strictness.explanation) Search fields, buttons, and other controls stay visible.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Show numbered region boxes", isOn: $controller.showBoxes)
            if controller.displays.count > 1 {
                Picker("Display", selection: $controller.selectedDisplayID) {
                    ForEach(controller.displays) { Text($0.name).tag($0.id) }
                }
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(controller.activity).font(.callout).lineLimit(3)
            if let coverage = controller.coverage {
                if let skip = coverage.skipReason {
                    Text(skip).font(.caption).foregroundStyle(.orange)
                } else if let app = coverage.appName {
                    let title = (coverage.windowTitle ?? "").isEmpty ? "" : " — \(coverage.windowTitle ?? "")"
                    Text("Covering: \(app)\(title)").font(.caption).lineLimit(2)
                    Text("Front window only on \(coverage.displayName) · \(coverage.readMode)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let notice = controller.notice {
                Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            permissionRow(
                "Screen Recording", granted: controller.screenRecordingGranted,
                detail: "Required to read the screen",
                action: Permissions.openScreenRecordingSettings)
            permissionRow(
                "Accessibility", granted: controller.accessibilityGranted,
                detail: "Optional: structured text; otherwise OCR only",
                action: Permissions.openAccessibilitySettings)
        }
    }

    private func permissionRow(_ name: String, granted: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.caption)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Open Settings", action: action).controlSize(.small) }
        }
    }

    private var classifierSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Classifier", selection: $controller.provider) {
                ForEach(ClassifierProvider.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(controller.classifierName) at \(controller.classifierEndpoint)").font(.caption)
                    Text(controller.classifierStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    if controller.provider.sendsTextOffDevice {
                        Text("Region text, app, window title, and task are sent to TypeSafe.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button("Check") { controller.refreshClassifierHealth() }.controlSize(.small)
            }
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(HotKeys.pause.display)  pause until resumed / resume (clears all overlays)").font(.caption2)
            Text("\(HotKeys.reveal.display)  reveal the region under the pointer for 10 min").font(.caption2)
            if controller.hotKeyStatus != "Registered" {
                Text("Shortcuts: \(controller.hotKeyStatus)").font(.caption2).foregroundStyle(.orange)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack {
            Button("Open Inspector") {
                openWindow(id: "inspector")
                NSApp.activate()
            }
            Spacer()
            Button("Quit") {
                controller.stop()
                NSApp.terminate(nil)
            }
        }
    }
}

/// Optional Google Calendar auto-start. Secondary to the typed task.
private struct CalendarSection: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var calendar: CalendarAutomation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Google Calendar (optional)").font(.caption.weight(.semibold))
                Spacer()
                connectionButtons
            }
            if calendar.connected {
                Toggle("Automatically start from the current event", isOn: Binding(
                    get: { calendar.autoStartEnabled }, set: { calendar.setAutoStart($0) }))
                    .font(.caption)
                Text(calendar.status.label).font(.caption2).foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let event = calendar.currentEvent { eventDetails(event) }
                actions
            } else {
                Text("Connect to start focus automatically from the event happening now. Read-only access.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = calendar.lastError {
                Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var connectionButtons: some View {
        if calendar.connecting {
            Text("Waiting for browser…").font(.caption2).foregroundStyle(.secondary)
            Button("Cancel") { calendar.cancelConnect() }.controlSize(.small)
        } else if calendar.connected {
            Button("Disconnect") { calendar.disconnect() }.controlSize(.small)
        } else {
            Button("Connect Google Calendar") { calendar.connect() }.controlSize(.small)
        }
    }

    private func eventDetails(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let times = [event.start, event.end].compactMap { $0?.formatted(date: .omitted, time: .shortened) }
            Text("Now: \(event.summary ?? "Busy (details hidden)") · \(times.joined(separator: "–"))"
                 + (calendar.overlapping > 0 ? " · \(calendar.overlapping) other event(s) overlap" : ""))
                .font(.caption2).lineLimit(2)
            if let brief = calendar.brief, brief.insufficientReason == nil {
                Text("Focus brief: \(brief.text)").font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            } else if let reason = calendar.brief?.insufficientReason {
                Text("Not used: \(reason)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack {
            if case .skipped = calendar.status {
                Button("Resume this event") { calendar.resumeThisEvent() }.controlSize(.small)
            } else if case .pausedByUser = calendar.status, controller.runState != .paused {
                Button("Re-arm") { calendar.resumeThisEvent() }.controlSize(.small)
            }
            if let brief = calendar.brief, brief.insufficientReason == nil {
                Button("Edit as my task") { controller.taskDraft = brief.text }
                    .controlSize(.small)
                    .help("Copies the brief into the task field; press Start/Use my typed task to apply it as your own")
            }
            Spacer()
            Button("Check now") { calendar.checkNow() }.controlSize(.small)
        }
    }

    private var statusColor: Color {
        switch calendar.status {
        case .blocked, .degraded, .needsAuthorization: return .orange
        case .active: return .green
        default: return .secondary
        }
    }
}
