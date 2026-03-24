import Cocoa
import CoreGraphics
import Darwin

// ---------------------------------------------------------------------------
// SkyLight private API – confirmed present on macOS 26 via dyld_info
//
// ARM64 ABI NOTE: CGRect is a Homogeneous Floating-point Aggregate (4 × CGFloat).
// It is passed BY VALUE in SIMD registers (d0–d3), not as a pointer.
// Using UnsafeMutablePointer<CGRect> here would corrupt the call stack → segfault.
// ---------------------------------------------------------------------------
private typealias CGSMainConnectionIDFunc = @convention(c) () -> Int32

/// SLSSetDockRectWithOrientation(cid, rect, orientation)
/// Registers a screen-edge reservation with WindowServer.
/// WindowServer uses this to compute NSScreen.visibleFrame for all apps.
/// CGRect is passed BY VALUE on arm64 (HFA rule). Return is void.
private typealias SLSSetDockRectByValueFunc = @convention(c) (Int32, CGRect, Int32) -> Void

// Orientation constants (matches Dock internals)
private let kDockOrientationBottom: Int32 = 0
private let kDockOrientationLeft:   Int32 = 1
private let kDockOrientationRight:  Int32 = 2

// ---------------------------------------------------------------------------
class DisplayEngine {
    static let shared = DisplayEngine()

    /// Points to cover at the bottom of the screen (the dead LCD panel strip).
    var targetInsetPoints: CGFloat = 232.0

    private(set) var isInsetEnabled = false

    // MARK: – Private state
    private var overlayWindow:   NSWindow?
    private var skyLightHandle:  UnsafeMutableRawPointer?
    private var cid:             Int32 = 0
    private var savedBottomRect: CGRect = .zero
    private var reapplyTimer:    Timer?

    // Raw dlsym pointer – cast inline at call site
    private var ptrSetDock: UnsafeMutableRawPointer?

    // -----------------------------------------------------------------------
    init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        skyLightHandle = dlopen(path, RTLD_NOW)
        guard let handle = skyLightHandle else {
            print("[DisplayEngine] ❌ Could not load SkyLight")
            return
        }

        if let sym = dlsym(handle, "CGSMainConnectionID") {
            cid = unsafeBitCast(sym, to: CGSMainConnectionIDFunc.self)()
            print("[DisplayEngine] cid = \(cid)")
        }

        ptrSetDock = dlsym(handle, "SLSSetDockRectWithOrientation")
        print("[DisplayEngine] SLSSetDockRectWithOrientation: \(ptrSetDock != nil ? "✓" : "✗ (overlay-only mode)")")
    }

    // -----------------------------------------------------------------------
    // MARK: – Public API

    @discardableResult
    func applyInset(enabled: Bool) -> Bool {
        return enabled ? enableInset() : { disableInset(); return true }()
    }

    // -----------------------------------------------------------------------
    // MARK: – Enable

    private func enableInset() -> Bool {
        guard let screen = NSScreen.main else {
            print("[DisplayEngine] No main screen")
            return false
        }

        // Derive the current bottom reservation from NSScreen – no SkyLight read needed.
        // visibleFrame.minY > frame.minY only when the Dock is at the bottom.
        let screenFrame   = screen.frame
        let visibleFrame  = screen.visibleFrame
        let currentBottom = max(visibleFrame.minY - screenFrame.minY, 0)
        savedBottomRect   = CGRect(x: screenFrame.minX, y: screenFrame.minY,
                                   width: screenFrame.width, height: currentBottom)
        print("[DisplayEngine] Saved bottom reservation: \(savedBottomRect)")

        // Build the enlarged reservation that includes the dead-zone strip.
        let newRect = CGRect(
            x:      screenFrame.minX,
            y:      screenFrame.minY,
            width:  screenFrame.width,
            height: targetInsetPoints
        )

        // Tell WindowServer to reserve the strip (shrinks NSScreen.visibleFrame).
        setDockRect(newRect, orientation: kDockOrientationBottom)
        print("[DisplayEngine] Bottom reservation set to \(newRect)")

        // Black overlay window covers the dead strip visually.
        let win = makeOverlayWindow(frame: newRect)
        win.orderFrontRegardless()
        overlayWindow = win

        // Ask running apps to reflow against the shrunken visibleFrame.
        postScreenParamsChanged()

        // Re-assert every second – the Dock process will periodically overwrite us.
        reapplyTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reapplyIfNeeded()
        }

        isInsetEnabled = true
        return true
    }

    // -----------------------------------------------------------------------
    // MARK: – Disable

    private func disableInset() {
        reapplyTimer?.invalidate()
        reapplyTimer = nil

        // Restore whatever the Dock had before we overrode it.
        setDockRect(savedBottomRect, orientation: kDockOrientationBottom)

        overlayWindow?.close()
        overlayWindow = nil

        postScreenParamsChanged()
        isInsetEnabled = false
        print("[DisplayEngine] Inset disabled, restored bottom to \(savedBottomRect)")
    }

    // -----------------------------------------------------------------------
    // MARK: – Re-apply (fights the Dock process overwriting us)

    private func reapplyIfNeeded() {
        guard isInsetEnabled, let screen = NSScreen.main else { return }
        let f = screen.frame
        let r = CGRect(x: f.minX, y: f.minY, width: f.width, height: targetInsetPoints)
        setDockRect(r, orientation: kDockOrientationBottom)
    }

    // -----------------------------------------------------------------------
    // MARK: – SkyLight helper
    //
    // CGRect is passed BY VALUE (arm64 HFA – 4 × CGFloat in d0–d3).
    // Return type is void.

    private func setDockRect(_ rect: CGRect, orientation: Int32) {
        guard let ptr = ptrSetDock else {
            print("[DisplayEngine] SLSSetDockRectWithOrientation unavailable")
            return
        }
        unsafeBitCast(ptr, to: SLSSetDockRectByValueFunc.self)(cid, rect, orientation)
    }

    private func postScreenParamsChanged() {
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name("com.apple.screenParametersChangedNotification"),
            object: nil
        )
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApplication.shared
        )
    }

    // -----------------------------------------------------------------------
    // MARK: – Overlay window

    private func makeOverlayWindow(frame: CGRect) -> NSWindow {
        let win = NSWindow(
            contentRect: frame,
            styleMask:   .borderless,
            backing:     .buffered,
            defer:       false
        )
        win.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
        win.backgroundColor    = .black
        win.isOpaque           = true
        win.hasShadow          = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        win.isReleasedWhenClosed = false
        return win
    }
}
