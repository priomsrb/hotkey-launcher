import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var hotkeys: [Hotkey] = []
    @State private var exceptions: [String] = []
    @State private var runningApps: [NSRunningApplication] = []
    @State private var recordingBundleId: String? = nil
    @State private var tempKey = ""
    @State private var tempModifiers: [String] = []
    @State private var searchText = ""
    @State private var selectedRow: RowID? = nil
    @FocusState private var focusTarget: FocusTarget?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var onClose: (() -> Void)? = nil

    // An app can appear both as an Applications row and an Exceptions row,
    // so selection needs more than the bundle id.
    enum RowID: Hashable {
        case app(String)
        case exception(String)

        var bundleId: String {
            switch self {
            case .app(let id), .exception(let id): return id
            }
        }
    }

    enum FocusTarget: Hashable {
        case search
        case list
    }

    struct AppItem: Identifiable {
        let bundleId: String
        let name: String
        let hotkey: Hotkey?
        let runningApp: NSRunningApplication?
        let hasConflict: Bool
        var id: RowID { .app(bundleId) }
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

    private var filteredApps: [AppItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return combinedApps }
        return combinedApps.filter { matchesSearch($0, query: query) }
    }

    private var filteredExceptions: [String] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return exceptions }
        return exceptions.filter {
            ApplicationManager.shared.getAppName(bundleId: $0).localizedCaseInsensitiveContains(query)
        }
    }

    private func matchesSearch(_ item: AppItem, query: String) -> Bool {
        if item.name.localizedCaseInsensitiveContains(query) {
            return true
        }
        guard let hotkey = item.hotkey, !hotkey.key.isEmpty else { return false }
        if hotkey.displayString.localizedCaseInsensitiveContains(query) {
            return true
        }
        let parts = hotkey.modifiers + [hotkey.key]
        return parts.joined(separator: " ").localizedCaseInsensitiveContains(query)
            || parts.joined(separator: "+").localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(selection: $selectedRow) {
                    sectionApplications
                    sectionExceptions
                }
                .listStyle(InsetListStyle())
                .focused($focusTarget, equals: .list)
                .onDeleteCommand(perform: deleteSelectedRow)
                .onChange(of: recordingBundleId) { newValue in
                    HotkeyManager.shared.isRecording = (newValue != nil)
                    if let bundleId = newValue {
                        withAnimation {
                            proxy.scrollTo(RowID.app(bundleId), anchor: .center)
                        }
                    } else {
                        // Recording ended (saved or cancelled): hand focus back
                        // to the list so arrow keys keep working.
                        DispatchQueue.main.async { focusTarget = .list }
                    }
                }
            }

            Divider()
            footerView
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            loadData()
            if selectedRow == nil {
                selectedRow = allRowIDs.first
            }
            DispatchQueue.main.async { focusTarget = .list }
        }
        .onReceive(timer) { _ in updateRunningApps() }
        .onChange(of: tempKey, perform: handleTempKeyChange)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundColor(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.callout)
                .focused($focusTarget, equals: .search)
                .onSubmit(selectFirstMatch)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(width: 160)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(5)
    }

    private var sectionApplications: some View {
        Section(header: HStack {
            Text("Applications").font(.callout).foregroundColor(.secondary)
            Spacer()
            searchField
        }) {
            ForEach(filteredApps) { item in
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
            }
        }
    }

    private var sectionExceptions: some View {
        Group {
            if !filteredExceptions.isEmpty {
                Section(header: Text("Exceptions (Hotkeys disabled when these apps are focused)").font(.callout).foregroundColor(.secondary)) {
                    ForEach(filteredExceptions.map { RowID.exception($0) }, id: \.self) { row in
                        ExceptionRow(bundleId: row.bundleId, onDelete: deleteException)
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
            .keyboardShortcut("n", modifiers: .command)
            .help("Add Hotkey (⌘N)")
            .padding(.leading)
            .padding(.vertical)

            Button(action: addException) {
                Label("Add Exception", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("Add Exception (⇧⌘N)")
            .padding(.leading)
            .padding(.vertical)

            Spacer()

            Button("Done") {
                closeWindow()
            }
            .keyboardShortcut("w", modifiers: .command)
            .help("Close (⌘W)")
            .padding()

            // Hidden buttons for global shortcuts
            Group {
                Button("") { handleEscape() }.keyboardShortcut(.cancelAction)
                Button("") { handleReturn() }.keyboardShortcut(.return, modifiers: [])
                Button("") { focusTarget = .search }.keyboardShortcut("f", modifiers: .command)
                Button("") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }
            .opacity(0).frame(width: 0, height: 0)
        }
    }

    private var allRowIDs: [RowID] {
        filteredApps.map { RowID.app($0.bundleId) } + filteredExceptions.map { RowID.exception($0) }
    }

    private func handleReturn() {
        if recordingBundleId != nil { return }
        if focusTarget == .search {
            selectFirstMatch()
            return
        }
        if case .app(let bundleId) = selectedRow {
            startRecording(for: bundleId)
        }
    }

    private func handleEscape() {
        if recordingBundleId != nil { return } // the recorder handles its own Escape
        if focusTarget == .search || !searchText.isEmpty {
            searchText = ""
            focusTarget = .list
        } else {
            closeWindow()
        }
    }

    private func selectFirstMatch() {
        if let first = allRowIDs.first {
            selectedRow = first
        }
        focusTarget = .list
    }

    private func deleteSelectedRow() {
        guard let row = selectedRow else { return }
        let rowsBefore = allRowIDs
        let index = rowsBefore.firstIndex(of: row)

        switch row {
        case .app(let bundleId):
            guard let hotkey = hotkeys.first(where: { $0.bundleId == bundleId }) else { return }
            deleteHotkey(hotkey)
        case .exception(let bundleId):
            deleteException(bundleId)
        }

        // Keep the selection useful: stay on the row if it still exists
        // (running apps keep their row after losing a hotkey), otherwise
        // move to the nearest neighbor.
        let rowsAfter = allRowIDs
        if rowsAfter.contains(row) {
            selectedRow = row
        } else if let index = index, !rowsAfter.isEmpty {
            selectedRow = rowsAfter[min(index, rowsAfter.count - 1)]
        } else {
            selectedRow = rowsAfter.first
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
        if !filteredApps.contains(where: { $0.bundleId == bundleId }) {
            searchText = ""
        }
        selectedRow = .app(bundleId)
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
            Group {
                if let icon = ApplicationManager.shared.getAppIcon(bundleId: item.bundleId) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .frame(width: 32, height: 32)
                }
            }
            .accessibilityHidden(true)
            
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
                Button(action: {
                    onStartRecording(item.bundleId)
                }) {
                    Text(hotkey.displayString)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Hotkey \(hotkey.displayString) for \(item.name)")
                .accessibilityHint("Records a new hotkey")

                Button(action: {
                    onDelete(hotkey)
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 8)
                .accessibilityLabel("Remove hotkey for \(item.name)")
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
                .accessibilityLabel("Assign hotkey for \(item.name)")
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
            Group {
                if let icon = ApplicationManager.shared.getAppIcon(bundleId: bundleId) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "app.badge.minus")
                        .resizable()
                        .frame(width: 24, height: 24)
                }
            }
            .accessibilityHidden(true)

            Text(ApplicationManager.shared.getAppName(bundleId: bundleId))

            Spacer()

            Button(action: {
                onDelete(bundleId)
            }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Remove exception for \(ApplicationManager.shared.getAppName(bundleId: bundleId))")
        }
        .padding(.vertical, 2)
    }
}
