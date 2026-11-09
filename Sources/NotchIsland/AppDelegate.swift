import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: IslandController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = IslandController()
        controller.start()
        if OnboardingState.shouldShow() && !ProcessInfo.processInfo.arguments.contains("--stay-expanded") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated { self?.controller.showOnboarding() }
            }
        }

        // Small menu-bar entry for language and quitting (the app has no Dock icon).
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch Island")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Launch arguments for previews/screenshots: `open NotchIsland.app --args --demo-timer --expanded`
        // (also --demo-stopwatch, --widgets, --settings, --stay-expanded)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo-timer") { controller.timer.start(minutes: 5) }
        if args.contains("--demo-stopwatch") && !controller.stopwatch.isActive { controller.stopwatch.start() }
        if args.contains("--widgets") {
            // Preview: open the widget page even when activities are running.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                MainActor.assumeIsolated { self?.controller.model.page = .widgets }
            }
        }
        if args.contains("--settings") { controller.openSettings() }
        if args.contains("--preview-demo-key"), Bundle.main.bundleIdentifier != "local.notchisland.app" {
            // Screenshot aid for isolated preview copies only (never the shipping bundle ID):
            // Alpha Vantage's publicly documented demo key, which only returns IBM.
            controller.widgetSettings.setStockAPIKey("demo")
        }
        controller.pinExpanded = args.contains("--stay-expanded")
        if args.contains("--expanded") || controller.pinExpanded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.controller.setExpanded(true) }
            }
        }
    }

    // Rebuilt on every open so titles follow the current language and state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let lang = controller.lang
        menu.removeAllItems()

        let geometry = controller.model.geometry
        let notchText = geometry.hasNotch
            ? lang.t(.notchDetected) + " · " + lang.t(.notchSize, String(format: "%.0f", geometry.notchSize.width),
                                                       String(format: "%.0f", geometry.notchSize.height))
            : lang.t(.virtualNotch)
        let info = NSMenuItem(title: "\(notchText) — \(controller.device.modelIdentifier)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        let hint = NSMenuItem(title: lang.t(.hoverHint), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(item(controller.isExpanded ? lang.t(.collapseIsland) : lang.t(.expandIsland), #selector(toggleIsland)))
        if controller.timer.isActive {
            menu.addItem(item(lang.t(.stopTimer), #selector(stopTimer)))
        } else {
            menu.addItem(item(lang.t(.quickTimer), #selector(quickTimer)))
        }
        if controller.stopwatch.isActive {
            menu.addItem(item(lang.t(.stopStopwatch), #selector(resetStopwatch)))
        } else {
            menu.addItem(item(lang.t(.startStopwatch), #selector(startStopwatch)))
        }
        menu.addItem(.separator())
        let settingsItem = item(lang.t(.settingsMenu), #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(item(lang.t(.onboardingMenu), #selector(showOnboarding)))

        // Language is chosen only in Settings (General › Language).
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: lang.t(.quit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleIsland() { controller.setExpanded(!controller.isExpanded) }
    @objc private func quickTimer() { controller.timer.start(minutes: 5) }
    @objc private func stopTimer() { controller.timer.reset() }
    @objc private func startStopwatch() { controller.stopwatch.start() }
    @objc private func resetStopwatch() { controller.stopwatch.reset() }
    @objc private func openSettings() { controller.openSettings() }
    @objc private func showOnboarding() { controller.showOnboarding() }
}
