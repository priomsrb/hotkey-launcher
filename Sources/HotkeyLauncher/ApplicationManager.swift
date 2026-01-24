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
                activateApp(runningApp)
            }
        } else {
            print("[AppManager] App not running, launching...")
            // App not running - launch it
            launchApp(bundleId: bundleId)
        }
    }
    
    /// Activate an app using multiple methods for reliability
    private func activateApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        
        // First, try to raise the main/first window via Accessibility API
        // This is more reliable than just NSRunningApplication.activate()
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        
        if result == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty {
            print("[AppManager] Raising first window via AXUIElement")
            // Raise the first window
            AXUIElementPerformAction(windows[0], kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(windows[0], kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        
        // Also call activate to ensure the app becomes frontmost
        let success = app.activate(options: [.activateIgnoringOtherApps])
        print("[AppManager] NSRunningApplication.activate result: \(success)")
        
        // If activate failed, try unhiding the app
        if !success {
            print("[AppManager] Activate failed, trying unhide...")
            let unhideSuccess = app.unhide()
            print("[AppManager] Unhide result: \(unhideSuccess)")
            // Try activate again after unhide
            let retrySuccess = app.activate(options: [.activateIgnoringOtherApps])
            print("[AppManager] Retry activate result: \(retrySuccess)")
        }
    }
    
    /// Launch an application by bundle ID
    private func launchApp(bundleId: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            print("[AppManager] Could not find application with bundle ID: \(bundleId)")
            return
        }
        
        print("[AppManager] Launching app at: \(appURL.path)")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
            if let error = error {
                print("[AppManager] Error launching: \(error)")
            } else {
                print("[AppManager] Launch successful")
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
        
        let windowCount = (windowsRef as? [AXUIElement])?.count ?? 0
        guard result == .success,
              let windows = windowsRef as? [AXUIElement],
              windows.count > 1 else {
            // No windows or only one window - just ensure app is activated
            print("[AppManager] Only \(windowCount) window(s), just activating app")
            activateApp(app)
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
