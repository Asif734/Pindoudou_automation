import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol AXNotificationListening: AnyObject {
    var callback: (@MainActor () -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
final class AXNotificationWakeup: AXNotificationListening {
    private var observer: AXObserver?
    private var applicationElement: AXUIElement?
    var callback: (@MainActor () -> Void)?

    init(callback: (@MainActor () -> Void)? = nil) { self.callback = callback }

    func start() {
        start(bundleIdentifier: "com.pinduoduo.merchantMac")
    }

    private func start(bundleIdentifier: String) {
        stop()
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let wakeup = Unmanaged<AXNotificationWakeup>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in wakeup.callback?() }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success,
              let created else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXValueChangedNotification as String,
            kAXLayoutChangedNotification as String,
            kAXRowCountChangedNotification as String,
            kAXCreatedNotification as String,
            "AXLayoutComplete",
            "AXLiveRegionChanged"
        ]
        for notification in notifications {
            _ = AXObserverAddNotification(created, element, notification as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        applicationElement = element
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        applicationElement = nil
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }
}
