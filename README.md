# iMac Screen Panel Partially Dead Fixer

A lightweight macOS menu-bar app that hides the dead/broken strip at the bottom of an iMac screen panel — and **prevents other apps from laying out into that dead zone**.

---

## The Problem

Older iMacs sometimes develop a partially dead LCD panel, typically a horizontal strip at the bottom of the screen that no longer displays anything. The screen still works everywhere else, but that dead strip remains black. macOS has no built-in way to "shrink" the usable display area to hide it.

---

## What Was Wrong (Original Code)

The original implementation tried three things, all of which failed on modern macOS:

### 1. `CGSSetDisplayInsets` — symbol doesn't exist
```swift
if let sym = dlsym(handle, "CGSSetDisplayInsets") { ... }
// → "Symbol CGSSetDisplayInsets not found"
```
This CGS-era private API was removed from SkyLight in macOS 12+. The `dlsym` call silently returned `nil` every time.

### 2. `CGSSetSessionDisplayInsets` — also gone
```swift
if let sym = dlsym(handle, "CGSSetSessionDisplayInsets") { ... }
// → "Symbol CGSSetSessionDisplayInsets not found"
```
Same issue. Both symbols are absent from the SkyLight dyld cache on macOS 12–26.

### 3. `NSApplicationMain()` misuse
```swift
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
```
`NSApplicationMain()` is designed for proper `.app` bundles with an `Info.plist`. Called on a bare compiled executable it behaved unpredictably. The correct call for a non-bundle Cocoa app is `app.run()`.

### 4. Swift `Optional<@convention(c) ...>` stored properties → segfault
When the code was updated to use `SLSSetDockRectWithOrientation`, storing the function pointer as:
```swift
var fnSetDock: SLSSetDockRectFunc?   // @convention(c) optional stored property
```
caused a **segmentation fault at startup** due to Swift's unreliable memory layout for `Optional` wrapping a C function type. The safe pattern is to store the raw `UnsafeMutableRawPointer?` from `dlsym` and `unsafeBitCast` it inline at the call site.

### 5. arm64 ABI mismatch for `CGRect` → segfault on "Enable Inset"
The function `SLSSetDockRectWithOrientation` was declared with:
```swift
// ❌ Wrong — passes a pointer in integer register x1
@convention(c) (Int32, UnsafeMutablePointer<CGRect>, Int32) -> CGError
```
On **arm64**, `CGRect` (4 × `CGFloat` = 32 bytes) is a **Homogeneous Floating-point Aggregate (HFA)**. The arm64 ABI passes HFAs **by value in SIMD registers `d0–d3`**, not via a pointer. Using the wrong calling convention corrupted the call stack and caused an immediate segfault when the button was clicked.

---

## The Fix

### Visual coverage — black overlay window
A borderless `NSWindow` is placed over the dead strip at the maximum window level. It covers the dead LCD area visually and ignores all mouse events:
```swift
win.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
win.ignoresMouseEvents = true
win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
```

### System-level space reservation — `SLSSetDockRectWithOrientation`
This is the exact private SkyLight API the Dock process uses to tell WindowServer "reserve this rect on this screen edge". WindowServer uses these reservations to compute `NSScreen.visibleFrame` — the area apps are allowed to use. By calling it ourselves with a rect covering the dead zone, we shrink the usable screen area and prevent apps from laying out into it:

```swift
// Correct arm64 signature — CGRect by VALUE in SIMD registers
typealias SLSSetDockRectByValueFunc = @convention(c) (Int32, CGRect, Int32) -> Void

unsafeBitCast(ptr, to: SLSSetDockRectByValueFunc.self)(cid, rect, orientation)
```

A 1-second `Timer` re-asserts the reservation because the Dock process periodically overwrites it.

### Saved rect derived from `NSScreen` (no SkyLight read needed)
Instead of calling `SLSGetDockRectWithOrientation` (which also has an uncertain ABI), the pre-existing bottom reservation is derived safely from `NSScreen`:
```swift
let currentBottom = max(screen.visibleFrame.minY - screen.frame.minY, 0)
```

### `app.run()` instead of `NSApplicationMain()`
For a non-bundle executable the Cocoa run loop is started with:
```swift
app.run()   // not NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
```

---

## Usage

### Build & run once
```bash
make run
```

### Install (copies to `~/Applications` + auto-starts on login via LaunchAgent)
```bash
make install
```

### Uninstall
```bash
make clean
launchctl unload ~/Library/LaunchAgents/com.user.screeninset.plist
rm ~/Library/LaunchAgents/com.user.screeninset.plist
rm ~/Applications/ScreenInset
```

### Adjust the dead-zone size
Click the **⬛ Inset** menu-bar icon → drag the slider to match your screen's dead strip height (default: 232 pt). The inset re-applies immediately while the slider moves.

---

## Requirements

- macOS 12+ (arm64 or x86_64)
- Xcode Command Line Tools (`xcode-select --install`)
- No entitlements or SIP changes required

---

## How it works (summary)

| Component | Role |
|---|---|
| Black `NSWindow` | Visually covers the dead LCD strip |
| `SLSSetDockRectWithOrientation` | Tells WindowServer to reserve the strip → shrinks `NSScreen.visibleFrame` |
| 1 s `Timer` | Re-asserts reservation (Dock process overwrites periodically) |
| `NSScreen` delta | Safely derives the pre-existing bottom reservation without SkyLight read calls |
