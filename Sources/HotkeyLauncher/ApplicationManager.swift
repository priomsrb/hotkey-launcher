import Cocoa
import ApplicationServices

// Private API to get CGWindowID from AXUIElement
// This is needed to match CGWindowListCopyWindowInfo results with AXUIElements
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

// Private API to create an AXUIElement from a remote token (pid + element id)
// This allows finding windows across all spaces
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

typealias AXUIElementID = UInt64

/// Simple timer to prevent long-running AX operations from blocking the UI
class LightweightTimer {
    private let startTime = Date()
    func hasElapsed(milliseconds: Double) -> Bool {
        return Date().timeIntervalSince(startTime) * 1000 > milliseconds
    }
}

extension AXUIElement {
    /// Support the .attributes([kAXSubroleAttribute]).subrole syntax
    struct AttributesWrapper {
        let element: AXUIElement
        var subrole: String? {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success {
                return value as? String
            }
            return nil
        }
    }
    
    func attributes(_ names: [CFString]) -> AttributesWrapper {
        return AttributesWrapper(element: self)
    }
}

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
    
    /// Get all windows for an app using brute-force (includes all spaces)
    private func getWindowsForApp(_ app: NSRunningApplication) -> [AXUIElement] {
        let pid = app.processIdentifier
        
        // Use brute-force discovery to find windows across all spaces
        let axWindows = ApplicationManager.windowsByBruteForce(pid)
        
        // If brute-force found nothing, fall back to standard AX windows attribute
        if axWindows.isEmpty {
            let appElement = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let axWindowsAttr = windowsRef as? [AXUIElement] {
                return axWindowsAttr
            }
        }
        
        return axWindows
    }
    
    // Copied from https://github.com/lwouis/alt-tab-macos/blob/aeaf782feb92a19688d2161268de1f0c10fc009d/src/api-wrappers/AXUIElement.swift#L250
    /// brute-force getting the windows of a process by iterating over AXUIElementID one by one
    private static func windowsByBruteForce(_ pid: pid_t) -> [AXUIElement] {
        // we use this to call _AXUIElementCreateWithRemoteToken; we reuse the object for performance
        // tests showed that this remoteToken is 20 bytes: 4 + 4 + 4 + 8; the order of bytes matters
        var remoteToken = Data(count: 20)
        remoteToken.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        remoteToken.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        remoteToken.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        var axWindows = [AXUIElement]()
        // we iterate to 1000 as a tradeoff between performance, and missing windows of long-lived processes
        // different apps can take widely different time for this to complete. We stop iterating if we time out
        let timer = LightweightTimer()
        for axUiElementId: AXUIElementID in 0..<1000 {
            remoteToken.replaceSubrange(12..<20, with: withUnsafeBytes(of: axUiElementId) { Data($0) })
            if let axUiElement = _AXUIElementCreateWithRemoteToken(remoteToken as CFData)?.takeRetainedValue(),
               let subrole = axUiElement.attributes([kAXSubroleAttribute as CFString]).subrole,
               [kAXStandardWindowSubrole as String, kAXDialogSubrole as String].contains(subrole) {
                axWindows.append(axUiElement)
            }
            if timer.hasElapsed(milliseconds: 100) {
                return axWindows
            }
        }
        return axWindows
    }
    
    /// Activate an app using multiple methods for reliability
    private func activateApp(_ app: NSRunningApplication) {
        // Check window count using brute-force (includes fullscreen/all spaces)
        let windows = getWindowsForApp(app)
        
        if windows.isEmpty {
            print("[AppManager] No windows found for \(app.localizedName ?? "app"), launching to trigger reopen...")
            if let bundleId = app.bundleIdentifier {
                launchApp(bundleId: bundleId)
                return
            }
        }
        
        // If we have windows, try to raise the main/first window
        if !windows.isEmpty {
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
    
    /// Cycle to the next window of the given application using brute-force discovery
    private func cycleWindows(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        
        // Get all windows across all spaces
        let windows = getWindowsForApp(app)
        
        guard windows.count > 1 else {
            // No windows or only one window - just ensure app is activated
            print("[AppManager] Only \(windows.count) window(s), just activating app")
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
        
        // If we didn't find the focused window in our list, it might be because
        // it's a window from another space that's focused.
        // We still have its element, so let's try to match by comparing element IDs if possible
        // but CFEqual should usually handle this.
        
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
    
    /// Get a list of running applications that can be targeted
    func getRunningApplications() -> [NSRunningApplication] {
        return NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && app.bundleIdentifier != nil && app.bundleIdentifier != Bundle.main.bundleIdentifier
        }.sorted { (app1, app2) -> Bool in
            let name1 = app1.localizedName ?? ""
            let name2 = app2.localizedName ?? ""
            return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
        }
    }
}
