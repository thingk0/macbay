import Foundation

#if canImport(DiskArbitration)
import DiskArbitration
#endif

/// Reports that mounted volumes may have changed: a disk appeared, disappeared, or changed its
/// mount path or name. Events carry no detail on purpose. Subscribers re-read mounted volumes and
/// compare, so duplicate or spurious notifications cost one cheap read, never a rescan.
///
/// A burst of disk notifications (one per partition, plus the initial report of every disk that
/// is already attached) is coalesced into a single event after `debounce` seconds of quiet.
public final class VolumeChangeMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "macbay.volume-monitor", qos: .utility)
    private let debounce: TimeInterval
    private var handlers: [UUID: @Sendable () -> Void] = [:]
    private var pendingNotification: DispatchWorkItem?
#if canImport(DiskArbitration)
    private var session: DASession?
#endif

    public init(debounce: TimeInterval = 0.5) {
        self.debounce = debounce
    }

    deinit {
        stop()
    }

    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        let needsStart = handlers.count == 1
        lock.unlock()
        if needsStart {
            start()
        }
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        let empty = handlers.isEmpty
        lock.unlock()
        if empty {
            stop()
        }
    }

    private func start() {
#if canImport(DiskArbitration)
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let watchedKeys = [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeNameKey] as CFArray
        DARegisterDiskAppearedCallback(session, nil, { _, context in
            VolumeChangeMonitor.received(context)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { _, context in
            VolumeChangeMonitor.received(context)
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, watchedKeys, { _, _, context in
            VolumeChangeMonitor.received(context)
        }, context)
        DASessionSetDispatchQueue(session, queue)
        lock.lock()
        self.session = session
        lock.unlock()
#endif
    }

    private func stop() {
#if canImport(DiskArbitration)
        lock.lock()
        let session = self.session
        self.session = nil
        pendingNotification?.cancel()
        pendingNotification = nil
        lock.unlock()
        guard let session else { return }
        DASessionSetDispatchQueue(session, nil)
        // Callbacks hold an unretained pointer to self; let any already queued ones finish first.
        queue.sync {}
#endif
    }

    private static func received(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        Unmanaged<VolumeChangeMonitor>.fromOpaque(context).takeUnretainedValue().scheduleNotification()
    }

    /// Runs on `queue`. Restarts the quiet period so a burst produces one event.
    private func scheduleNotification() {
        lock.lock()
        pendingNotification?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notify() }
        pendingNotification = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func notify() {
        lock.lock()
        pendingNotification = nil
        let current = Array(handlers.values)
        lock.unlock()
        for handler in current {
            handler()
        }
    }
}
