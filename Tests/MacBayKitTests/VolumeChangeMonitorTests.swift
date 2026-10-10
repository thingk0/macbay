import Foundation
import XCTest
@testable import MacBayKit

final class VolumeChangeMonitorTests: XCTestCase {
    func testInitialDiskReportIsCoalescedAndUnsubscribeStopsDelivery() {
        let monitor = VolumeChangeMonitor(debounce: 0.2)
        let lock = NSLock()
        var events = 0
        let id = monitor.subscribe {
            lock.lock()
            events += 1
            lock.unlock()
        }
        // DiskArbitration reports every attached disk on registration; that burst is one event at most.
        Thread.sleep(forTimeInterval: 1.0)
        lock.lock()
        let delivered = events
        lock.unlock()
        XCTAssertLessThanOrEqual(delivered, 1)

        monitor.unsubscribe(id)
        Thread.sleep(forTimeInterval: 0.5)
        lock.lock()
        XCTAssertEqual(events, delivered, "No events after unsubscribing")
        lock.unlock()
    }
}
