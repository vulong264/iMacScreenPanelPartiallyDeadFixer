import Cocoa
import ApplicationServices

// ---------------------------------------------------------------------------
// WindowConstrainer
// Uses the macOS Accessibility API to monitor all windows and prevent them
// from extending into the dead-zone strip at the bottom of the screen.
//
// When a window's bottom edge extends into the dead zone, we either:
//   1. Exit full-screen first (if the window is in native full-screen)
//   2. Shrink its height (if the window originated above the dead zone)
//   3. Move it up (if the window is positioned entirely in the dead zone)
// ---------------------------------------------------------------------------

class WindowConstrainer {
    static let shared = WindowConstrainer()

    private var constrainTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// The inset height in points (from the bottom of the screen).
    var deadZoneHeight: CGFloat = 232.0

    /// Whether the constrainer is actively monitoring and adjusting windows.
    private(set) var isActive = false

    /// Track windows we've already exited from full-screen to avoid loops.
    /// Key = window hash description, Value = timestamp.
    private var recentlyExitedFullScreen: [String: Date] = [:]

    // -----------------------------------------------------------------------
    // MARK: – Start / Stop

    func start(deadZone: CGFloat) {
        guard !isActive else { return }
        deadZoneHeight = deadZone

        // Prompt for Accessibility permission if not granted
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if !trusted {
            print("[WindowConstrainer] ⚠️ Accessibility permission not yet granted — will retry")
        }

        // Constrain all existing windows immediately
        constrainAllWindows()

        // Poll every 0.5s – catches new windows, resized windows, moved windows
        constrainTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.constrainAllWindows()
        }

        // Also constrain on app launch / activate / space change for faster response
        let ws = NSWorkspace.shared
        let nc = ws.notificationCenter

        let launchObs = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                       object: nil, queue: .main) { [weak self] note in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.constrainWindowsOf(pid: app.processIdentifier)
                }
            }
        }
        let activateObs = nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                          object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.constrainWindowsOf(pid: app.processIdentifier)
            }
        }
        // React to Space changes (full-screen creates a new Space)
        let spaceObs = nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.constrainAllWindows()
            }
        }
        workspaceObservers = [launchObs, activateObs, spaceObs]

        isActive = true
        print("[WindowConstrainer] Started — dead zone: \(deadZone) pt")
    }

    func stop() {
        constrainTimer?.invalidate()
        constrainTimer = nil
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        recentlyExitedFullScreen.removeAll()
        isActive = false
        print("[WindowConstrainer] Stopped")
    }

    func updateDeadZone(_ height: CGFloat) {
        deadZoneHeight = height
        if isActive {
            constrainAllWindows()
        }
    }

    // -----------------------------------------------------------------------
    // MARK: – Core logic

    /// Iterate every visible, standard window on the main screen and constrain it.
    private func constrainAllWindows() {
        guard AXIsProcessTrusted() else { return }

        // Clean up old entries from recentlyExitedFullScreen (older than 5s)
        let cutoff = Date().addingTimeInterval(-5)
        recentlyExitedFullScreen = recentlyExitedFullScreen.filter { $0.value > cutoff }

        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            guard app.activationPolicy == .regular else { continue }
            constrainWindowsOf(pid: app.processIdentifier)
        }
    }

    /// Constrain all windows belonging to a single app.
    private func constrainWindowsOf(pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        guard let screen = NSScreen.main else { return }

        let appRef = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue)
        guard result == .success, let windows = windowsValue as? [AXUIElement] else { return }

        let screenFrame = screen.frame
        // AX uses flipped coordinates (origin = top-left of primary screen).
        // deadZoneTop in AX coords = screen height minus dead zone height
        let deadZoneTop = screenFrame.height - deadZoneHeight

        for window in windows {
            constrainSingleWindow(window, deadZoneTop: deadZoneTop, screenFrame: screenFrame)
        }
    }

    /// Check one window and constrain it if needed.
    private func constrainSingleWindow(_ window: AXUIElement,
                                        deadZoneTop: CGFloat,
                                        screenFrame: CGRect) {

        // --- Check if window is in native full-screen ---
        let windowKey = "\(window)"
        if isFullScreen(window) {
            // Only exit full-screen if we haven't recently done so (prevent loops)
            if recentlyExitedFullScreen[windowKey] == nil {
                print("[WindowConstrainer] Exiting full-screen for window")
                exitFullScreen(window)
                recentlyExitedFullScreen[windowKey] = Date()

                // After exiting full-screen, the window needs time to animate out.
                // We'll catch it on the next timer tick and resize it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.zoomWindowToUsableArea(window, deadZoneTop: deadZoneTop, screenFrame: screenFrame)
                }
            }
            return
        }

        // --- Read current position & size ---
        var posValue:  CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return }

        var pos  = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue  as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue as! AXValue, .cgSize,  &size)
        else { return }

        // Skip tiny windows (toolbars, popovers, etc.)
        guard size.width > 50 && size.height > 50 else { return }

        let windowBottom = pos.y + size.height  // AX flipped coords

        // If the window bottom doesn't reach the dead zone, nothing to do.
        guard windowBottom > deadZoneTop else { return }

        // --- Constrain ---
        if pos.y < deadZoneTop {
            // Window starts above dead zone but extends into it → shrink height
            let newHeight = deadZoneTop - pos.y
            guard newHeight >= 100 else { return }
            var newSize = CGSize(width: size.width, height: newHeight)
            if let val = AXValueCreate(.cgSize, &newSize) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, val)
            }
        } else {
            // Window is entirely in the dead zone → move it up
            let moveUp = windowBottom - deadZoneTop
            var newPos = CGPoint(x: pos.x, y: pos.y - moveUp)
            if newPos.y < 0 { newPos.y = 0 }
            if let val = AXValueCreate(.cgPoint, &newPos) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, val)
            }
            // Also shrink if still too tall
            let adjustedBottom = newPos.y + size.height
            if adjustedBottom > deadZoneTop {
                let newHeight = deadZoneTop - newPos.y
                guard newHeight >= 100 else { return }
                var newSize = CGSize(width: size.width, height: newHeight)
                if let val = AXValueCreate(.cgSize, &newSize) {
                    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, val)
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: – Full-screen helpers

    /// Check if window is in native macOS full-screen mode.
    private func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value)
        if result == .success, let boolVal = value as? Bool {
            return boolVal
        }
        return false
    }

    /// Exit native macOS full-screen mode.
    private func exitFullScreen(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
    }

    /// After exiting full-screen, zoom the window to fill the usable area
    /// (full screen minus menu bar and dead zone).
    private func zoomWindowToUsableArea(_ window: AXUIElement,
                                         deadZoneTop: CGFloat,
                                         screenFrame: CGRect) {
        // In AX flipped coords:
        //   top of usable area = menu bar height (typically ~25–38 pt)
        //   bottom of usable area = deadZoneTop
        // We use NSScreen.visibleFrame to get the menu bar offset.
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame

        // Convert visibleFrame to AX flipped coords
        let menuBarHeight = screenFrame.height - (visibleFrame.minY + visibleFrame.height)
        let topY = max(menuBarHeight, 0)
        let usableHeight = deadZoneTop - topY

        guard usableHeight > 100 else { return }

        var newPos = CGPoint(x: screenFrame.minX, y: topY)
        var newSize = CGSize(width: screenFrame.width, height: usableHeight)

        if let posVal = AXValueCreate(.cgPoint, &newPos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        }
    }
}
