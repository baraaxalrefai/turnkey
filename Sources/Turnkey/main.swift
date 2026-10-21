import AppKit

// Turnkey — turn your head, your keys follow. Private and fully offline.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
