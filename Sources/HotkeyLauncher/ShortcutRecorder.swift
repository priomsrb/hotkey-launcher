import SwiftUI
import Carbon

struct ShortcutRecorder: View {
    @Binding var key: String
    @Binding var modifiers: [String]
    @State private var isFocused = false
    
    var body: some View {
        ZStack {
            ShortcutNSViewRepresentable(key: $key, modifiers: $modifiers, isFocused: $isFocused)
            
            if key.isEmpty {
                Text(isFocused ? "Recording... Press keys" : "Click to record shortcut")
                    .foregroundColor(isFocused ? .accentColor : .secondary)
                    .font(.headline)
            } else {
                VStack {
                    Text(displayString(key: key, mods: modifiers))
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                    
                    if isFocused {
                        Text("Press new keys to change")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
            }
        }
    }
    
    private func displayString(key: String, mods: [String]) -> String {
        var result = ""
        for modifier in mods {
            switch modifier.lowercased() {
            case "cmd", "command": result += "⌘"
            case "opt", "option", "alt": result += "⌥"
            case "ctrl", "control": result += "⌃"
            case "shift": result += "⇧"
            default: break
            }
        }
        result += key.uppercased()
        return result
    }
}

struct ShortcutNSViewRepresentable: NSViewRepresentable {
    @Binding var key: String
    @Binding var modifiers: [String]
    @Binding var isFocused: Bool
    
    class Coordinator: NSObject {
        var parent: ShortcutNSViewRepresentable
        
        init(_ parent: ShortcutNSViewRepresentable) {
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
        view.onFocusChange = { focused in
            DispatchQueue.main.async {
                self.isFocused = focused
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class ShortcutNSView: NSView {
    var onKeyEvent: ((NSEvent) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        onKeyEvent?(event)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        
        if window?.firstResponder == self {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 3
            
            // Add a subtle background highlight
            NSColor.controlAccentColor.withAlphaComponent(0.05).setFill()
            path.fill()
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
        }
        
        path.stroke()
    }
    
    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        onFocusChange?(true)
        return super.becomeFirstResponder()
    }
    
    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        onFocusChange?(false)
        return super.resignFirstResponder()
    }
}
