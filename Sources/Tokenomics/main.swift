import AppKit

// Diagnostic mode: dump the native reader's daily token totals and exit, for
// verifying it against ccusage. Runs before any GUI setup.
if CommandLine.arguments.contains("--dump-daily") {
    DumpDaily.run()
    exit(0)
}

// Menu bar agent: no Dock icon, no main window (.accessory activation policy).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
