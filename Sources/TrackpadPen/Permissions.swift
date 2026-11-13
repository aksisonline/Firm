import AppKit
import CoreGraphics

enum Permissions {
    /// Returns true if we can both observe and modify HID events.
    /// Prompts the user for whatever is missing.
    @discardableResult
    static func ensure() -> Bool {
        let accessibility = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        let listen = CGPreflightListenEventAccess() || CGRequestListenEventAccess()
        let post = CGPreflightPostEventAccess() || CGRequestPostEventAccess()
        return accessibility && listen && post
    }

    static var status: (accessibility: Bool, inputMonitoring: Bool) {
        (AXIsProcessTrusted(), CGPreflightListenEventAccess() && CGPreflightPostEventAccess())
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
}
