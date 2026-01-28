import Cocoa
import SwiftUI

/// Main application delegate - sets up menu bar and coordinates components
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var hotkeys: [Hotkey] = []
    private var settingsWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up the menu bar item
        setupStatusBar()
        
        // Load configuration
        hotkeys = ConfigManager.shared.loadHotkeys()
        
        // Start the hotkey manager
        HotkeyManager.shared.start(hotkeys: hotkeys) { [weak self] hotkey in
            self?.handleHotkey(hotkey)
        }
        
        print("HotkeyLauncher started!")
        print("Config file: \(ConfigManager.shared.configPath)")
        print("Registered hotkeys:")
        for hotkey in hotkeys {
            let modStr = hotkey.modifiers.joined(separator: "+")
            print("  \(modStr)+\(hotkey.key) -> \(hotkey.bundleId)")
        }

        // Check for command line flags
        if CommandLine.arguments.contains("--settings") {
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
        
        menu.addItem(NSMenuItem(title: "HotkeyLauncher", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let reloadItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)
        
        let showConfigItem = NSMenuItem(title: "Show Config in Finder", action: #selector(showConfigInFinder), keyEquivalent: "")
        showConfigItem.target = self
        menu.addItem(showConfigItem)
        
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
            window.title = "HotkeyLauncher Settings"
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

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow {
            settingsWindow = nil
        }
    }
    
    /// Handle a hotkey press
    private func handleHotkey(_ hotkey: Hotkey) {
        ApplicationManager.shared.activateOrLaunch(bundleId: hotkey.bundleId)
    }
    
    /// Reload configuration from file
    @objc private func reloadConfig() {
        hotkeys = ConfigManager.shared.loadHotkeys()
        HotkeyManager.shared.updateHotkeys(hotkeys)
        print("Config reloaded")
    }
    
    /// Open Finder to show the config file
    @objc private func showConfigInFinder() {
        let configPath = ConfigManager.shared.configPath
        let configURL = URL(fileURLWithPath: configPath)
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }
    
    /// Quit the application
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
