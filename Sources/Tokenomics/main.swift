import AppKit

// Diagnostic flags (used to verify the readers against ccusage and to profile
// memory) each run and exit before any GUI setup.
if CommandLine.arguments.contains("--dump-daily") {
    DumpDaily.run(provider: ClaudeNativeProvider())
    exit(0)
}
if CommandLine.arguments.contains("--dump-codex") {
    DumpDaily.run(provider: CodexProvider())
    exit(0)
}
if CommandLine.arguments.contains("--dump-intraday") {
    DumpIntraday.run()
    exit(0)
}
if CommandLine.arguments.contains("--dump-curve") {
    DumpCurve.run()
    exit(0)
}
if CommandLine.arguments.contains("--scan-only") {
    ScanOnly.run()
    exit(0)
}
if CommandLine.arguments.contains("--bench") {
    Bench.run()
    exit(0)
}

// Menu bar agent: no Dock icon, no main window (.accessory activation policy).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
