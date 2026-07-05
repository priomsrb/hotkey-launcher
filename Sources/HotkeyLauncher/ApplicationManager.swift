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

// Private SkyLight APIs to enumerate spaces and the windows on them.
// CGWindowListCopyWindowInfo only sees the current space; these see every
// space, including fullscreen ones. Same technique as alt-tab-macos.
typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
func CGSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID, _ owner: Int, _ spaces: NSArray, _ options: Int, _ setTags: inout Int, _ clearTags: inout Int) -> NSArray

/// Simple timer to prevent long-running AX operations from blocking the UI
class LightweightTimer {
    private let startTime = Date()
    func hasElapsed(milliseconds: Double) -> Bool {
        return Date().timeIntervalSince(startTime) * 1000 > milliseconds
    }
}

/// Manages application launching, switching, and window cycling
class ApplicationManager {
    static let shared = ApplicationManager()

    /// A window-cycling session. Pressing the hotkey repeatedly within
    /// `sessionTimeout` walks this fixed window list, so every window is
    /// visited exactly once per loop even while the OS z-order shifts under us.
    private struct CycleSession {
        let bundleId: String
        let windows: [AXUIElement]
        var index: Int
        var lastActivity: Date
    }

    private var session: CycleSession?
    private let sessionTimeout: TimeInterval = 1.0

    private init() {}

    /// Activate or launch the application with the given bundle ID
    /// - If not running: Launch it
    /// - If running but not focused: Bring to focus
    /// - If already focused: Cycle to next window
    func activateOrLaunch(bundleId: String) {
        print("[AppManager] activateOrLaunch called for: \(bundleId)")

        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) else {
            print("[AppManager] App not running, launching...")
            launchApp(bundleId: bundleId)
            return
        }

        // A recent hotkey press for the same app means we're mid-cycle, even if
        // macOS hasn't finished activating the app yet
        let inActiveSession: Bool
        if let s = session, s.bundleId == bundleId,
           Date().timeIntervalSince(s.lastActivity) < sessionTimeout {
            inActiveSession = true
        } else {
            inActiveSession = false
        }

        if app.isActive || inActiveSession {
            print("[AppManager] App is focused or mid-cycle, cycling windows...")
            cycleWindows(for: app)
        } else {
            print("[AppManager] App is not focused, activating...")
            focusApp(app)
        }
    }

    // MARK: - Window discovery

    /// Get all windows for an app, sorted focused-first then by z-order.
    ///
    /// The window server (via private SkyLight APIs) tells us exactly which
    /// window IDs the app owns across every space, including fullscreen ones.
    /// The standard kAXWindows list covers the current space reliably; any
    /// window it misses (other spaces, fullscreen) is then brute-forced by
    /// matching those specific IDs, so the scan can stop as soon as every
    /// window is accounted for and doesn't depend on subrole quirks.
    private func getWindowsForApp(_ app: NSRunningApplication) -> [AXUIElement] {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // The window the app itself considers focused - always include it
        var focusedWindow: AXUIElement?
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success {
            focusedWindow = (focusedRef as! AXUIElement)
        }

        var standardWindows: [AXUIElement] = []
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let list = windowsRef as? [AXUIElement] {
            standardWindows = list
        }
        // Keep only real windows, but if the filter removes everything
        // (some apps report no subrole) keep the unfiltered list
        let filteredStandard = standardWindows.filter { ApplicationManager.isCycleableWindow($0) }
        if !filteredStandard.isEmpty {
            standardWindows = filteredStandard
        }

        // Ground truth: every window the window server attributes to this app
        let expectedIDs = ApplicationManager.windowServerWindowIDs(pid: pid)

        var seenIDs = Set<CGWindowID>()
        var merged: [(id: CGWindowID, element: AXUIElement)] = []
        func addUnique(_ windows: [AXUIElement]) {
            for window in windows {
                var windowID: CGWindowID = 0
                _ = _AXUIElementGetWindow(window, &windowID)
                guard windowID != 0, seenIDs.insert(windowID).inserted else { continue }
                merged.append((windowID, window))
            }
        }

        addUnique(standardWindows)
        if let focused = focusedWindow {
            addUnique([focused])
        }

        if expectedIDs.isEmpty {
            // Window server enumeration unavailable - fall back to a blind scan
            addUnique(ApplicationManager.windowsByBruteForce(pid))
        } else {
            // Brute-force only the windows the AX list missed (other spaces,
            // fullscreen). Matching by ID means the scan stops the moment all
            // of them are found.
            let missingIDs = expectedIDs.subtracting(seenIDs)
            if !missingIDs.isEmpty {
                addUnique(ApplicationManager.windowsByBruteForce(pid, lookingFor: missingIDs))
                let stillMissing = expectedIDs.subtracting(seenIDs)
                if !stillMissing.isEmpty {
                    print("[AppManager] Warning: \(stillMissing.count) window(s) exist but weren't reachable via AX: \(stillMissing)")
                }
            }
        }

        // If no window had a resolvable ID, fall back to the raw standard list
        guard !merged.isEmpty else {
            return standardWindows
        }

        var focusedID: CGWindowID = 0
        if let focused = focusedWindow {
            _ = _AXUIElementGetWindow(focused, &focusedID)
        }

        let zOrderRank = ApplicationManager.zOrderRanks()

        return merged.sorted { a, b in
            if a.id == focusedID { return true }
            if b.id == focusedID { return false }
            let rankA = zOrderRank[a.id] ?? Int.max
            let rankB = zOrderRank[b.id] ?? Int.max
            if rankA != rankB { return rankA < rankB }
            return a.id < b.id
        }.map { $0.element }
    }

    /// All windows the window server attributes to `pid` on any space
    /// (including fullscreen spaces), at the normal window layer. This is the
    /// ground truth for whether AX-based discovery has missed a window.
    private static func windowServerWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        let connection = CGSMainConnectionID()
        guard let displaySpaces = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] else { return [] }

        var spaceIDs: [CGSSpaceID] = []
        for display in displaySpaces {
            for space in (display["Spaces"] as? [[String: Any]]) ?? [] {
                if let spaceID = space["id64"] as? CGSSpaceID {
                    spaceIDs.append(spaceID)
                }
            }
        }
        guard !spaceIDs.isEmpty else { return [] }

        var setTags = 0
        var clearTags = 0
        // 0x7 = include invisible and minimized windows
        let rawIDs = CGSCopyWindowsWithOptionsAndTags(connection, 0, spaceIDs as NSArray, 0x7, &setTags, &clearTags)
        let windowIDs: [CGWindowID] = (rawIDs as? [NSNumber])?.map { $0.uint32Value } ?? []
        guard !windowIDs.isEmpty else { return [] }

        // Resolve owner pid, layer, etc. for each ID (works across spaces,
        // unlike CGWindowListCopyWindowInfo). Note: this API requires the IDs
        // stored as raw values in the CFArray, not boxed in NSNumbers.
        var pointers: [UnsafeRawPointer?] = windowIDs.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let cfIDs = CFArrayCreate(kCFAllocatorDefault, &pointers, pointers.count, nil)
        guard let descriptions = CGWindowListCreateDescriptionFromArray(cfIDs) as? [[String: Any]] else { return [] }

        // Keep only windows that plausibly have an AX representation: normal
        // layer, visible alpha, and big enough to not be a tooltip/overlay.
        // Anything else would count as permanently "missing" and trigger
        // pointless brute-force scans on every hotkey press.
        var result = Set<CGWindowID>()
        for info in descriptions {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.1,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, width >= 100,
                  let height = bounds["Height"] as? Double, height >= 100,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            result.insert(windowID)
        }
        return result
    }

    /// Global front-to-back ranking of every window the window server knows about
    private static func zOrderRanks() -> [CGWindowID: Int] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var ranks: [CGWindowID: Int] = [:]
        for (index, info) in infoList.enumerated() {
            if let windowID = info[kCGWindowNumber as String] as? CGWindowID {
                ranks[windowID] = index
            }
        }
        return ranks
    }

    private static let cycleableSubroles: Set<String> = [
        kAXStandardWindowSubrole as String,
        kAXDialogSubrole as String,
        kAXFloatingWindowSubrole as String,
    ]

    private static func isCycleableWindow(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String else { return false }
        return cycleableSubroles.contains(subrole)
    }

    // Technique from https://github.com/lwouis/alt-tab-macos/blob/aeaf782feb92a19688d2161268de1f0c10fc009d/src/api-wrappers/AXUIElement.swift#L250
    /// Brute-force the AX elements of a process by iterating element IDs one
    /// by one. When `lookingFor` is given, elements are matched against those
    /// CGWindowIDs and the scan stops as soon as all of them are found - this
    /// is cheaper per element (no subrole query) so it can scan much deeper,
    /// which matters for busy processes like Chrome that burn through element
    /// IDs. Without it, windows are detected by subrole (blind fallback).
    private static func windowsByBruteForce(_ pid: pid_t, lookingFor targetIDs: Set<CGWindowID> = []) -> [AXUIElement] {
        // we use this to call _AXUIElementCreateWithRemoteToken; we reuse the object for performance
        // tests showed that this remoteToken is 20 bytes: 4 + 4 + 4 + 8; the order of bytes matters
        var remoteToken = Data(count: 20)
        remoteToken.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        remoteToken.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        remoteToken.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        var axWindows = [AXUIElement]()
        var remaining = targetIDs
        let targeted = !targetIDs.isEmpty
        let maxElementID: AXUIElementID = targeted ? 30_000 : 2000
        let budgetMs: Double = targeted ? 500 : 250
        let timer = LightweightTimer()
        for axUiElementId: AXUIElementID in 0..<maxElementID {
            remoteToken.replaceSubrange(12..<20, with: withUnsafeBytes(of: axUiElementId) { Data($0) })
            if let axUiElement = _AXUIElementCreateWithRemoteToken(remoteToken as CFData)?.takeRetainedValue() {
                if targeted {
                    var windowID: CGWindowID = 0
                    _ = _AXUIElementGetWindow(axUiElement, &windowID)
                    if remaining.remove(windowID) != nil {
                        axWindows.append(axUiElement)
                        if remaining.isEmpty {
                            return axWindows
                        }
                    }
                } else if isCycleableWindow(axUiElement) {
                    axWindows.append(axUiElement)
                }
            }
            if timer.hasElapsed(milliseconds: budgetMs) {
                return axWindows
            }
        }
        return axWindows
    }

    // MARK: - Focusing and cycling

    /// Bring an app to the front, showing its most recently focused window
    private func focusApp(_ app: NSRunningApplication) {
        let windows = getWindowsForApp(app)

        guard !windows.isEmpty else {
            print("[AppManager] No windows found for \(app.localizedName ?? "app"), launching to trigger reopen...")
            session = nil
            if let bundleId = app.bundleIdentifier {
                launchApp(bundleId: bundleId)
            }
            return
        }

        print("[AppManager] Raising most recently focused window of \(windows.count)")
        raiseWindow(windows[0], of: app)

        // Seed a session so an immediate second press cycles to the next window
        session = CycleSession(bundleId: app.bundleIdentifier ?? "",
                               windows: windows,
                               index: 0,
                               lastActivity: Date())
    }

    /// Cycle to the next window of the given application
    private func cycleWindows(for app: NSRunningApplication) {
        let bundleId = app.bundleIdentifier ?? ""
        let now = Date()

        // Continue an active session using its cached window list
        if var s = session, s.bundleId == bundleId,
           now.timeIntervalSince(s.lastActivity) < sessionTimeout,
           s.windows.count > 1 {
            // Windows may have closed since the list was cached - skip dead ones
            for _ in 0..<s.windows.count {
                s.index = (s.index + 1) % s.windows.count
                if raiseWindow(s.windows[s.index], of: app) {
                    s.lastActivity = now
                    session = s
                    print("[AppManager] Continuing cycle for \(bundleId): \(s.index + 1)/\(s.windows.count)")
                    return
                }
            }
            // Every cached window is gone - rebuild below
        }

        session = nil
        let windows = getWindowsForApp(app)
        print("[AppManager] New cycle session for \(bundleId): \(windows.count) window(s)")

        guard !windows.isEmpty else {
            // Active app with no windows - relaunch to trigger its reopen behaviour
            launchApp(bundleId: bundleId)
            return
        }

        guard windows.count > 1 else {
            raiseWindow(windows[0], of: app)
            return
        }

        // Start from whichever window is focused right now and move one past it
        let focusedIndex = findFocusedIndex(in: windows, app: app)
        var newSession = CycleSession(bundleId: bundleId,
                                      windows: windows,
                                      index: focusedIndex,
                                      lastActivity: now)
        for _ in 0..<windows.count {
            newSession.index = (newSession.index + 1) % windows.count
            if raiseWindow(windows[newSession.index], of: app) { break }
        }
        session = newSession
    }

    /// Find the index of the app's focused window in a list, comparing by
    /// CGWindowID as a fallback because remote elements can fail CFEqual
    private func findFocusedIndex(in windows: [AXUIElement], app: NSRunningApplication) -> Int {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedValue = focusedRef else { return 0 }
        let focusedWindow = focusedValue as! AXUIElement

        if let index = windows.firstIndex(where: { CFEqual($0, focusedWindow) }) {
            return index
        }

        var focusedID: CGWindowID = 0
        _ = _AXUIElementGetWindow(focusedWindow, &focusedID)
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

    /// Raise a window and make it the focused window of its (activated) app.
    /// Returns false if the element is dead (window closed since it was listed).
    @discardableResult
    private func raiseWindow(_ window: AXUIElement, of app: NSRunningApplication) -> Bool {
        // A closed window's element answers no attribute queries - detect and skip it
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef) == .success else {
            return false
        }

        // Un-minimize first, otherwise raising does nothing visible
        var minimizedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
           (minimizedRef as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)

        // Activate after making the window main so macOS switches to its space
        // if needed. Harmless when the app is already active.
        let activated = app.activate(options: [.activateIgnoringOtherApps])
        if !activated && !app.isActive {
            print("[AppManager] Activate failed, using AppleScript fallback...")
            activateViaAppleScript(bundleId: app.bundleIdentifier ?? "", appName: app.localizedName ?? "")
        }
        return true
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

    // MARK: - App metadata helpers

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
