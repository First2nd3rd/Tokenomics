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
if CommandLine.arguments.contains("--dump-workbuddy") {
    DumpDaily.run(provider: WorkBuddyProvider())
    exit(0)
}
if CommandLine.arguments.contains("--dump-peers") {
    DumpPeers.run()
    exit(0)
}
if CommandLine.arguments.contains("--dump-archive") {
    DumpArchive.run()
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
if CommandLine.arguments.contains("--bench-report") {
    BenchReport.run()
    exit(0)
}
if CommandLine.arguments.contains("--verify-report") {
    VerifyReport.run()   // exits itself with the check status
}
if let flagIndex = CommandLine.arguments.firstIndex(of: "--refreeze") {
    let days = CommandLine.arguments.dropFirst(flagIndex + 1).filter {
        $0.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
    }
    let force = CommandLine.arguments.contains("--force")
    Refreeze.run(days: Array(days), force: force)   // exits itself with the repair status
}

// Menu bar agent: no Dock icon, no main window (.accessory activation policy).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
