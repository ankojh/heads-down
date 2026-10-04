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
            Image(systemName: controller.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("Heads Down Inspector", id: "inspector") {
            InspectorView(controller: controller)
        }
        .defaultSize(width: 920, height: 600)
        .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { SessionController.shared.setUp() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { SessionController.shared.stop() }
    }
}
