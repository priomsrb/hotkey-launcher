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
    
    // State for window cycling to make it reliable during rapid presses
    private var lastCycleBundleId: String?
    private var lastCycleTime: Date?
    private var lastCycleWindows: [AXUIElement] = []
    private var lastCycleIndex: Int = 0
    
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
            
            let now = Date()
            let isRapidCycle = lastCycleBundleId == bundleId && 
                              lastCycleTime != nil && 
                              now.timeIntervalSince(lastCycleTime!) < 1.0
            
            // If the app is already active OR we are in a rapid cycling session, cycle windows
            if runningApp.isActive || isRapidCycle {
                print("[AppManager] App is focused or in rapid cycle, cycling windows...")
                cycleWindows(for: runningApp)
            } else {
                print("[AppManager] App is not focused, activating...")
                // Not focused - bring to front and initialize session
                activateApp(runningApp)
            }
        } else {
            print("[AppManager] App not running, launching...")
            // App not running - launch it
            launchApp(bundleId: bundleId)
        }
    }
    
    /// Get all windows for an app using brute-force (includes all spaces), sorted by focus and z-order
    private func getWindowsForApp(_ app: NSRunningApplication) -> [AXUIElement] {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        
        // 1. Identify what the OS thinks is currently focused - this is our #1 priority
        var focusedWindowElement: AXUIElement?
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success {
            focusedWindowElement = (focusedValue as! AXUIElement)
        }
        
        // 2. Brute-force find all windows across all spaces
        let axWindows = ApplicationManager.windowsByBruteForce(pid)
        
        // Fallback to standard AX if brute-force failed completely
        var rawWindows: [AXUIElement]
        if axWindows.isEmpty {
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let axWindowsAttr = windowsRef as? [AXUIElement] {
                rawWindows = axWindowsAttr
            } else {
                rawWindows = []
            }
        } else {
            rawWindows = axWindows
        }
        
        // 3. Match by CGWindowID for accurate sorting and de-duplication
        var uniqueWindows: [CGWindowID: AXUIElement] = [:]
        var focusedID: CGWindowID = 0
        if let focused = focusedWindowElement {
            _ = _AXUIElementGetWindow(focused, &focusedID)
        }
        
        for axWindow in rawWindows {
            var windowID: CGWindowID = 0
            _ = _AXUIElementGetWindow(axWindow, &windowID)
            if windowID != 0 && uniqueWindows[windowID] == nil {
                uniqueWindows[windowID] = axWindow
            }
        }
        
        // If focused window wasn't in list, add it
        if focusedID != 0 && uniqueWindows[focusedID] == nil, let focused = focusedWindowElement {
            uniqueWindows[focusedID] = focused
        }
        
        let deduplicated = Array(uniqueWindows.values)
        if deduplicated.isEmpty { return rawWindows }
        
        // 4. Get global z-order snapshot
        let options: CGWindowListOption = [.optionAll]
        let windowRankMap: [CGWindowID: Int]
        if let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            var map: [CGWindowID: Int] = [:]
            for (index, info) in windowInfoList.enumerated() {
                if let windowID = info[kCGWindowNumber as String] as? CGWindowID {
                    map[windowID] = index
                }
            }
            windowRankMap = map
        } else {
            windowRankMap = [:]
        }
        
        // 5. Final prioritized sort: Focus > Z-Order > ID
        return deduplicated.sorted { (ax1, ax2) -> Bool in
            var id1: CGWindowID = 0
            var id2: CGWindowID = 0
            _ = _AXUIElementGetWindow(ax1, &id1)
            _ = _AXUIElementGetWindow(ax2, &id2)
            
            if id1 == focusedID && id1 != 0 { return true }
            if id2 == focusedID && id2 != 0 { return false }
            
            let rank1 = windowRankMap[id1] ?? Int.max
            let rank2 = windowRankMap[id2] ?? Int.max
            if rank1 != rank2 {
                return rank1 < rank2
            }
            return id1 < id2
        }
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
        // we iterate to 2000 as a tradeoff between performance, and missing windows of long-lived processes
        // different apps can take widely different time for this to complete. We stop iterating if we time out
        let timer = LightweightTimer()
        for axUiElementId: AXUIElementID in 0..<2000 {
            remoteToken.replaceSubrange(12..<20, with: withUnsafeBytes(of: axUiElementId) { Data($0) })
            if let axUiElement = _AXUIElementCreateWithRemoteToken(remoteToken as CFData)?.takeRetainedValue(),
               let subrole = axUiElement.attributes([kAXSubroleAttribute as CFString]).subrole,
               [kAXStandardWindowSubrole as String, kAXDialogSubrole as String, kAXFloatingWindowSubrole as String].contains(subrole) {
                axWindows.append(axUiElement)
            }
            if timer.hasElapsed(milliseconds: 250) {
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
            print("[AppManager] Raising first window (z-order 0) and initializing session")
            raiseWindow(windows[0])
            
            // Initialize session state even during activation to make the next rapid press cycle correctly
            lastCycleBundleId = app.bundleIdentifier
            lastCycleTime = Date()
            lastCycleWindows = windows
            lastCycleIndex = 0
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
    
    /// Cycle to the next window of the given application
    private func cycleWindows(for app: NSRunningApplication) {
        let bundleId = app.bundleIdentifier ?? ""
        let now = Date()
        
        // If we are within 1 second of the last cycle for the same app, continue the cycle
        // using the same window list to ensure we visit every window exactly once in a loop.
        // Rapid OS z-order changes can otherwise cause us to toggle between 2 windows.
        if let lastId = lastCycleBundleId, lastId == bundleId,
           let lastTime = lastCycleTime, now.timeIntervalSince(lastTime) < 1.0,
           !lastCycleWindows.isEmpty {
            
            lastCycleIndex = (lastCycleIndex + 1) % lastCycleWindows.count
            lastCycleTime = now
            print("[AppManager] Continuing cycle session for \(bundleId), index: \(lastCycleIndex)/\(lastCycleWindows.count)")
            raiseWindow(lastCycleWindows[lastCycleIndex])
            return
        }
        
        // Start a new cycle session or refresh if enough time has passed
        let windows = getWindowsForApp(app)
        
        guard windows.count > 1 else {
            // No windows or only one window - just ensure app is activated
            print("[AppManager] Only \(windows.count) window(s), just activating app")
            activateApp(app)
            // Clear session state
            lastCycleBundleId = nil
            return
        }
        
        // Find the index of the currently focused window to start the cycle from there
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let startIndex = findFocusedIndex(in: windows, appElement: appElement)
        
        // Initialize session state
        lastCycleBundleId = bundleId
        lastCycleTime = now
        lastCycleWindows = windows
        // Move to the window after the currently focused one
        lastCycleIndex = (startIndex + 1) % windows.count
        
        print("[AppManager] Starting new cycle session for \(bundleId), index \(lastCycleIndex)/\(windows.count)")
        raiseWindow(lastCycleWindows[lastCycleIndex])
    }
    
    /// Helper to find the index of a focuses window element in a list, with CGWindowID fallback for reliability
    private func findFocusedIndex(in windows: [AXUIElement], appElement: AXUIElement) -> Int {
        var focusedWindowRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        
        guard focusedResult == .success, let focusedWindow = focusedWindowRef else { return 0 }
        let focusedElement = focusedWindow as! AXUIElement
        
        // 1. Try direct comparison
        for (index, window) in windows.enumerated() {
            if CFEqual(window, focusedElement) {
                return index
            }
        }
        
        // 2. Try CGWindowID fallback (more robust for remote elements)
        var focusedID: CGWindowID = 0
        _ = _AXUIElementGetWindow(focusedElement, &focusedID)
        if focusedID != 0 {
            for (index, window) in windows.enumerated() {
                var windowID: CGWindowID = 0
                _ = _AXUIElementGetWindow(window, &windowID)
                if windowID == focusedID {
                    return index
                }
            }
        }
        
        return 0
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
                    if workspace.frontmostApplication?.bundleIdentifier != nil {
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
