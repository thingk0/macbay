import Foundation
import XCTest
@testable import MacBayKit

final class VolumeChangeMonitorTests: XCTestCase {
    /// A @Sendable handler cannot mutate a captured var, so count through a locked reference.
    private final class EventCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    func testInitialDiskReportIsCoalescedAndUnsubscribeStopsDelivery() {
        let monitor = VolumeChangeMonitor(debounce: 0.2)
        let events = EventCounter()
        let id = monitor.subscribe {
            events.increment()
        }
        // DiskArbitration reports every attached disk on registration; that burst is one event at most.
        Thread.sleep(forTimeInterval: 1.0)
        let delivered = events.value
        XCTAssertLessThanOrEqual(delivered, 1)

        monitor.unsubscribe(id)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(events.value, delivered, "No events after unsubscribing")
    }
}
