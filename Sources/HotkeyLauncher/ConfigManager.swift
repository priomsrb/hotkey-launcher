import Foundation

/// Manages loading and saving hotkey configurations
class ConfigManager {
    static let shared = ConfigManager()
    
    private let configFileName = "config.json"
    private var configFileURL: URL?
    
    private init() {
        configFileURL = getConfigFileURL()
    }
    
    /// Get the config file URL, creating directory if needed
    private func getConfigFileURL() -> URL? {
        // First try Application Support directory
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appDir = appSupport.appendingPathComponent("HotkeyLauncher")
            
            // Create directory if it doesn't exist
            if !FileManager.default.fileExists(atPath: appDir.path) {
                try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            }
            
            return appDir.appendingPathComponent(configFileName)
        }
        
        // Fallback to current directory
        return URL(fileURLWithPath: configFileName)
    }
    
    /// Load configuration from config file, creating default if not exists
    func loadConfig() -> HotkeyConfig {
        guard let url = configFileURL else {
            print("Could not determine config file location")
            return HotkeyConfig(hotkeys: defaultHotkeys(), exceptions: [])
        }
        
        // If config doesn't exist, create with defaults
        if !FileManager.default.fileExists(atPath: url.path) {
            let defaultConfig = HotkeyConfig(hotkeys: defaultHotkeys(), exceptions: [])
            saveConfig(defaultConfig)
            print("Created default config at: \(url.path)")
            return defaultConfig
        }
        
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(HotkeyConfig.self, from: data)
            print("Loaded configuration with \(config.hotkeys.count) hotkeys and \(config.exceptions.count) exceptions from: \(url.path)")
            return config
        } catch {
            print("Error loading config: \(error). Using defaults.")
            return HotkeyConfig(hotkeys: defaultHotkeys(), exceptions: [])
        }
    }
    
    /// Load hotkeys from config file
    func loadHotkeys() -> [Hotkey] {
        return loadConfig().hotkeys
    }
    
    /// Load exceptions from config file
    func loadExceptions() -> [String] {
        return loadConfig().exceptions
    }
    
    /// Save configuration to config file
    func saveConfig(_ config: HotkeyConfig) {
        guard let url = configFileURL else { return }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        do {
            let data = try encoder.encode(config)
            try data.write(to: url)
        } catch {
            print("Error saving config: \(error)")
        }
    }
    
    /// Save hotkeys to config file
    func saveHotkeys(_ hotkeys: [Hotkey]) {
        let exceptions = loadExceptions()
        saveConfig(HotkeyConfig(hotkeys: hotkeys, exceptions: exceptions))
    }
    
    /// Save exceptions to config file
    func saveExceptions(_ exceptions: [String]) {
        let hotkeys = loadHotkeys()
        saveConfig(HotkeyConfig(hotkeys: hotkeys, exceptions: exceptions))
    }
    
    /// Default hotkey configuration
    private func defaultHotkeys() -> [Hotkey] {
        return [
            Hotkey(key: "t", modifiers: ["cmd"], bundleId: "com.apple.Terminal"),
            Hotkey(key: "s", modifiers: ["cmd"], bundleId: "com.apple.Safari"),
            Hotkey(key: "f", modifiers: ["cmd"], bundleId: "com.apple.finder")
        ]
    }
    
    /// Get the path to the config file for display
    var configPath: String {
        return configFileURL?.path ?? "Unknown"
    }
}
