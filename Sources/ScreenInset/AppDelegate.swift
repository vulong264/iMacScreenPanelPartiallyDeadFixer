import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Menu-bar only app – hide from Dock
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "⬛ Inset"
        }
        constructMenu()
    }

    func constructMenu() {
        let menu = NSMenu()

        // -- Toggle --
        let isEnabled   = DisplayEngine.shared.isInsetEnabled
        let toggleTitle = isEnabled ? "Disable Inset" : "Enable Inset"
        let toggleItem  = NSMenuItem(title: toggleTitle, action: #selector(toggleInset(_:)), keyEquivalent: "e")
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // -- Inset size label --
        let pts  = Int(DisplayEngine.shared.targetInsetPoints)
        let info = NSMenuItem(title: "Dead zone: \(pts) pt", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)

        // -- Slider (embedded as a custom view) --
        let sliderView    = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        let slider        = NSSlider(value: Double(DisplayEngine.shared.targetInsetPoints),
                                     minValue: 50, maxValue: 500,
                                     target: self,
                                     action: #selector(sliderChanged(_:)))
        slider.frame      = NSRect(x: 18, y: 5, width: 184, height: 20)
        slider.isContinuous = false
        sliderView.addSubview(slider)
        let sliderItem    = NSMenuItem()
        sliderItem.view   = sliderView
        menu.addItem(sliderItem)

        menu.addItem(.separator())

        // -- Quit --
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // -----------------------------------------------------------------------
    @objc func toggleInset(_ sender: NSMenuItem) {
        let wasEnabled = DisplayEngine.shared.isInsetEnabled
        let success    = DisplayEngine.shared.applyInset(enabled: !wasEnabled)

        if success {
            // Rebuild to keep label in sync
            constructMenu()
            if let button = statusItem.button {
                button.title = !wasEnabled ? "⬛ ON" : "⬛ Inset"
            }
        } else {
            showError("Failed to apply inset.\nCheck Console for details.")
        }
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        DisplayEngine.shared.targetInsetPoints = CGFloat(sender.doubleValue)
        // If already enabled, re-apply immediately
        if DisplayEngine.shared.isInsetEnabled {
            DisplayEngine.shared.applyInset(enabled: false)
            DisplayEngine.shared.applyInset(enabled: true)
        }
        constructMenu()
    }

    // -----------------------------------------------------------------------
    private func showError(_ message: String) {
        let alert           = NSAlert()
        alert.messageText   = "ScreenInset Error"
        alert.informativeText = message
        alert.alertStyle    = .warning
        alert.runModal()
    }
}
