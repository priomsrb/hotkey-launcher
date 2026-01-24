import Cocoa
import Carbon

/// Manages global hotkey registration and handling using CGEvent taps
class HotkeyManager {
    static let shared = HotkeyManager()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotkeys: [Hotkey] = []
    private var hotkeyCallback: ((Hotkey) -> Void)?
    
    private init() {}
    
    /// Register hotkeys and start listening for key events
    /// - Parameters:
    ///   - hotkeys: Array of hotkey configurations
    ///   - callback: Called when a registered hotkey is pressed
    func start(hotkeys: [Hotkey], callback: @escaping (Hotkey) -> Void) {
        self.hotkeys = hotkeys
        self.hotkeyCallback = callback
        
        guard checkAccessibilityPermissions() else {
            print("Accessibility permissions not granted")
            return
        }
        
        setupEventTap()
    }
    
    /// Stop listening for hotkeys
    func stop() {
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
    }
    
    /// Update the registered hotkeys without restarting the event tap
    func updateHotkeys(_ hotkeys: [Hotkey]) {
        self.hotkeys = hotkeys
    }
    
    /// Check if accessibility permissions are granted
    private func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    /// Set up the CGEvent tap to intercept keyboard events
    private func setupEventTap() {
        // Create event tap for keydown events
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        // Store self in a context that can be passed to the callback
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passRetained(event)
                }
                
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        )
        
        guard let eventTap = eventTap else {
            print("Failed to create event tap. Check accessibility permissions.")
            return
        }
        
        // Create run loop source and add to current run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        // Enable the event tap
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        print("Hotkey manager started with \(hotkeys.count) hotkeys")
    }
    
    /// Handle an incoming keyboard event
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap disabled events (re-enable if needed)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }
        
        guard type == .keyDown else {
            return Unmanaged.passRetained(event)
        }
        
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        
        // Check against registered hotkeys
        for hotkey in hotkeys {
            guard let hotkeyCode = hotkey.keyCode,
                  keyCode == hotkeyCode else {
                continue
            }
            
            // Check modifiers match (ignoring non-modifier flags)
            let requiredFlags = hotkey.cgEventFlags
            let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            let activeModifiers = flags.intersection(modifierMask)
            
            if activeModifiers == requiredFlags {
                // Match found! Call the callback on main thread
                DispatchQueue.main.async {
                    self.hotkeyCallback?(hotkey)
                }
                // Consume the event (don't pass to other apps)
                return nil
            }
        }
        
        // Not a registered hotkey, pass through
        return Unmanaged.passRetained(event)
    }
}
