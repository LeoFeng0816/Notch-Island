import AppKit

if CommandLine.arguments.contains("--capture-diagnostics") {
    exit(MainActor.assumeIsolated { CaptureDiagnostics.run(arguments: CommandLine.arguments) })
}

if CommandLine.arguments.contains("--self-test") {
    exit(MainActor.assumeIsolated { SelfTest.run() })
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
