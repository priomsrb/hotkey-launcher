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
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        
        if result == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty {
            print("[AppManager] Raising first window via AXUIElement")
            AXUIElementPerformAction(windows[0], kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(windows[0], kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        
        // Try NSRunningApplication.activate first
        let success = app.activate(options: [.activateIgnoringOtherApps])
        print("[AppManager] NSRunningApplication.activate result: \(success)")
        
        // If activate failed, use AppleScript as fallback (more reliable from terminal apps)
        if !success {
            print("[AppManager] Activate failed, using AppleScript fallback...")
            activateViaAppleScript(bundleId: app.bundleIdentifier ?? "", appName: app.localizedName ?? "")
        }
    }
    
    /// Use AppleScript to activate an app - more reliable when NSRunningApplication.activate fails
    private func activateViaAppleScript(bundleId: String, appName: String) {
        // Try by bundle ID first, then by name
        let script: String
        if !bundleId.isEmpty {
            script = """
            tell application id "\(bundleId)"
                activate
            end tell
            """
        } else if !appName.isEmpty {
            script = """
            tell application "\(appName)"
                activate
            end tell
            """
        } else {
            print("[AppManager] AppleScript fallback failed: no bundle ID or app name")
            return
        }
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("[AppManager] AppleScript error: \(error)")
            } else {
                print("[AppManager] AppleScript activation successful")
            }
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
    
    /// Get the localized name of an application from its bundle ID
    func getAppName(bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.deletingPathExtension().lastPathComponent
            return name
        }
        return bundleId
    }
    
    /// Get the icon of an application from its bundle ID
    func getAppIcon(bundleId: String) -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
    
    /// Show a file picker to select an application
    func pickApplication(completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application, .aliasFile]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                if let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier {
                    completion(bundleId)
                } else {
                    // Try to get bundle ID via workspace if Bundle(url:) fails (e.g. for aliases)
                    let workspace = NSWorkspace.shared
                    if let bundleId = workspace.frontmostApplication?.bundleIdentifier {
                         // This is not ideal, but aliases are tricky. 
                         // For now, assume it's a direct app path.
                    }
                    // Fallback: use the app name or try to find it
                    completion(nil)
                }
            } else {
                completion(nil)
            }
        }
    }
}
