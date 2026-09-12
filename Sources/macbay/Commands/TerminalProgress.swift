import Foundation
import Darwin
import MacBayKit

/// stderr-only activity display; the library emits events and knows nothing about terminals.
final class TerminalProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let enabled: Bool
    private let interactive: Bool
    private var timer: DispatchSourceTimer?
    private var copyLabel: String?
    private var label = "Starting"
    private var started = Date()
    private var active = true

    init(json: Bool) {
        enabled = !json
        interactive = isatty(STDERR_FILENO) != 0
        if enabled && interactive {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "macbay.progress"))
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func update(_ event: OperationProgress) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, active else { return }

        if case .copyProgress(let sample) = event {
            let speed = sample.bytesPerSecond.map { " · ~" + OutputFormatter.humanBytes($0) + "/s" } ?? ""
            copyLabel = "Copy estimate: \(OutputFormatter.humanBytes(sample.observedBytes)) / \(OutputFormatter.humanBytes(sample.totalBytes)) (\(Int(sample.fraction * 100))%)" + speed
            if interactive, let copyLabel { write("\r\u{001B}[2K" + copyLabel) }
            return
        }
        copyLabel = nil
        if label != "Starting" {
            let elapsed = Date().timeIntervalSince(started)
            let elapsedStr = String(format: "%.1fs", elapsed)
            if interactive {
                write("\r\u{001B}[2K  ✔ \(label) (\(elapsedStr))\n")
            } else {
                write("  ✔ \(label) (\(elapsedStr))\n")
            }
        }

        switch event {
        case .copyProgress: return
        case .selectingVolume: label = "Selecting volume"
        case .validating: label = "Validating application and links"
        case .checkingProcesses: label = "Checking running processes and locks"
        case .verifyingSignature: label = "Verifying code signature"
        case .checkingCompatibility: label = "Checking application compatibility"
        case .inspectingStorage: label = "Checking size, storage and records"
        case .copying: label = "Copying application"
        case .moving: label = "Moving application"
        case .updatingLink: label = "Updating application link"
        case .savingManifest: label = "Saving MacBay records"
        case .refreshingDock: label = "Refreshing Dock"
        }
        started = Date()
        write(interactive ? "\(label)…" : "\(label)…\n")
    }

    private func tick() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        write("\r\u{001B}[2K\(copyLabel ?? label)… \(Int(Date().timeIntervalSince(started)))s elapsed")
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        active = false
        timer?.cancel()
        timer = nil
        if enabled {
            if label != "Starting" {
                let elapsed = Date().timeIntervalSince(started)
                let elapsedStr = String(format: "%.1fs", elapsed)
                if interactive {
                    write("\r\u{001B}[2K  ✔ \(label) (\(elapsedStr))\n")
                } else {
                    write("  ✔ \(label) (\(elapsedStr))\n")
                }
            } else if interactive {
                write("\r\u{001B}[2K")
            }
        }
    }

    private func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    deinit { timer?.cancel() }
}
