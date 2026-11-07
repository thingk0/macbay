import Foundation
import MacBayKit

enum GUIMenuBarDisplay: String, CaseIterable, Identifiable {
    case connected, combined
    var id: Self { self }
    var title: String { self == .connected ? "Connected gauges" : "Combined storage" }
    init(storedValue: String?) { self = storedValue.flatMap(Self.init(rawValue:)) ?? .connected }
}

enum GUIMenuBarMetric: String, CaseIterable, Identifiable {
    case usedPercentage, availableSpace
    var id: Self { self }
    var title: String { self == .usedPercentage ? "Used percentage" : "Available space" }
    init(storedValue: String?) { self = storedValue.flatMap(Self.init(rawValue:)) ?? .usedPercentage }
}

enum GUIMenuBarPreferences {
    static let enabledKey = "macbay.gui.menuBar.enabled"
    static let displayKey = "macbay.gui.menuBar.display"
    static let metricKey = "macbay.gui.menuBar.metric"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }
}

struct GUIMenuBarCapacity: Equatable {
    let totalBytes: Double
    let availableBytes: Double

    init(_ volume: StorageVolume) {
        totalBytes = Double(volume.totalBytes)
        availableBytes = Double(min(volume.availableBytes, volume.totalBytes))
    }

    private init(totalBytes: Double, availableBytes: Double) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    var usedFraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, 1 - availableBytes / totalBytes))
    }
    var percentageText: String { usedFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
    var availableText: String {
        guard totalBytes > 0 else { return "—" }
        return GUIFormat.bytes(UInt64(exactly: availableBytes.rounded(.down)) ?? UInt64.max)
    }
    func value(for metric: GUIMenuBarMetric) -> String {
        metric == .usedPercentage ? percentageText : availableText
    }
    func combined(with other: Self) -> Self? {
        guard usedFraction != nil, other.usedFraction != nil else { return nil }
        // Sum capacities before dividing: averaging disk percentages hides size differences.
        return Self(totalBytes: totalBytes + other.totalBytes, availableBytes: availableBytes + other.availableBytes)
    }
}

struct GUIMenuBarSnapshot: Equatable {
    let internalName: String
    let externalName: String
    let internalCapacity: GUIMenuBarCapacity?
    let externalCapacity: GUIMenuBarCapacity?
    let connection: String
    let error: String?

    init(status: StatusReport?, selectedVolumePath: String?, error: String?) {
        self.error = error
        let readable = error == nil ? status : nil
        let external = readable?.externalVolumes.first { $0.path == selectedVolumePath }
        internalName = readable?.internalVolume.name ?? "Mac"
        externalName = external?.name ?? readable?.defaultVolume?.name ?? "External drive"
        internalCapacity = readable.map { GUIMenuBarCapacity($0.internalVolume) }
        externalCapacity = external.map(GUIMenuBarCapacity.init)
        if error != nil { connection = "Storage unavailable" }
        else if readable == nil { connection = "Reading storage…" }
        else if external != nil { connection = "Connected" }
        else if readable?.defaultVolume != nil || readable?.externalVolumes.isEmpty == true { connection = "Disconnected" }
        else { connection = "Choose a drive" }
    }

    var combinedCapacity: GUIMenuBarCapacity? {
        guard let internalCapacity, internalCapacity.usedFraction != nil else { return nil }
        guard let externalCapacity else { return internalCapacity }
        return internalCapacity.combined(with: externalCapacity)
    }

    func title(display: GUIMenuBarDisplay, metric: GUIMenuBarMetric) -> String {
        if display == .combined { return combinedCapacity?.value(for: metric) ?? "—" }
        return (internalCapacity?.value(for: metric) ?? "—") + " · " + (externalCapacity?.value(for: metric) ?? "—")
    }

    var toolTip: String {
        if let error { return "MacBay: " + error }
        guard let internalCapacity else { return "MacBay: " + connection }
        let internalDetail = internalName + ": " + internalCapacity.percentageText + " used, " + internalCapacity.availableText + " available"
        guard let externalCapacity else { return internalDetail + "\n" + externalName + ": " + connection }
        return internalDetail + "\n" + externalName + ": " + externalCapacity.percentageText + " used, " + externalCapacity.availableText + " available"
    }
}
