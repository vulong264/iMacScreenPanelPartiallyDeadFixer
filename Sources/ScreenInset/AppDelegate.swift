import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.title = "ScreenInset"
        }
        
        constructMenu()
    }
    
    func constructMenu() {
        let menu = NSMenu()
        
        let toggleTitle = DisplayEngine.shared.isInsetEnabled ? "Disable Inset" : "Enable Inset"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleInset(_:)), keyEquivalent: "")
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ScreenInset", action: #selector(NSApplication.shared.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    @objc func toggleInset(_ sender: NSMenuItem) {
        let isEnabled = DisplayEngine.shared.isInsetEnabled
        let success = DisplayEngine.shared.applyInset(enabled: !isEnabled)
        
        if success {
            sender.title = !isEnabled ? "Disable Inset" : "Enable Inset"
        } else {
            print("Failed to apply inset.")
        }
    }
}
