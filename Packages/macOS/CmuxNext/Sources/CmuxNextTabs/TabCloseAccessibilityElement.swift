import AppKit
import os

/// The x of a layer-drawn tab as a pressable child of its ``TabAccessibilityElement``, present
/// on every closable tab wide enough for it (it draws on hover). Computer-use agents and VoiceOver find it by
/// its identifier (`cmux.tabs.tab.<id>.close`) and press it with AXPress; the tab's Close Tab
/// custom action stays for clients that list actions instead.
/// AppKit calls accessibility on the main thread, but `NSAccessibilityElement` is not main-actor
/// isolated, so the press checks the thread and then enters the main actor with `assumeIsolated`.
nonisolated final class TabCloseAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    // Set and read on the main thread only (the tab cell configures it; AppKit presses there).
    nonisolated(unsafe) var onPress: (@MainActor () -> Void)?

    override init() {
        super.init()
        setAccessibilityRole(.button)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        guard Thread.isMainThread else {
            Self.logger.fault("tab close accessibility press off the main thread; refused")
            return false
        }
        MainActor.assumeIsolated { onPress() } // main-proof: guarded by Thread.isMainThread above
        return true
    }

    /// Faults from a press that arrives off the main thread.
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "tabs.accessibility")
}
