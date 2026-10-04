import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
    /// May report a stale `false` right after granting until the app is relaunched; the
    /// controller treats a successful ScreenCaptureKit content query as the real answer.
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @MainActor
    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @MainActor
    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
