import Cocoa
import ApplicationServices

// ---------------------------------------------------------------------------
// WindowConstrainer
// Uses the macOS Accessibility API to monitor all windows and prevent them
// from extending into the dead-zone strip at the bottom of the screen.
// ---------------------------------------------------------------------------

class WindowConstrainer {
    static let shared = WindowConstrainer()

    private var constrainTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?

    /// The inset height in points (from the bottom of the screen).
    var deadZoneHeight: CGFloat = 232.0

    /// Whether the constrainer is actively monitoring and adjusting windows.
    private(set) var isActive = false

    /// Track windows we've already exited from full-screen to avoid loops.
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

        // Poll frequently – catches any window that sneaks past event-based monitoring
        constrainTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.constrainAllWindows()
        }

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
                // Constrain after a tiny delay (window may still be animating)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.constrainWindowsOf(pid: app.processIdentifier)
                }
            }
        }
        let spaceObs = nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            // Space change = might be entering/exiting full-screen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.constrainAllWindows()
            }
        }
        workspaceObservers = [launchObs, activateObs, spaceObs]

        // Monitor global mouse-up events — catches zoom/maximize button clicks
        // and manual window drag-resizes.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            // Small delay to let the window finish its resize animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.constrainAllWindows()
            }
        }

        isActive = true
        print("[WindowConstrainer] Started — dead zone: \(deadZone) pt")
    }

    func stop() {
        constrainTimer?.invalidate()
        constrainTimer = nil
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
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

    private func constrainAllWindows() {
        guard AXIsProcessTrusted() else { return }

        // Clean up debounce entries older than 5s
        let cutoff = Date().addingTimeInterval(-5)
        recentlyExitedFullScreen = recentlyExitedFullScreen.filter { $0.value > cutoff }

        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            guard app.activationPolicy == .regular else { continue }
            constrainWindowsOf(pid: app.processIdentifier)
        }
    }

    private func constrainWindowsOf(pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        guard let screen = NSScreen.main else { return }

        let appRef = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue)
        guard result == .success, let windows = windowsValue as? [AXUIElement] else { return }

        let screenFrame = screen.frame
        let deadZoneTop = screenFrame.height - deadZoneHeight

        for window in windows {
            constrainSingleWindow(window, deadZoneTop: deadZoneTop, screenFrame: screenFrame)
        }
    }

    private func constrainSingleWindow(_ window: AXUIElement,
                                        deadZoneTop: CGFloat,
                                        screenFrame: CGRect) {
        let windowKey = "\(window)"

        // --- Handle native full-screen ---
        if isFullScreen(window) {
            if recentlyExitedFullScreen[windowKey] == nil {
                print("[WindowConstrainer] Exiting full-screen for window")
                exitFullScreen(window)
                recentlyExitedFullScreen[windowKey] = Date()
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
        // First: if the window looks "zoomed" (spans close to the full screen height),
        // resize it to fill just the usable area.
        let isMaximized = (size.height >= screenFrame.height - 60)
        if isMaximized {
            zoomWindowToUsableArea(window, deadZoneTop: deadZoneTop, screenFrame: screenFrame)
            return
        }

        // Otherwise: just shrink or move the window out of the dead zone.
        if pos.y < deadZoneTop {
            let newHeight = deadZoneTop - pos.y
            guard newHeight >= 100 else { return }
            setWindowSize(window, size: CGSize(width: size.width, height: newHeight))
        } else {
            // Window is entirely in the dead zone → move it up
            let moveUp = windowBottom - deadZoneTop
            var newY = pos.y - moveUp
            if newY < 0 { newY = 0 }
            setWindowPosition(window, position: CGPoint(x: pos.x, y: newY))
            // Also shrink if still too tall
            let adjustedBottom = newY + size.height
            if adjustedBottom > deadZoneTop {
                let newHeight = deadZoneTop - newY
                guard newHeight >= 100 else { return }
                setWindowSize(window, size: CGSize(width: size.width, height: newHeight))
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: – Full-screen helpers

    private func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value)
        if result == .success, let boolVal = value as? Bool {
            return boolVal
        }
        return false
    }

    private func exitFullScreen(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
    }

    /// Position and size the window to fill the usable screen area
    /// (between menu bar and dead zone).
    private func zoomWindowToUsableArea(_ window: AXUIElement,
                                         deadZoneTop: CGFloat,
                                         screenFrame: CGRect) {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame

        // Convert to AX flipped coords
        let menuBarHeight = screenFrame.height - (visibleFrame.minY + visibleFrame.height)
        let topY = max(menuBarHeight, 0)
        let usableHeight = deadZoneTop - topY

        guard usableHeight > 100 else { return }

        // Set position FIRST, then size — some apps compute layout from position
        setWindowPosition(window, position: CGPoint(x: screenFrame.minX, y: topY))
        setWindowSize(window, size: CGSize(width: screenFrame.width, height: usableHeight))

        // Some apps fight back (e.g. Chrome). Re-apply after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard self?.isActive == true else { return }
            self?.setWindowPosition(window, position: CGPoint(x: screenFrame.minX, y: topY))
            self?.setWindowSize(window, size: CGSize(width: screenFrame.width, height: usableHeight))
        }
    }

    // -----------------------------------------------------------------------
    // MARK: – AX convenience methods

    private func setWindowPosition(_ window: AXUIElement, position: CGPoint) {
        var pos = position
        if let val = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, val)
        }
    }

    private func setWindowSize(_ window: AXUIElement, size: CGSize) {
        var sz = size
        if let val = AXValueCreate(.cgSize, &sz) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, val)
        }
    }
}
