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
protocol AXNotificationSubscribing: AnyObject {
    var isAttached: Bool { get }
    func attach(processID: pid_t, notification: @escaping @MainActor () -> Void) -> Bool
    func detach()
}

/// Keeps the notification subscription attached to the current PDD process.
/// Polling is supplementary; it never opens a chat or sends a message.
@MainActor
final class AXNotificationWakeup: AXNotificationListening {
    var callback: (@MainActor () -> Void)?
    private let subscription: any AXNotificationSubscribing
    private let currentProcessID: @MainActor () -> pid_t?
    private let automaticHealthChecks: Bool
    private let logRoot: URL?
    private var healthTask: Task<Void, Never>?
    private var enabled = false
    private var boundProcessID: pid_t?
    private var generation = 0
    private var checkedConnection = false

    init(callback: (@MainActor () -> Void)? = nil,
         subscription: (any AXNotificationSubscribing)? = nil,
         currentProcessID: @escaping @MainActor () -> pid_t? = {
             NSRunningApplication.runningApplications(withBundleIdentifier: "com.pinduoduo.merchantMac").first?.processIdentifier
         }, automaticHealthChecks: Bool = true, logRoot: URL? = nil) {
        self.callback = callback
        self.subscription = subscription ?? LiveAXNotificationSubscription()
        self.currentProcessID = currentProcessID
        self.automaticHealthChecks = automaticHealthChecks
        self.logRoot = logRoot
    }

    func start() {
        enabled = true
        checkConnection()
        guard automaticHealthChecks, healthTask == nil else { return }
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.enabled, !Task.isCancelled else { return }
                self.checkConnection()
            }
        }
    }

    func checkConnection() {
        guard enabled else { return }
        let wasChecked = checkedConnection
        checkedConnection = true
        let processID = currentProcessID()
        if processID == boundProcessID && (processID == nil || subscription.isAttached) { return }
        generation += 1
        let revision = generation
        subscription.detach()
        let previous = boundProcessID
        boundProcessID = nil
        guard let processID else {
            log("ax-listener-waiting-for-process", "previous_pid=\(previous.map(String.init) ?? "none")")
            return
        }
        let attached = subscription.attach(processID: processID) { [weak self] in
            guard let self, self.enabled, self.generation == revision else { return }
            self.callback?()
        }
        if attached {
            boundProcessID = processID
            log("ax-listener-attached", "pid=\(processID) previous_pid=\(previous.map(String.init) ?? "none")")
            if wasChecked { callback?() } // Inspect messages that arrived while disconnected.
        } else {
            log("ax-listener-attach-retry", "pid=\(processID)")
        }
    }

    func stop() {
        enabled = false
        checkedConnection = false
        generation += 1
        healthTask?.cancel()
        healthTask = nil
        subscription.detach()
        boundProcessID = nil
    }

    private func log(_ kind: String, _ detail: String) {
        AutomationStepLog.record(root: logRoot, uid: nil, step: kind, detail: detail)
    }

    deinit { healthTask?.cancel() }
}

@MainActor
private final class LiveAXNotificationSubscription: AXNotificationSubscribing {
    private var observer: AXObserver?
    private var applicationElement: AXUIElement?
    private var notification: (@MainActor () -> Void)?
    var isAttached: Bool { observer != nil }

    func attach(processID: pid_t, notification: @escaping @MainActor () -> Void) -> Bool {
        detach()
        let element = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let subscription = Unmanaged<LiveAXNotificationSubscription>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak subscription] in subscription?.notification?() }
        }
        guard AXObserverCreate(processID, callback, &created) == .success, let created else { return false }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let names = [kAXValueChangedNotification as String, kAXLayoutChangedNotification as String,
                     kAXRowCountChangedNotification as String, kAXCreatedNotification as String,
                     "AXLayoutComplete", "AXLiveRegionChanged"]
        var registered = false
        for name in names {
            let result = AXObserverAddNotification(created, element, name as CFString, context)
            registered = registered || result == .success || result == .notificationAlreadyRegistered
        }
        guard registered else { return false }
        self.notification = notification
        observer = created
        applicationElement = element
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        return true
    }

    func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        applicationElement = nil
        notification = nil
    }

    deinit {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
    }
}
