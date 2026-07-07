import Cocoa
import SwiftUI
import ServiceManagement

/// Main application delegate - sets up menu bar and coordinates components
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenuTitleItem: NSMenuItem?
    private var hotkeys: [Hotkey] = []
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up the menu bar item
        setupStatusBar()

        // Load configuration
        let config = ConfigManager.shared.loadConfig()
        hotkeys = config.hotkeys
        let hasAssignedHotkeys = hotkeys.contains { !$0.key.isEmpty }

        // Hotkeys themselves (Carbon) don't need Accessibility, but the AX
        // window discovery/cycling in ApplicationManager does. Only prompt at
        // launch on configured installs — on a fresh install the welcome pane
        // asks with context instead, so the first thing a new user sees isn't
        // a permission dialog for an app they know nothing about.
        if hasAssignedHotkeys {
            let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(axOptions) {
                print("Accessibility permission not granted — window cycling will be limited until approved")
            }
        }

        // Track window focus history so cycling can order windows by actual
        // most-recent use instead of guessing from z-order
        WindowFocusTracker.shared.start()

        // Start the hotkey manager
        HotkeyManager.shared.start(hotkeys: hotkeys, exceptions: config.exceptions) { [weak self] hotkey in
            self?.handleHotkey(hotkey)
        }

        print("HotkeyLauncher started!")
        print("Config file: \(ConfigManager.shared.configPath)")
        print("Registered hotkeys:")
        for hotkey in hotkeys {
            let modStr = hotkey.modifiers.joined(separator: "+")
            print("  \(modStr)+\(hotkey.key) -> \(hotkey.bundleId)")
        }

        // A menu-bar-only app with no hotkeys is invisible and useless, so an
        // unconfigured launch opens settings — that covers fresh installs and
        // installs that were never set up.
        if CommandLine.arguments.contains("--settings") || !hasAssignedHotkeys {
            showSettings()
        }

        // Register for distributed notification to show settings when another instance tries to launch
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showSettings),
            name: NSNotification.Name("com.priomsrb.HotkeyLauncher.ShowSettings"),
            object: nil
        )
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        showSettings()
    }

    /// Set up the menu bar status item
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            // Use a keyboard icon
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "HotkeyLauncher")
            button.image?.isTemplate = true
        }
        
        // Create the menu
        let menu = NSMenu()
        menu.delegate = self

        let titleItem = NSMenuItem(title: "HotkeyLauncher", action: nil, keyEquivalent: "")
        statusMenuTitleItem = titleItem
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        if #available(macOS 13.0, *) {
            let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
            loginItem.target = self
            menu.addItem(loginItem)
        }

        // Config plumbing is a dev/power-user concern; keep it out of the top level
        let advancedMenu = NSMenu()
        let reloadItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "")
        reloadItem.target = self
        advancedMenu.addItem(reloadItem)

        let showConfigItem = NSMenuItem(title: "Show Config in Finder", action: #selector(showConfigInFinder), keyEquivalent: "")
        showConfigItem.target = self
        advancedMenu.addItem(showConfigItem)

        let advancedItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advancedItem.submenu = advancedMenu
        menu.addItem(advancedItem)

        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    /// Show the settings window
    @objc private func showSettings() {
        if settingsWindow == nil {
            let contentView = SettingsView(onClose: { [weak self] in
                self?.settingsWindow?.close()
            })
            
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.center()
            window.title = "HotkeyLauncher"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: contentView)
            window.makeKeyAndOrderFront(nil)
            settingsWindow = window
            
            // Bring to front even if app is an agent
            NSApp.activate(ignoringOtherApps: true)
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - NSMenuDelegate

    /// Keep the inert title row informative: it doubles as a status line so
    /// the menu itself tells new users whether anything is set up yet.
    func menuWillOpen(_ menu: NSMenu) {
        let count = ConfigManager.shared.loadConfig().hotkeys.filter { !$0.key.isEmpty }.count
        statusMenuTitleItem?.title = count == 0
            ? "HotkeyLauncher — no hotkeys yet"
            : "HotkeyLauncher — \(count) hotkey\(count == 1 ? "" : "s") active"
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow {
            settingsWindow = nil
        }
    }
    
    /// Handle a hotkey press
    private func handleHotkey(_ hotkey: Hotkey) {
        ApplicationManager.shared.activateOrLaunch(bundleId: hotkey.bundleId,
                                                   modifiers: hotkey.cgEventFlags)
    }
    
    /// Reload configuration from file
    @objc private func reloadConfig() {
        let config = ConfigManager.shared.loadConfig()
        hotkeys = config.hotkeys
        HotkeyManager.shared.updateConfig(hotkeys: hotkeys, exceptions: config.exceptions)
        print("Config reloaded")
    }
    
    /// Open Finder to show the config file
    @objc private func showConfigInFinder() {
        let configPath = ConfigManager.shared.configPath
        let configURL = URL(fileURLWithPath: configPath)
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }
    
    /// Toggle launching the app automatically at login (macOS 13+)
    @objc private func toggleStartAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Start at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleStartAtLogin), #available(macOS 13.0, *) {
            menuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        return true
    }

    /// Quit the application
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
