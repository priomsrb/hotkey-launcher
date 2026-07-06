import Cocoa
import Carbon

/// Manages global hotkey registration using Carbon's RegisterEventHotKey.
/// Unlike a CGEvent tap, registered hotkeys keep working while macOS Secure
/// Input is active (e.g. a password field has focus), and no Accessibility
/// permission is needed.
class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotkeys: [Hotkey] = []
    private var exceptions: [String] = []
    private var hotkeyCallback: ((Hotkey) -> Void)?

    private var eventHandler: EventHandlerRef?
    /// Registered hotkeys keyed by their EventHotKeyID.id
    private var registeredHotkeys: [UInt32: (ref: EventHotKeyRef, hotkey: Hotkey)] = [:]
    private var workspaceObserver: NSObjectProtocol?

    /// "HKLR" — identifies our registrations in the Carbon event handler
    private let signature: OSType = 0x484B_4C52

    /// While recording a new shortcut, all hotkeys are unregistered so the
    /// key combo reaches the recorder view instead of being consumed globally.
    var isRecording: Bool = false {
        didSet { refreshRegistration() }
    }

    private init() {}

    /// Register hotkeys and start listening for key events
    /// - Parameters:
    ///   - hotkeys: Array of hotkey configurations
    ///   - callback: Called when a registered hotkey is pressed
    func start(hotkeys: [Hotkey], exceptions: [String], callback: @escaping (Hotkey) -> Void) {
        self.hotkeys = hotkeys
        self.exceptions = exceptions
        self.hotkeyCallback = callback

        installEventHandler()

        // Carbon hotkeys can't pass a matched event through to the frontmost
        // app, so exceptions are handled by unregistering all hotkeys while an
        // exception app is active — the key combos then reach it normally.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }

        refreshRegistration()
    }

    /// Stop listening for hotkeys
    func stop() {
        unregisterAll()

        if let workspaceObserver = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }

        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    /// Update the registered hotkeys and exceptions
    func updateConfig(hotkeys: [Hotkey], exceptions: [String]) {
        unregisterAll()
        self.hotkeys = hotkeys
        self.exceptions = exceptions
        refreshRegistration()
    }

    /// Update the registered hotkeys (legacy)
    func updateHotkeys(_ hotkeys: [Hotkey]) {
        updateConfig(hotkeys: hotkeys, exceptions: exceptions)
    }

    /// Install the Carbon event handler that receives hotkey presses
    private func installEventHandler() {
        guard eventHandler == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, refcon) -> OSStatus in
                guard let event = event, let refcon = refcon else { return noErr }

                var hotkeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                guard status == noErr else { return status }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleHotkeyPress(hotkeyID)
                return noErr
            },
            1,
            &eventSpec,
            refcon,
            &eventHandler
        )

        if status != noErr {
            print("[HotkeyManager] ❌ Failed to install event handler (status \(status))")
        }
    }

    /// Register or unregister all hotkeys based on the current state
    /// (recording mode and whether the frontmost app is an exception)
    private func refreshRegistration() {
        if isRecording || frontmostAppIsException() {
            unregisterAll()
        } else {
            registerAll()
        }
    }

    private func frontmostAppIsException() -> Bool {
        guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return exceptions.contains(bundleId)
    }

    private func registerAll() {
        guard registeredHotkeys.isEmpty else { return }

        for (index, hotkey) in hotkeys.enumerated() {
            guard let keyCode = hotkey.keyCode else {
                print("[HotkeyManager] ⚠️ Unknown key \"\(hotkey.key)\", skipping \(hotkey.bundleId)")
                continue
            }
            let carbonModifiers = hotkey.carbonModifiers
            guard carbonModifiers != 0 else {
                print("[HotkeyManager] ⚠️ Hotkeys without modifiers are not supported, skipping \(hotkey.bundleId)")
                continue
            }

            let id = UInt32(index + 1)
            let hotkeyID = EventHotKeyID(signature: signature, id: id)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                carbonModifiers,
                hotkeyID,
                GetEventDispatcherTarget(),
                0,
                &ref
            )

            if status == noErr, let ref = ref {
                registeredHotkeys[id] = (ref, hotkey)
            } else {
                print("[HotkeyManager] ❌ Failed to register \(hotkey.displayString) for \(hotkey.bundleId) (status \(status))")
            }
        }

        print("[HotkeyManager] ✅ Registered \(registeredHotkeys.count) hotkeys")
    }

    private func unregisterAll() {
        guard !registeredHotkeys.isEmpty else { return }

        for (_, entry) in registeredHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        registeredHotkeys.removeAll()

        print("[HotkeyManager] Unregistered all hotkeys")
    }

    private func handleHotkeyPress(_ hotkeyID: EventHotKeyID) {
        guard hotkeyID.signature == signature,
              let entry = registeredHotkeys[hotkeyID.id] else {
            return
        }

        print("[HotkeyManager] ✅ MATCH! Triggering: \(entry.hotkey.bundleId)")
        DispatchQueue.main.async {
            self.hotkeyCallback?(entry.hotkey)
        }
    }
}
