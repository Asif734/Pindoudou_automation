import XCTest
@testable import PDDAXReader

@MainActor
final class AXNotificationRecoveryTests: XCTestCase {
    func testPIDChangeRebindsOnceAndIgnoresOldProcessCallbacks() {
        let process = RecoveryPID(11)
        let subscription = RecoverySubscription()
        var wakes = 0
        let listener = AXNotificationWakeup(callback: { wakes += 1 }, subscription: subscription,
            currentProcessID: { process.value }, automaticHealthChecks: false)
        listener.start()
        listener.checkConnection()
        XCTAssertEqual(subscription.attachments, [11])
        subscription.callbacks[0]()
        XCTAssertEqual(wakes, 1)
        process.value = 22
        listener.checkConnection()
        listener.checkConnection()
        XCTAssertEqual(subscription.attachments, [11, 22])
        XCTAssertEqual(wakes, 2, "Reconnection schedules inspection of messages received while disconnected")
        subscription.callbacks[0]()
        XCTAssertEqual(wakes, 2)
        subscription.callbacks[1]()
        XCTAssertEqual(wakes, 3)
        listener.stop()
        subscription.callbacks[1]()
        process.value = 33
        listener.checkConnection()
        XCTAssertEqual(wakes, 3)
        XCTAssertEqual(subscription.attachments, [11, 22], "Stop prevents late recovery from restarting automation")
    }

    func testMissingProcessAndFailedRegistrationRecoverWithoutStartStop() {
        let process = RecoveryPID(nil)
        let subscription = RecoverySubscription()
        let listener = AXNotificationWakeup(subscription: subscription,
            currentProcessID: { process.value }, automaticHealthChecks: false)
        listener.start()
        XCTAssertTrue(subscription.attachments.isEmpty)
        process.value = 44
        subscription.accept = false
        listener.checkConnection()
        XCTAssertFalse(subscription.isAttached)
        subscription.accept = true
        listener.checkConnection()
        XCTAssertTrue(subscription.isAttached)
        process.value = nil
        listener.checkConnection()
        XCTAssertFalse(subscription.isAttached)
        process.value = 55
        listener.checkConnection()
        XCTAssertEqual(subscription.attachments, [44, 44, 55])
        listener.stop()
    }
}

@MainActor private final class RecoveryPID {
    var value: Int32?
    init(_ value: Int32?) { self.value = value }
}
@MainActor private final class RecoverySubscription: AXNotificationSubscribing {
    var isAttached = false
    var accept = true
    var attachments: [Int32] = []
    var callbacks: [@MainActor () -> Void] = []
    func attach(processID: Int32, notification: @escaping @MainActor () -> Void) -> Bool {
        attachments.append(processID)
        guard accept else { return false }
        callbacks.append(notification)
        isAttached = true
        return true
    }
    func detach() { isAttached = false }
}
