import AppKit
import SwiftUI

@main
struct HeadsDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SessionController.shared

    var body: some Scene {
        MenuBarExtra {
            ControlPanelView(controller: controller)
        } label: {
            menuBarIcon
                .accessibilityLabel("Heads Down — \(controller.runState.label)")
                .help("Heads Down — \(controller.runState.label)")
        }
        .menuBarExtraStyle(.window)

        Window("Heads Down Inspector", id: "inspector") {
            InspectorView(controller: controller)
        }
        .defaultSize(width: 920, height: 600)
        .defaultLaunchBehavior(.suppressed)
    }

    @ViewBuilder
    private var menuBarIcon: some View {
        switch controller.runState {
        case .stopped:
            Image("MenuBarIcon")
                .renderingMode(.template)
        case .observing, .processing:
            Image("MenuBarActive")
                .renderingMode(.template)
        case .paused, .degraded, .requestingPermissions:
            // Keep the existing timer, pause, permission, and error indicators recognizable.
            Image(systemName: controller.menuBarSymbol)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            SessionController.shared.setUp()
            // Watches the calendar independently of capture: an event can start while focus is off.
            CalendarAutomation.shared.setUp(session: SessionController.shared)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            CalendarAutomation.shared.shutdown()
            SessionController.shared.stop(cause: .quit)
        }
    }
}
