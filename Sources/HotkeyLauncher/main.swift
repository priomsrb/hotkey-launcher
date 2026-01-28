import Cocoa

// Check if another instance is already running
let bundleIdentifier = "com.priomsrb.HotkeyLauncher"
let currentPID = ProcessInfo.processInfo.processIdentifier
let runningApps = NSWorkspace.shared.runningApplications
let otherInstances = runningApps.filter { 
    ($0.bundleIdentifier == bundleIdentifier || $0.localizedName == "HotkeyLauncher") && 
    $0.processIdentifier != currentPID 
}

if !otherInstances.isEmpty {
    // Tell the existing instance to show settings
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("com.priomsrb.HotkeyLauncher.ShowSettings"),
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
    exit(0)
}

// Create the application
let app = NSApplication.shared

// Create and retain the delegate
// We keep a strong reference here to prevent it from being deallocated
// since NSApplication.delegate is a weak property.
let delegate = AppDelegate()
app.delegate = delegate

// Run as a menu bar app (no dock icon)
app.setActivationPolicy(.accessory)

app.run()
