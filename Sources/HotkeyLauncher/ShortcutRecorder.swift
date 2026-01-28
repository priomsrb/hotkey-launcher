import SwiftUI
import Carbon

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var key: String
    @Binding var modifiers: [String]
    
    class Coordinator: NSObject {
        var parent: ShortcutRecorder
        
        init(_ parent: ShortcutRecorder) {
            self.parent = parent
        }
        
        @objc func handleKeyEvent(_ event: NSEvent) {
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags
            
            var mods: [String] = []
            if modifierFlags.contains(.command) { mods.append("cmd") }
            if modifierFlags.contains(.option) { mods.append("opt") }
            if modifierFlags.contains(.control) { mods.append("ctrl") }
            if modifierFlags.contains(.shift) { mods.append("shift") }
            
            // Map common key codes to strings
            let keyStr = mapKeyCode(keyCode) ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
            
            if !keyStr.isEmpty && !mods.isEmpty {
                parent.key = keyStr
                parent.modifiers = mods
            }
        }
        
        private func mapKeyCode(_ keyCode: UInt16) -> String? {
            // This should match Hotkey.keyCodeMap in reverse
            let map: [UInt16: String] = [
                0x31: "space", 0x35: "escape", 0x32: "`", 0x1B: "-", 0x18: "=",
                0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";", 0x27: "'",
                0x2B: ",", 0x2F: ".", 0x2C: "/"
            ]
            return map[keyCode]
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> NSView {
        let view = ShortcutNSView()
        view.onKeyEvent = context.coordinator.handleKeyEvent
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class ShortcutNSView: NSView {
    var onKeyEvent: ((NSEvent) -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        onKeyEvent?(event)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if window?.firstResponder == self {
            NSColor.selectedControlColor.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }
    }
    
    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
    
    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }
}
