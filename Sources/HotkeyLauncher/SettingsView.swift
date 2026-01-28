import SwiftUI

struct SettingsView: View {
    enum SheetMode: Identifiable {
        case add
        case edit(Hotkey)
        
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let h): return "edit-\(h.bundleId)"
            }
        }
    }
    
    @State private var hotkeys: [Hotkey] = []
    @State private var sheetMode: SheetMode?
    
    @State private var newAppBundleId = ""
    @State private var newKey = ""
    @State private var newModifiers: [String] = []
    
    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(hotkeys) { hotkey in
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
                            editHotkey(hotkey)
                        }) {
                            Image(systemName: "pencil")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.leading, 8)
                        
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
                    prepareForAdd()
                }) {
                    Label("Add Hotkey", systemImage: "plus")
                }
                .padding()
                
                Spacer()
                
                Button("Done") {
                    closeWindow()
                }
                .keyboardShortcut("w", modifiers: .command)
                .keyboardShortcut(.defaultAction)
                .padding()
            }
            
            // Hidden buttons for global shortcuts
            Group {
                Button("") { closeWindow() }.keyboardShortcut(.cancelAction)
                Button("") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }
            .opacity(0).frame(width: 0, height: 0)
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            hotkeys = ConfigManager.shared.loadHotkeys()
        }
        .sheet(item: $sheetMode) { mode in
            VStack(spacing: 20) {
                Text(title(for: mode))
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
                        .frame(height: 120)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(8)
                }
                
                HStack {
                    Button("Cancel") {
                        sheetMode = nil
                    }
                    
                    Spacer()
                    
                    Button(saveButtonTitle(for: mode)) {
                        saveOrAddHotkey(original: hotkey(from: mode))
                        sheetMode = nil
                    }
                    .disabled(newAppBundleId.isEmpty || newKey.isEmpty)
                    .buttonStyle(BorderedProminentButtonStyle())
                }
            }
            .padding(30)
            .frame(width: 400)
            .onAppear {
                initializeForm(from: mode)
            }
        }
    }
    
    private func title(for mode: SheetMode) -> String {
        if case .edit = mode { return "Edit Hotkey" }
        return "Add New Hotkey"
    }
    
    private func saveButtonTitle(for mode: SheetMode) -> String {
        if case .edit = mode { return "Save" }
        return "Add"
    }
    
    private func hotkey(from mode: SheetMode) -> Hotkey? {
        if case .edit(let h) = mode { return h }
        return nil
    }
    
    private func initializeForm(from mode: SheetMode) {
        if case .edit(let h) = mode {
            newAppBundleId = h.bundleId
            newKey = h.key
            newModifiers = h.modifiers
        } else {
            newAppBundleId = ""
            newKey = ""
            newModifiers = []
        }
    }
    
    private func closeWindow() {
        NSApplication.shared.keyWindow?.close()
    }
    
    private func deleteHotkey(_ hotkey: Hotkey) {
        hotkeys.removeAll { $0.id == hotkey.id }
        saveToConfig()
    }
    
    private func prepareForAdd() {
        sheetMode = .add
    }
    
    private func editHotkey(_ hotkey: Hotkey) {
        sheetMode = .edit(hotkey)
    }
    
    private func saveOrAddHotkey(original: Hotkey?) {
        let newHotkey = Hotkey(key: newKey, modifiers: newModifiers, bundleId: newAppBundleId)
        
        if let original = original {
            if let index = hotkeys.firstIndex(where: { $0.id == original.id }) {
                hotkeys[index] = newHotkey
            } else {
                hotkeys.append(newHotkey)
            }
        } else {
            if let index = hotkeys.firstIndex(where: { $0.bundleId == newAppBundleId }) {
                hotkeys[index] = newHotkey
            } else {
                hotkeys.append(newHotkey)
            }
        }
        
        saveToConfig()
    }
    
    private func saveToConfig() {
        ConfigManager.shared.saveHotkeys(hotkeys)
        HotkeyManager.shared.updateHotkeys(hotkeys)
    }
}
