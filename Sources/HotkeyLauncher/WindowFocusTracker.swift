import Cocoa
import ApplicationServices

/// Remembers when each window (by CGWindowID) was last focused by the user.
///
/// Window cycling wants windows in most-recently-used order, but the window
/// server's z-order is a poor proxy for it: every window a cycle session
/// raises jumps to the front even though the user only passed through it,
/// and windows on other spaces have no observable z-order at all. So we keep
/// our own clock: an AX observer follows the frontmost app's focused window,
/// and ApplicationManager suppresses stamping during a cycle session so only
/// the window the cycle finally lands on counts as "used" - the same rule
/// Windows alt-tab applies.
final class WindowFocusTracker {
    static let shared = WindowFocusTracker()

    private var stamps: [CGWindowID: Date] = [:]

    /// While set, focus changes in this process are not recorded: a cycle
    /// session is raising windows the user is only passing through
    private var suppressedPid: pid_t?

    private var observer: AXObserver?
    private var observedAppElement: AXUIElement?
    private var workspaceObserver: NSObjectProtocol?

    private init() {}

    /// When each known window was last genuinely focused
    var lastFocusTimes: [CGWindowID: Date] { stamps }

    /// Start following the frontmost application's focused window
    func start() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.follow(app)
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            follow(frontmost)
        }
    }

    // MARK: - Cycle suppression

    /// Ignore focus changes in `pid` until the current cycle session commits
    func beginCycleSuppression(pid: pid_t) {
        suppressedPid = pid
    }

    /// The cycle session is over: the window it landed on (if any) is the one
    /// the user actually switched to, so record it as used now
    func endCycleSuppression(stampingFinal window: AXUIElement?) {
        suppressedPid = nil
        if let window = window {
            stamp(window)
        }
    }

    // MARK: - Focus observation

    private func follow(_ app: NSRunningApplication) {
        detach()
        let pid = app.processIdentifier
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return }

        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon = refcon else { return }
            Unmanaged<WindowFocusTracker>.fromOpaque(refcon).takeUnretainedValue()
                .handleFocusNotification(element)
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success,
              let axObserver = newObserver else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(axObserver, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(axObserver, appElement, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)

        observer = axObserver
        observedAppElement = appElement

        // The window that's focused as the app becomes frontmost counts as used
        stampFocusedWindow(of: appElement, pid: pid)
    }

    private func detach() {
        if let observer = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedAppElement = nil
    }

    private func handleFocusNotification(_ element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != suppressedPid else { return }

        // The notification's element is normally the newly focused window;
        // if its ID isn't resolvable, ask the app for its focused window
        var windowID: CGWindowID = 0
        _ = _AXUIElementGetWindow(element, &windowID)
        if windowID != 0 {
            record(windowID)
        } else if let appElement = observedAppElement {
            stampFocusedWindow(of: appElement, pid: pid)
        }
    }

    private func stampFocusedWindow(of appElement: AXUIElement, pid: pid_t) {
        guard pid != suppressedPid else { return }
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return }
        stamp(focused as! AXUIElement)
    }

    private func stamp(_ window: AXUIElement) {
        var windowID: CGWindowID = 0
        _ = _AXUIElementGetWindow(window, &windowID)
        if windowID != 0 {
            record(windowID)
        }
    }

    private func record(_ windowID: CGWindowID) {
        stamps[windowID] = Date()
        // Windows come and go; keep the map from growing forever
        if stamps.count > 1024 {
            let cutoff = stamps.values.sorted(by: >)[512]
            stamps = stamps.filter { $0.value > cutoff }
        }
    }
}
