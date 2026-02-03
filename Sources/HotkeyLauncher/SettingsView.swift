import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var hotkeys: [Hotkey] = []
    @State private var exceptions: [String] = []
    @State private var runningApps: [NSRunningApplication] = []
    @State private var recordingBundleId: String? = nil
    @State private var tempKey = ""
    @State private var tempModifiers: [String] = []
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var onClose: (() -> Void)? = nil
    
    struct AppItem: Identifiable {
        let bundleId: String
        let name: String
        let hotkey: Hotkey?
        let runningApp: NSRunningApplication?
        let hasConflict: Bool
        var id: String { bundleId }
    }
    
    private var combinedApps: [AppItem] {
        var items: [AppItem] = []
        let allHotkeys = hotkeys
        
        for hotkey in hotkeys {
            let name = ApplicationManager.shared.getAppName(bundleId: hotkey.bundleId)
            let hasConflict = allHotkeys.contains { other in
                other.bundleId != hotkey.bundleId && 
                !other.key.isEmpty && 
                other.key == hotkey.key && 
                other.modifiers.sorted() == hotkey.modifiers.sorted()
            }
            items.append(AppItem(bundleId: hotkey.bundleId, name: name, hotkey: hotkey, runningApp: nil, hasConflict: hasConflict))
        }
        for app in runningApps {
            if let bundleId = app.bundleIdentifier {
                let name = app.localizedName ?? "Unknown"
                items.append(AppItem(bundleId: bundleId, name: name, hotkey: nil, runningApp: app, hasConflict: false))
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List {
                    sectionApplications
                    sectionExceptions
                }
                .listStyle(InsetListStyle())
                .onChange(of: recordingBundleId) { newValue in
                    HotkeyManager.shared.isRecording = (newValue != nil)
                    if let bundleId = newValue {
                        withAnimation {
                            proxy.scrollTo(bundleId, anchor: .center)
                        }
                    }
                }
            }
            
            Divider()
            footerView
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear(perform: loadData)
        .onReceive(timer) { _ in updateRunningApps() }
        .onChange(of: tempKey, perform: handleTempKeyChange)
    }

    private var sectionApplications: some View {
        Section(header: Text("Applications").font(.caption).foregroundColor(.secondary)) {
            ForEach(combinedApps) { item in
                AppRow(
                    item: item,
                    recordingBundleId: $recordingBundleId,
                    tempKey: $tempKey,
                    tempModifiers: $tempModifiers,
                    hotkeys: $hotkeys,
                    onDelete: deleteHotkey,
                    onStartRecording: startRecording,
                    onSave: saveToConfig
                )
                .id(item.bundleId)
            }
        }
    }

    private var sectionExceptions: some View {
        Group {
            if !exceptions.isEmpty {
                Section(header: Text("Exceptions (Hotkeys disabled when these apps are focused)").font(.caption).foregroundColor(.secondary)) {
                    ForEach(exceptions, id: \.self) { bundleId in
                        ExceptionRow(bundleId: bundleId, onDelete: deleteException)
                    }
                }
            }
        }
    }

    private var footerView: some View {
        HStack {
            Button(action: prepareForAdd) {
                Label("Add Hotkey", systemImage: "plus")
            }
            .padding(.leading)
            .padding(.vertical)
            
            Button(action: addException) {
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
            
            // Hidden buttons for global shortcuts
            Group {
                Button("") { 
                    if recordingBundleId == nil {
                        closeWindow() 
                    }
                }.keyboardShortcut(.cancelAction)
                Button("") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }
            .opacity(0).frame(width: 0, height: 0)
        }
    }

    private func loadData() {
        let config = ConfigManager.shared.loadConfig()
        hotkeys = config.hotkeys
        exceptions = config.exceptions
        updateRunningApps()
    }

    private func handleTempKeyChange(_ newValue: String) {
        if !newValue.isEmpty, let bundleId = recordingBundleId {
            saveOrAddHotkey(bundleId: bundleId, key: newValue, modifiers: tempModifiers)
            recordingBundleId = nil
            tempKey = ""
            tempModifiers = []
        }
    }

    private func prepareForAdd() {
        ApplicationManager.shared.pickApplication { bundleId in
            if let bundleId = bundleId {
                if !hotkeys.contains(where: { $0.bundleId == bundleId }) {
                    let placeholder = Hotkey(key: "", modifiers: [], bundleId: bundleId)
                    hotkeys.append(placeholder)
                    saveToConfig()
                }
                startRecording(for: bundleId)
            }
        }
    }
    
    private func startRecording(for bundleId: String) {
        recordingBundleId = bundleId
        tempKey = ""
        tempModifiers = []
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
    
    private func saveOrAddHotkey(bundleId: String, key: String, modifiers: [String]) {
        if key.isEmpty { return }
        let newHotkey = Hotkey(key: key, modifiers: modifiers, bundleId: bundleId)
        
        if let index = hotkeys.firstIndex(where: { $0.bundleId == bundleId }) {
            hotkeys[index] = newHotkey
        } else {
            hotkeys.append(newHotkey)
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
}

private struct AppRow: View {
    let item: SettingsView.AppItem
    @Binding var recordingBundleId: String?
    @Binding var tempKey: String
    @Binding var tempModifiers: [String]
    @Binding var hotkeys: [Hotkey]
    let onDelete: (Hotkey) -> Void
    let onStartRecording: (String) -> Void
    let onSave: () -> Void

    var body: some View {
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
                if item.hasConflict {
                    Label("Shortcut conflict", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if item.hotkey == nil || item.hotkey?.key.isEmpty == true {
                    Text("No hotkey assigned")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if recordingBundleId == item.bundleId {
                ShortcutNSViewRepresentable(key: $tempKey, modifiers: $tempModifiers, isFocused: .constant(true), onCancel: {
                    recordingBundleId = nil
                    tempKey = ""
                    tempModifiers = []
                    hotkeys.removeAll { $0.bundleId == item.bundleId && $0.key.isEmpty }
                }, onUnassign: {
                    if let hotkey = item.hotkey {
                        onDelete(hotkey)
                    }
                    recordingBundleId = nil
                    tempKey = ""
                    tempModifiers = []
                })
                .frame(width: 150, height: 30)
                .overlay(
                    Text("Recording... Press keys")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(4)
                        .allowsHitTesting(false)
                )
            } else if let hotkey = item.hotkey, !hotkey.key.isEmpty {
                Text(hotkey.displayString)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
                    .onTapGesture {
                        onStartRecording(item.bundleId)
                    }
                
                Button(action: {
                    onDelete(hotkey)
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 8)
            } else {
                Button(action: {
                    onStartRecording(item.bundleId)
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
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(recordingBundleId == item.bundleId ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }
}

private struct ExceptionRow: View {
    let bundleId: String
    let onDelete: (String) -> Void

    var body: some View {
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
                onDelete(bundleId)
            }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 2)
    }
}
