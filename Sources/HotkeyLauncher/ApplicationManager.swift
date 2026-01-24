import Cocoa
import ApplicationServices

/// Manages application launching, switching, and window cycling
class ApplicationManager {
    static let shared = ApplicationManager()
    
    private init() {}
    
    /// Activate or launch the application with the given bundle ID
    /// - If not running: Launch it
    /// - If running but not focused: Bring to focus
    /// - If already focused: Cycle to next window
    func activateOrLaunch(bundleId: String) {
        print("[AppManager] activateOrLaunch called for: \(bundleId)")
        let workspace = NSWorkspace.shared
        
        // Check if app is running
        if let runningApp = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            // App is running
            print("[AppManager] App is running (pid: \(runningApp.processIdentifier))")
            if runningApp.isActive {
                print("[AppManager] App is active, cycling windows...")
                // Already focused - cycle to next window
                cycleWindows(for: runningApp)
            } else {
                print("[AppManager] App is not active, activating...")
                // Not focused - bring to front
                let success = runningApp.activate(options: [.activateIgnoringOtherApps])
                print("[AppManager] Activation result: \(success)")
            }
        } else {
            print("[AppManager] App not running, launching...")
            // App not running - launch it
            launchApp(bundleId: bundleId)
        }
    }
    
    /// Launch an application by bundle ID
    private func launchApp(bundleId: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            print("Could not find application with bundle ID: \(bundleId)")
            return
        }
        
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
            if let error = error {
                print("Error launching \(bundleId): \(error)")
            }
        }
    }
    
    /// Cycle to the next window of the given application using Accessibility API
    private func cycleWindows(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        
        // Get all windows
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        
        guard result == .success,
              let windows = windowsRef as? [AXUIElement],
              windows.count > 1 else {
            // No windows or only one window - just ensure app is activated
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        
        // Get the frontmost (focused) window
        var focusedWindowRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        
        guard focusedResult == .success, let focusedWindow = focusedWindowRef else {
            // Can't get focused window, just raise the second window
            raiseWindow(windows[1])
            return
        }
        
        // Find the index of the focused window and cycle to the next one
        let focusedElement = focusedWindow as! AXUIElement
        var nextWindowIndex = 0
        
        for (index, window) in windows.enumerated() {
            if CFEqual(window, focusedElement) {
                nextWindowIndex = (index + 1) % windows.count
                break
            }
        }
        
        raiseWindow(windows[nextWindowIndex])
    }
    
    /// Raise a window to the front
    private func raiseWindow(_ window: AXUIElement) {
        // Raise the window
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        
        // Set it as the main window if possible
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
}
