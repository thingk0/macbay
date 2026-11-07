import AppKit
import Combine
import SwiftUI

@MainActor
public final class GUIMenuBarController: NSObject {
    private let store: GUIStore
    private let openWindow: () -> Void
    private let openSettings: () -> Void
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()
    private var timer: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var lastSnapshot: GUIMenuBarSnapshot?
    private var lastDisplay: GUIMenuBarDisplay?
    private var lastMetric: GUIMenuBarMetric?

    public var isEnabled: Bool { GUIMenuBarPreferences.isEnabled() }

    public init(store: GUIStore, openWindow: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.store = store
        self.openWindow = openWindow
        self.openSettings = openSettings
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: GUIMenuBarView(store: store,
            openWindow: { [weak self] in self?.showWindow() }, openSettings: { [weak self] in self?.showSettings() }))
        // Only storage changes affect the status item; workflow progress doesn't redraw it.
        Publishers.CombineLatest3(store.$statusReport, store.$selectedVolumePath, store.$statusError)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusItem() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.requestRefresh() }.store(in: &subscriptions)
        updateStatusItem()
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        timer?.cancel()
        timer = nil
        subscriptions.removeAll()
        popover.close()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func updateStatusItem() {
        guard isEnabled else {
            popover.close()
            timer?.cancel()
            timer = nil
            refreshTask?.cancel()
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            lastSnapshot = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            item.button?.imagePosition = .imageLeading
            statusItem = item
        }
        if timer == nil {
            timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.requestRefresh() }
        }
        let snapshot = GUIMenuBarSnapshot(status: store.statusReport, selectedVolumePath: store.selectedVolumePath, error: store.statusError)
        let display = GUIMenuBarDisplay(storedValue: UserDefaults.standard.string(forKey: GUIMenuBarPreferences.displayKey))
        let metric = GUIMenuBarMetric(storedValue: UserDefaults.standard.string(forKey: GUIMenuBarPreferences.metricKey))
        guard snapshot != lastSnapshot || display != lastDisplay || metric != lastMetric else { return }
        lastSnapshot = snapshot
        lastDisplay = display
        lastMetric = metric
        let button = statusItem?.button
        button?.title = " " + snapshot.title(display: display, metric: metric)
        button?.image = Self.gaugeImage(internalFraction: snapshot.internalCapacity?.usedFraction,
                                       externalFraction: snapshot.externalCapacity?.usedFraction)
        button?.toolTip = snapshot.toolTip
        button?.setAccessibilityLabel("MacBay. " + snapshot.toolTip)
    }

    private func requestRefresh() {
        guard isEnabled, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.refreshTask = nil }
            await self.store.refreshStorage()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        requestRefresh()
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showWindow() { popover.close(); openWindow() }
    private func showSettings() { popover.close(); openSettings() }

    static func gaugeImage(internalFraction: Double?, externalFraction: Double?) -> NSImage {
        let image = NSImage(size: NSSize(width: 31, height: 18), flipped: false) { _ in
            for (x, fraction) in [(CGFloat(7), internalFraction), (CGFloat(24), externalFraction)] {
                let center = NSPoint(x: x, y: 9)
                NSColor.labelColor.withAlphaComponent(0.25).setStroke()
                let track = NSBezierPath(ovalIn: NSRect(x: x - 5.5, y: 3.5, width: 11, height: 11))
                track.lineWidth = 2
                track.stroke()
                if let fraction, fraction > 0 {
                    NSColor.labelColor.setStroke()
                    let used = NSBezierPath()
                    used.lineWidth = 2
                    used.lineCapStyle = .round
                    used.appendArc(withCenter: center, radius: 5.5, startAngle: 90,
                                   endAngle: 90 - 360 * CGFloat(min(1, fraction)), clockwise: true)
                    used.stroke()
                }
            }
            NSColor.labelColor.withAlphaComponent(externalFraction == nil ? 0.2 : 1).setStroke()
            let link = NSBezierPath()
            link.lineWidth = 1.5
            if externalFraction == nil { link.setLineDash([1.5, 2], count: 2, phase: 0) }
            link.move(to: NSPoint(x: 13.5, y: 9))
            link.line(to: NSPoint(x: 17.5, y: 9))
            link.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
