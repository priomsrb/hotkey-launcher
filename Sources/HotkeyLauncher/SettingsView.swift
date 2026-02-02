import SwiftUI
import AppKit

struct SettingsView: View {
    enum SheetMode: Identifiable {
        case add
        case addWithApp(String)
        case edit(Hotkey)
        
        var id: String {
            switch self {
            case .add: return "add"
            case .addWithApp(let b): return "add-\(b)"
            case .edit(let h): return "edit-\(h.bundleId)"
            }
        }
    }
    
    @State private var hotkeys: [Hotkey] = []
    @State private var exceptions: [String] = []
    @State private var runningApps: [NSRunningApplication] = []
    @State private var sheetMode: SheetMode?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var onClose: (() -> Void)? = nil
    
    @State private var newAppBundleId = ""
    @State private var newKey = ""
    @State private var newModifiers: [String] = []
    
    struct AppItem: Identifiable {
        let bundleId: String
        let name: String
        let hotkey: Hotkey?
        let runningApp: NSRunningApplication?
        var id: String { bundleId }
    }
    
    private var combinedApps: [AppItem] {
        var items: [AppItem] = []
        for hotkey in hotkeys {
            let name = ApplicationManager.shared.getAppName(bundleId: hotkey.bundleId)
            items.append(AppItem(bundleId: hotkey.bundleId, name: name, hotkey: hotkey, runningApp: nil))
        }
        for app in runningApps {
            if let bundleId = app.bundleIdentifier {
                let name = app.localizedName ?? "Unknown"
                items.append(AppItem(bundleId: bundleId, name: name, hotkey: nil, runningApp: app))
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            List {
                Section(header: Text("Applications").font(.caption).foregroundColor(.secondary)) {
                    ForEach(combinedApps) { item in
                        HStack {
                            if let icon = ApplicationManager.shared.getAppIcon(bundleId: item.bundleId) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 32, height: 32)
                            } else {
                                Image(systemName: "app.dashed")
                                    .resizable()
                                    .frame(width: 32, height: 32)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.headline)
                            }
                            
                            Spacer()
                            
                            if let hotkey = item.hotkey {
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
                            } else if let app = item.runningApp {
                                Button(action: {
                                    assignHotkey(for: app)
                                }) {
                                    Text("Assign Hotkey")
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.1))
                                        .cornerRadius(4)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let hotkey = item.hotkey {
                                editHotkey(hotkey)
                            } else if let app = item.runningApp {
                                assignHotkey(for: app)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                if !exceptions.isEmpty {
                    Section(header: Text("Exceptions (Hotkeys disabled when these apps are focused)").font(.caption).foregroundColor(.secondary)) {
                        ForEach(exceptions, id: \.self) { bundleId in
                            HStack {
                                if let icon = ApplicationManager.shared.getAppIcon(bundleId: bundleId) {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 24, height: 24)
                                } else {
                                    Image(systemName: "app.badge.minus")
                                        .resizable()
                                        .frame(width: 24, height: 24)
                                }
                                
                                Text(ApplicationManager.shared.getAppName(bundleId: bundleId))
                                
                                Spacer()
                                
                                Button(action: {
                                    deleteException(bundleId)
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.vertical, 2)
                        }
                    }
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
                .padding(.leading)
                .padding(.vertical)
                
                Button(action: {
                    addException()
                }) {
                    Label("Add Exception", systemImage: "plus")
                }
                .padding(.leading)
                .padding(.vertical)
                
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
            let config = ConfigManager.shared.loadConfig()
            hotkeys = config.hotkeys
            exceptions = config.exceptions
            updateRunningApps()
        }
        .onReceive(timer) { _ in
            updateRunningApps()
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
                    .keyboardShortcut(.cancelAction)
                    
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
        switch mode {
        case .edit(let h):
            newAppBundleId = h.bundleId
            newKey = h.key
            newModifiers = h.modifiers
        case .addWithApp(let b):
            newAppBundleId = b
            newKey = ""
            newModifiers = []
        case .add:
            newAppBundleId = ""
            newKey = ""
            newModifiers = []
        }
    }
    
    private func closeWindow() {
        if let onClose = onClose {
            onClose()
        } else {
            NSApplication.shared.keyWindow?.close()
        }
    }
    
    private func deleteHotkey(_ hotkey: Hotkey) {
        hotkeys.removeAll { $0.id == hotkey.id }
        saveToConfig()
    }
    
    private func deleteException(_ bundleId: String) {
        exceptions.removeAll { $0 == bundleId }
        saveToConfig()
    }
    
    private func prepareForAdd() {
        sheetMode = .add
    }
    
    private func addException() {
        ApplicationManager.shared.pickApplication { bundleId in
            if let bundleId = bundleId {
                if !exceptions.contains(bundleId) {
                    exceptions.append(bundleId)
                    saveToConfig()
                }
            }
        }
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
        let config = HotkeyConfig(hotkeys: hotkeys, exceptions: exceptions)
        ConfigManager.shared.saveConfig(config)
        HotkeyManager.shared.updateConfig(hotkeys: hotkeys, exceptions: exceptions)
        updateRunningApps()
    }
    
    private func updateRunningApps() {
        let allRunning = ApplicationManager.shared.getRunningApplications()
        let existingBundleIds = Set(hotkeys.map { $0.bundleId })
        runningApps = allRunning.filter { app in
            guard let bundleId = app.bundleIdentifier else { return false }
            return !existingBundleIds.contains(bundleId)
        }
    }
    
    private func assignHotkey(for app: NSRunningApplication) {
        if let bundleId = app.bundleIdentifier {
            sheetMode = .addWithApp(bundleId)
        }
    }
}
