import Cocoa
import CoreGraphics
import Darwin

// Define function types
typealias CGSMainConnectionIDFunc = @convention(c) () -> Int32
typealias CGSSetDisplayInsetsFunc = @convention(c) (CGDirectDisplayID, NSEdgeInsets) -> CGError
typealias CGSSetSessionDisplayInsetsFunc = @convention(c) (Int32, CGDirectDisplayID, CGRect) -> CGError

class DisplayEngine {
    static let shared = DisplayEngine()
    var isInsetEnabled = false
    let targetInsetPoints: CGFloat = 232.0
    
    private var skyLightHandle: UnsafeMutableRawPointer?
    
    init() {
        // Load SkyLight dynamically to bypass SDK .tbd missing symbols
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        skyLightHandle = dlopen(path, RTLD_NOW)
        if skyLightHandle == nil {
            print("Failed to load SkyLight.framework at runtime")
        }
    }
    
    func applyInset(enabled: Bool) -> Bool {
        guard let handle = skyLightHandle else {
            print("No SkyLight handle")
            return false
        }
        
        let displayID = CGMainDisplayID()
        let bottomInset = enabled ? targetInsetPoints : 0.0
        
        // 1. Try CGSSetDisplayInsets
        if let sym = dlsym(handle, "CGSSetDisplayInsets") {
            let CGSSetDisplayInsets = unsafeBitCast(sym, to: CGSSetDisplayInsetsFunc.self)
            let insets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
            let err1 = CGSSetDisplayInsets(displayID, insets)
            if err1 == .success {
                isInsetEnabled = enabled
                postReflow()
                return true
            } else {
                print("CGSSetDisplayInsets returned \(err1)")
            }
        } else {
            print("Symbol CGSSetDisplayInsets not found")
        }
        
        // 2. Try CGSSetSessionDisplayInsets
        if let symSetSession = dlsym(handle, "CGSSetSessionDisplayInsets"),
           let symMainConn = dlsym(handle, "CGSMainConnectionID") {
            
            let CGSSetSessionDisplayInsets = unsafeBitCast(symSetSession, to: CGSSetSessionDisplayInsetsFunc.self)
            let CGSMainConnectionID = unsafeBitCast(symMainConn, to: CGSMainConnectionIDFunc.self)
            
            let cid = CGSMainConnectionID()
            let rectInsets = CGRect(x: 0, y: 0, width: 0, height: bottomInset)
            let err2 = CGSSetSessionDisplayInsets(cid, displayID, rectInsets)
            if err2 == .success {
                isInsetEnabled = enabled
                postReflow()
                return true
            } else {
                print("CGSSetSessionDisplayInsets returned \(err2)")
            }
        } else {
            print("Symbol CGSSetSessionDisplayInsets not found")
        }
        
        print("Fallback required but not implemented.")
        return false
    }
    
    private func postReflow() {
        // Trigger WindowServer/apps to respect new geometry
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
}
