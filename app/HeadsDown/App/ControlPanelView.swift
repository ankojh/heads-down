import AppKit
import SwiftUI

/// Menu-bar panel: task, start/pause/stop, mode, status, permissions, classifier, shortcuts.
struct ControlPanelView: View {
    @ObservedObject var controller: SessionController
    @Environment(\.openWindow) private var openWindow

    private var startTitle: String {
        switch controller.runState {
        case .stopped, .requestingPermissions: return "Start"
        case .paused: return "Resume"
        default: return "Update task"
        }
    }

    private var startDisabled: Bool {
        let draft = controller.taskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty || controller.runState == .requestingPermissions { return true }
        return controller.isActive && draft == controller.currentTask
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            taskSection
            controls
            modeSection
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
        HStack {
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
            }
        }
    }

    private var controls: some View {
        HStack {
            Button(startTitle) { controller.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(startDisabled)
            Button(controller.runState == .paused ? "Resume" : "Pause") { controller.togglePause() }
                .disabled(!(controller.isActive || controller.runState == .paused))
            Button("Stop") { controller.stop() }
                .disabled(controller.runState == .stopped)
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Mode", selection: $controller.mode) {
                ForEach(CoverMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(controller.mode.explanation).font(.caption2).foregroundStyle(.secondary)
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
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Laya at \(controller.classifierEndpoint)").font(.caption)
                Text(controller.classifierStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Check") { controller.refreshClassifierHealth() }.controlSize(.small)
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(HotKeys.pause.display)  pause / resume (clears all overlays)").font(.caption2)
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
