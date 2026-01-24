import Cocoa

/// Main application delegate - sets up menu bar and coordinates components
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotkeys: [Hotkey] = []
    
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
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.stop()
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
