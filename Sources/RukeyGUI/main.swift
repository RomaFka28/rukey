import AppKit

// Entry point: build the application, install the delegate and hand over to
// AppKit's run loop. The event tap lives in `.commonModes` of the main run
// loop, so `NSApplication.run()` delivers events to it exactly like the
// console's `CFRunLoopRun()` did; this file must not call `CFRunLoopRun()`.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
