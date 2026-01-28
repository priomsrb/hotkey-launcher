import SwiftUI

struct SettingsView: View {
    @State private var hotkeys: [Hotkey] = []
    @State private var showingAddSheet = false
    @State private var newAppBundleId = ""
    @State private var newKey = ""
    @State private var newModifiers: [String] = []
    
    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(hotkeys, id: \.bundleId) { hotkey in
                    HStack {
                        if let icon = ApplicationManager.shared.getAppIcon(bundleId: hotkey.bundleId) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 32, height: 32)
                        } else {
                            Image(systemName: "app.dashed")
                                .resizable()
                                .frame(width: 32, height: 32)
                        }
                        
                        VStack(alignment: .leading) {
                            Text(ApplicationManager.shared.getAppName(bundleId: hotkey.bundleId))
                                .font(.headline)
                            Text(hotkey.bundleId)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Text(hotkey.displayString)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                        
                        Button(action: {
                            deleteHotkey(hotkey)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.leading, 8)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(InsetListStyle())
            
            Divider()
            
            HStack {
                Button(action: {
                    showingAddSheet = true
                }) {
                    Label("Add Hotkey", systemImage: "plus")
                }
                .padding()
                
                Spacer()
                
                Button("Done") {
                    NSApplication.shared.keyWindow?.close()
                }
                .padding()
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            hotkeys = ConfigManager.shared.loadHotkeys()
        }
        .sheet(isPresented: $showingAddSheet) {
            VStack(spacing: 20) {
                Text("Add New Hotkey")
                    .font(.title2)
                    .bold()
                
                HStack {
                    Text("Application:")
                    Text(newAppBundleId.isEmpty ? "None selected" : ApplicationManager.shared.getAppName(bundleId: newAppBundleId))
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    Button("Select App...") {
                        ApplicationManager.shared.pickApplication { bundleId in
                            if let bundleId = bundleId {
                                newAppBundleId = bundleId
                            }
                        }
                    }
                }
                
                VStack(alignment: .leading) {
                    Text("Shortcut:")
                    ShortcutRecorder(key: $newKey, modifiers: $newModifiers)
                        .frame(height: 100)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(8)
                    
                    if !newKey.isEmpty {
                        Text("Recorded: \(displayString(key: newKey, mods: newModifiers))")
                            .font(.caption)
                            .padding(.top, 4)
                    } else {
                        Text("Focus the box and press keys...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }
                
                HStack {
                    Button("Cancel") {
                        resetNewHotkey()
                        showingAddSheet = false
                    }
                    
                    Spacer()
                    
                    Button("Add") {
                        addHotkey()
                        showingAddSheet = false
                    }
                    .disabled(newAppBundleId.isEmpty || newKey.isEmpty)
                    .buttonStyle(BorderedProminentButtonStyle())
                }
            }
            .padding(30)
            .frame(width: 400)
        }
    }
    
    private func deleteHotkey(_ hotkey: Hotkey) {
        hotkeys.removeAll { $0 == hotkey }
        saveHotkeys()
    }
    
    private func addHotkey() {
        let hotkey = Hotkey(key: newKey, modifiers: newModifiers, bundleId: newAppBundleId)
        hotkeys.append(hotkey)
        saveHotkeys()
        resetNewHotkey()
    }
    
    private func saveHotkeys() {
        ConfigManager.shared.saveHotkeys(hotkeys)
        HotkeyManager.shared.updateHotkeys(hotkeys)
    }
    
    private func resetNewHotkey() {
        newAppBundleId = ""
        newKey = ""
        newModifiers = []
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
