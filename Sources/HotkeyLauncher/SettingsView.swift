import SwiftUI
import AppKit
import ApplicationServices

struct SettingsView: View {
    @State private var hotkeys: [Hotkey] = []
    @State private var exceptions: [String] = []
    @State private var runningApps: [NSRunningApplication] = []
    @State private var recordingBundleId: String? = nil
    @State private var tempKey = ""
    @State private var tempModifiers: [String] = []
    @State private var searchText = ""
    @State private var filter: AppFilter = .all
    @State private var selectedRow: RowID? = nil
    @State private var axTrusted = AXIsProcessTrusted()
    @FocusState private var focusTarget: FocusTarget?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var onClose: (() -> Void)? = nil

    enum AppFilter: String, CaseIterable {
        case all = "All"
        case assigned = "Assigned"
        case unassigned = "Unassigned"
    }

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
        let conflictingApp: String?
        var isAssigned: Bool { hotkey.map { !$0.key.isEmpty } ?? false }
        var id: RowID { .app(bundleId) }
    }

    private var combinedApps: [AppItem] {
        var items: [AppItem] = []
        let allHotkeys = hotkeys

        for hotkey in hotkeys {
            let name = ApplicationManager.shared.getAppName(bundleId: hotkey.bundleId)
            let conflicting = allHotkeys.first { other in
                other.bundleId != hotkey.bundleId &&
                !other.key.isEmpty &&
                other.key == hotkey.key &&
                other.modifiers.sorted() == hotkey.modifiers.sorted()
            }
            let conflictName = conflicting.map { ApplicationManager.shared.getAppName(bundleId: $0.bundleId) }
            items.append(AppItem(bundleId: hotkey.bundleId, name: name, hotkey: hotkey, runningApp: nil, conflictingApp: conflictName))
        }
        for app in runningApps {
            if let bundleId = app.bundleIdentifier {
                let name = app.localizedName ?? "Unknown"
                items.append(AppItem(bundleId: bundleId, name: name, hotkey: nil, runningApp: app, conflictingApp: nil))
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredApps: [AppItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return combinedApps.filter { item in
            switch filter {
            case .all: break
            case .assigned: guard item.isAssigned else { return false }
            case .unassigned: guard !item.isAssigned else { return false }
            }
            return query.isEmpty || matchesSearch(item, query: query)
        }
    }

    private var filteredExceptions: [String] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return exceptions }
        return exceptions.filter {
            ApplicationManager.shared.getAppName(bundleId: $0).localizedCaseInsensitiveContains(query)
        }
    }

    /// Exceptions aren't hotkeys, so they only show under the "All" filter
    private var visibleExceptions: [String] {
        filter == .all ? filteredExceptions : []
    }

    private var hasAssignedHotkeys: Bool {
        hotkeys.contains { !$0.key.isEmpty }
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
            if !axTrusted {
                accessibilityBanner
                Divider()
            }
            headerBar
            Divider()
            if !hasAssignedHotkeys {
                firstRunHint
                Divider()
            }
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
        .onReceive(timer) { _ in
            updateRunningApps()
            axTrusted = AXIsProcessTrusted()
        }
        .onChange(of: tempKey, perform: handleTempKeyChange)
        .onChange(of: filter) { _ in handleFilterChange() }
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text("Accessibility access is needed to switch and cycle windows reliably.")
                .font(.callout)
            Spacer()
            Button("Open System Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            searchField
            Spacer()
            Picker("Filter", selection: $filter) {
                ForEach(AppFilter.allCases, id: \.self) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Filter applications")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var firstRunHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text("No hotkeys yet. Select an app and press Return, or hover a row and click Record Shortcut.")
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
            Button("Suggest Hotkeys") { suggestHotkeys() }
                .help("Assign ⌃⌥ + a letter of the app's name to each running app")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
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
        .frame(minWidth: 140, maxWidth: 220)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(5)
    }

    private var emptyListMessage: String {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return "No apps match “\(searchText)”"
        }
        switch filter {
        case .assigned: return "No hotkeys assigned yet"
        case .unassigned: return "Every running app has a hotkey"
        case .all: return "No applications"
        }
    }

    private var sectionApplications: some View {
        Section(header: Text("Applications").font(.callout).foregroundColor(.secondary)) {
            if filteredApps.isEmpty {
                Text(emptyListMessage)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(filteredApps) { item in
                AppRow(
                    item: item,
                    isSelected: selectedRow == item.id,
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
            if !visibleExceptions.isEmpty {
                Section(header: Text("Exceptions")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .help("Hotkeys are disabled while one of these apps is focused")
                ) {
                    ForEach(visibleExceptions.map { RowID.exception($0) }, id: \.self) { row in
                        ExceptionRow(
                            bundleId: row.bundleId,
                            isSelected: selectedRow == row,
                            onDelete: deleteException
                        )
                    }
                }
            }
        }
    }

    private var footerView: some View {
        HStack {
            Menu {
                Button("Add App…", action: prepareForAdd)
                Button("Add Exception…", action: addException)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .fixedSize()
            .help("Add App (⌘N) or Exception (⇧⌘N)")

            Spacer()

            // Hidden buttons for keyboard shortcuts
            Group {
                Button("") { prepareForAdd() }.keyboardShortcut("n", modifiers: .command)
                Button("") { addException() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("") { closeWindow() }.keyboardShortcut("w", modifiers: .command)
                Button("") { handleEscape() }.keyboardShortcut(.cancelAction)
                Button("") { handleReturn() }.keyboardShortcut(.return, modifiers: [])
                Button("") { focusTarget = .search }.keyboardShortcut("f", modifiers: .command)
                Button("") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }
            .opacity(0).frame(width: 0, height: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var allRowIDs: [RowID] {
        filteredApps.map { RowID.app($0.bundleId) } + visibleExceptions.map { RowID.exception($0) }
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

    private func handleFilterChange() {
        // The recording row may have been filtered out from under the
        // recorder; cancel so hotkeys don't stay suspended.
        if let recording = recordingBundleId, !filteredApps.contains(where: { $0.bundleId == recording }) {
            cancelRecording(for: recording)
        }
        if let row = selectedRow, allRowIDs.contains(row) { return }
        selectedRow = allRowIDs.first
    }

    private func cancelRecording(for bundleId: String) {
        recordingBundleId = nil
        tempKey = ""
        tempModifiers = []
        hotkeys.removeAll { $0.bundleId == bundleId && $0.key.isEmpty }
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
        if !filteredApps.contains(where: { $0.bundleId == bundleId }) {
            filter = .all
        }
        selectedRow = .app(bundleId)
        recordingBundleId = bundleId
        tempKey = ""
        tempModifiers = []
    }

    /// Offer conflict-free starter hotkeys: ⌃⌥ + a letter of each running
    /// app's name. ⌃⌥ so suggestions can't shadow common app shortcuts or
    /// ⌥-typed special characters.
    private func suggestHotkeys() {
        var used = Set(hotkeys.filter { !$0.key.isEmpty }.map { comboKey(modifiers: $0.modifiers, key: $0.key) })
        let suggestionMods = ["ctrl", "opt"]

        for app in runningApps {
            guard let bundleId = app.bundleIdentifier else { continue }
            guard !hotkeys.contains(where: { $0.bundleId == bundleId && !$0.key.isEmpty }) else { continue }
            let name = app.localizedName ?? ""
            let candidates = name.lowercased().map(String.init).filter { Hotkey.supportedKeys.contains($0) }
            guard let key = candidates.first(where: { !used.contains(comboKey(modifiers: suggestionMods, key: $0)) }) else { continue }
            used.insert(comboKey(modifiers: suggestionMods, key: key))

            let suggestion = Hotkey(key: key, modifiers: suggestionMods, bundleId: bundleId)
            if let index = hotkeys.firstIndex(where: { $0.bundleId == bundleId }) {
                hotkeys[index] = suggestion
            } else {
                hotkeys.append(suggestion)
            }
        }
        saveToConfig()
    }

    private func comboKey(modifiers: [String], key: String) -> String {
        (modifiers.map { $0.lowercased() }.sorted() + [key.lowercased()]).joined(separator: "+")
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
                // Make sure the new row is visible and selected
                searchText = ""
                filter = .all
                selectedRow = .exception(bundleId)
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
    let isSelected: Bool
    @Binding var recordingBundleId: String?
    @Binding var tempKey: String
    @Binding var tempModifiers: [String]
    @Binding var hotkeys: [Hotkey]
    let onDelete: (Hotkey) -> Void
    let onStartRecording: (String) -> Void
    let onSave: () -> Void
    @State private var isHovering = false

    /// Row controls (delete, record) only show on hover or selection to keep
    /// the long list quiet; keyboard users get ⌫ and Return instead.
    private var showsControls: Bool { isHovering || isSelected }

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
                if let conflictingApp = item.conflictingApp {
                    Label("Conflicts with \(conflictingApp)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
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
                    Text("Type shortcut…")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(4)
                        .allowsHitTesting(false)
                )
                .help("Esc cancels · Delete removes the hotkey")
            } else if let hotkey = item.hotkey, !hotkey.key.isEmpty {
                Button(action: {
                    onStartRecording(item.bundleId)
                }) {
                    Text(hotkey.displayString)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(item.conflictingApp == nil ? Color.secondary.opacity(0.1) : Color.orange.opacity(0.2))
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
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)
            } else {
                Button(action: {
                    onStartRecording(item.bundleId)
                }) {
                    Text("Record Shortcut")
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(4)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Record shortcut for \(item.name)")
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(recordingBundleId == item.bundleId ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

private struct ExceptionRow: View {
    let bundleId: String
    let isSelected: Bool
    let onDelete: (String) -> Void
    @State private var isHovering = false

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
            .opacity(isHovering || isSelected ? 1 : 0)
            .allowsHitTesting(isHovering || isSelected)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
