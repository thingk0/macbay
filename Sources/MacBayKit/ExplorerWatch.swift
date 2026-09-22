import Foundation

#if canImport(CoreServices)
import CoreServices
#endif

public struct ExplorerChangeEvent: Equatable, Sendable {
    public let changedPaths: [String]
    public let droppedEvents: Bool
    public let historyDone: Bool

    public init(changedPaths: [String], droppedEvents: Bool = false, historyDone: Bool = true) {
        self.changedPaths = changedPaths
        self.droppedEvents = droppedEvents
        self.historyDone = historyDone
    }
}

public struct ExplorerRefreshResult: Equatable, Sendable {
    public let report: ExplorerScanReport
    public let refreshedPaths: [String]
    public let fullRescan: Bool

    public init(report: ExplorerScanReport, refreshedPaths: [String], fullRescan: Bool) {
        self.report = report
        self.refreshedPaths = refreshedPaths
        self.fullRescan = fullRescan
    }
}

public final class ExplorerChangeMonitor: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var handlers: [UUID: @Sendable (ExplorerChangeEvent) -> Void] = [:]
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    nonisolated(unsafe) private var lastEventID: FSEventStreamEventId = UInt64(kFSEventStreamEventIdSinceNow)
    private let watchedRoot: String
    private let latency: CFTimeInterval

    public init(watchedRoot: String, latency: TimeInterval = 1.0) {
        self.watchedRoot = watchedRoot
        self.latency = latency
    }

    deinit {
        stop()
    }

    public func currentEventID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return lastEventID
    }

    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (ExplorerChangeEvent) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        let needsStart = stream == nil
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
#if canImport(CoreServices)
        let paths = [watchedRoot] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagIgnoreSelf
                | kFSEventStreamCreateFlagFileEvents
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            ExplorerChangeMonitor.eventCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }
        lock.lock()
        stream = created
        lock.unlock()
        FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(created)
#else
        return
#endif
    }

    public func stop() {
#if canImport(CoreServices)
        lock.lock()
        let active = stream
        stream = nil
        lock.unlock()
        if let active {
            FSEventStreamStop(active)
            FSEventStreamInvalidate(active)
            FSEventStreamRelease(active)
        }
#endif
    }

#if canImport(CoreServices)
    private static let eventCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, eventIDs in
        guard let info else { return }
        let monitor = Unmanaged<ExplorerChangeMonitor>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        var dropped = false
        for index in 0..<Int(numEvents) {
            let flag = eventFlags[index]
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                dropped = true
            }
        }
        var newest = monitor.currentEventID()
        for index in 0..<Int(numEvents) {
            newest = max(newest, UInt64(eventIDs[index]))
        }
        monitor.lock.lock()
        monitor.lastEventID = max(monitor.lastEventID, newest)
        let handlers = Array(monitor.handlers.values)
        monitor.lock.unlock()
        let event = ExplorerChangeEvent(changedPaths: paths, droppedEvents: dropped)
        for handler in handlers {
            handler(event)
        }
    }
#endif
}

public struct ExplorerRefresher {
    private let fileManager: FileManager
    private let scanner: ExplorerScanner
    private let recordStore: ScanRecordStore

    public init(
        fileManager: FileManager = .default,
        diskInfoProvider: (any DiskInfoProvider)? = nil,
        recordStore: ScanRecordStore? = nil
    ) {
        self.fileManager = fileManager
        self.scanner = ExplorerScanner(fileManager: fileManager, diskInfoProvider: diskInfoProvider)
        self.recordStore = recordStore ?? ScanRecordStore(fileManager: fileManager)
    }

    public func refresh(
        root: String,
        event: ExplorerChangeEvent,
        recordScan: Bool = true
    ) -> ExplorerRefreshResult? {
        let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        guard let previous = recordStore.load(forRootPath: standardizedRoot) else {
            guard let report = try? fullScan(root: standardizedRoot, recordScan: recordScan) else { return nil }
            return ExplorerRefreshResult(report: report, refreshedPaths: [], fullRescan: true)
        }
        if event.droppedEvents {
            guard let report = try? fullScan(root: standardizedRoot, recordScan: recordScan) else { return nil }
            return ExplorerRefreshResult(report: report, refreshedPaths: [], fullRescan: true)
        }
        let relevant = event.changedPaths.filter {
            $0 == standardizedRoot || $0.hasPrefix(standardizedRoot + "/")
        }
        guard !relevant.isEmpty else { return nil }
        var entriesByPath = Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.path, $0) })
        var refreshed: [String] = []
        var warnings = previous.warnings
        for changed in relevant {
            let standardized = URL(fileURLWithPath: changed).standardizedFileURL.path
            if standardized == standardizedRoot {
                guard let report = try? fullScan(root: standardizedRoot, recordScan: recordScan) else { return nil }
                return ExplorerRefreshResult(report: report, refreshedPaths: [standardizedRoot], fullRescan: true)
            }
            let parent = URL(fileURLWithPath: standardized).deletingLastPathComponent().standardizedFileURL.path
            let remeasured = remeasureEntry(at: standardized, parentRoot: standardizedRoot, warnings: &warnings)
            entriesByPath[standardized] = remeasured
            refreshed.append(standardized)
            _ = parent
        }
        var entries = Array(entriesByPath.values)
        entries.sort {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            if $0.logicalBytes != $1.logicalBytes { return $0.logicalBytes > $1.logicalBytes }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let totalLogical = entries.reduce(UInt64(0)) { $0.addingReportingOverflow($1.logicalBytes).partialValue }
        let totalAllocated = entries.reduce(UInt64(0)) { $0.addingReportingOverflow($1.allocatedBytes).partialValue }
        let scan = ExplorerScan(
            rootPath: standardizedRoot,
            entries: entries,
            totalLogicalBytes: totalLogical,
            totalAllocatedBytes: totalAllocated,
            complete: previous.complete,
            unreadablePaths: previous.unreadablePaths,
            warnings: warnings
        )
        let report = recordStore.buildReport(from: scan, previous: previous)
        if recordScan {
            try? recordStore.save(report)
        }
        return ExplorerRefreshResult(report: report, refreshedPaths: refreshed.sorted(), fullRescan: false)
    }

    private func fullScan(root: String, recordScan: Bool) throws -> ExplorerScanReport {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MacBayError.pathMissing(root)
        }
        let scan = scanner.scanDirectory(URL(fileURLWithPath: root))
        let previous = recordStore.load(forRootPath: scan.rootPath)
        let report = recordStore.buildReport(from: scan, previous: previous)
        if recordScan {
            try recordStore.save(report)
        }
        return report
    }

    private func remeasureEntry(at path: String, parentRoot: String, warnings: inout [String]) -> ExplorerEntry? {
        let url = URL(fileURLWithPath: path)
        if (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil {
            var unreadable: [String] = []
            let (_, entry) = remeasureChild(url: url, warnings: &warnings, unreadablePaths: &unreadable)
            return entry
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        if parent.path != parentRoot && !parentRoot.hasPrefix(parent.path + "/") && parent.path != URL(fileURLWithPath: parentRoot).standardizedFileURL.path {
            var unreadable: [String] = []
            let (_, entry) = remeasureChild(url: url, warnings: &warnings, unreadablePaths: &unreadable)
            return entry
        }
        var unreadable: [String] = []
        let (_, entry) = remeasureChild(url: url, warnings: &warnings, unreadablePaths: &unreadable)
        return entry
    }

    private func remeasureChild(
        url: URL,
        warnings: inout [String],
        unreadablePaths: inout [String]
    ) -> (sized: (logical: UInt64, allocated: UInt64, fileCount: Int)?, entry: ExplorerEntry?) {
        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent
        if let linkDestination = try? fileManager.destinationOfSymbolicLink(atPath: standardized.path) {
            let resolved = URL(fileURLWithPath: linkDestination, relativeTo: standardized.deletingLastPathComponent()).standardizedFileURL
            return (nil, ExplorerEntry(
                name: name,
                path: standardized.path,
                kind: .symlink,
                externalTarget: resolved.path,
                action: resolved.path.hasPrefix("/Volumes/") ? .externalLink : .directoryMove
            ))
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            return (nil, nil)
        }
        if !isDirectory.boolValue {
            let values = try? standardized.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isReadableKey])
            guard values?.isReadable != false else {
                unreadablePaths.append(standardized.path)
                return (nil, ExplorerEntry(name: name, path: standardized.path, kind: .file, unreadable: true, action: .unreadable))
            }
            let logical = UInt64(max(0, values?.fileSize ?? 0))
            let allocated = UInt64(max(0, values?.totalFileAllocatedSize ?? values?.fileSize ?? 0))
            return ((logical, allocated, 1), ExplorerEntry(
                name: name,
                path: standardized.path,
                kind: .file,
                logicalBytes: logical,
                allocatedBytes: allocated,
                fileCount: 1,
                action: scanner.movableFileAction(for: standardized)
            ))
        }
        if standardized.pathExtension.lowercased() == "app" {
            let scan = scanner.scanDirectory(standardized.deletingLastPathComponent())
            if let match = scan.entries.first(where: { $0.path == standardized.path }) {
                return ((match.logicalBytes, match.allocatedBytes, match.fileCount), match)
            }
            return (nil, ExplorerEntry(name: name, path: standardized.path, kind: .application, unreadable: true, action: .unreadable))
        }
        let parent = standardized.deletingLastPathComponent()
        let scan = scanner.scanDirectory(parent)
        if let match = scan.entries.first(where: { $0.path == standardized.path }) {
            return ((match.logicalBytes, match.allocatedBytes, match.fileCount), match)
        }
        return (nil, ExplorerEntry(
            name: name,
            path: standardized.path,
            kind: .directory,
            action: scanner.movableAction(for: standardized)
        ))
    }
}
