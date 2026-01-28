import Cocoa

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
