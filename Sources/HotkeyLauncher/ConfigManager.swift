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
    
    /// Load hotkeys from config file, creating default if not exists
    func loadHotkeys() -> [Hotkey] {
        guard let url = configFileURL else {
            print("Could not determine config file location")
            return defaultHotkeys()
        }
        
        // If config doesn't exist, create with defaults
        if !FileManager.default.fileExists(atPath: url.path) {
            let defaults = defaultHotkeys()
            saveHotkeys(defaults)
            print("Created default config at: \(url.path)")
            return defaults
        }
        
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(HotkeyConfig.self, from: data)
            print("Loaded \(config.hotkeys.count) hotkeys from: \(url.path)")
            return config.hotkeys
        } catch {
            print("Error loading config: \(error). Using defaults.")
            return defaultHotkeys()
        }
    }
    
    /// Save hotkeys to config file
    func saveHotkeys(_ hotkeys: [Hotkey]) {
        guard let url = configFileURL else { return }
        
        let config = HotkeyConfig(hotkeys: hotkeys)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        do {
            let data = try encoder.encode(config)
            try data.write(to: url)
        } catch {
            print("Error saving config: \(error)")
        }
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
