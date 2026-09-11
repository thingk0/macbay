import Foundation
import XCTest
import Darwin
import MacBayKit
@testable import MacBayTUI

final class PTYIntegrationTests: XCTestCase {

    private var binaryURL: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("mb")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("mb")
    }

    final class PTYSession {
        let process: Process
        let masterFD: Int32
        private let lock = NSLock()
        private var outputData = Data()
        private var isDraining = true
        private var drainThread: Thread?

        init(process: Process, masterFD: Int32) {
            self.process = process
            self.masterFD = masterFD
            startDraining()
        }

        private func startDraining() {
            let thread = Thread { [weak self] in
                guard let self else { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while self.isDraining {
                    let n = Darwin.read(self.masterFD, &buffer, buffer.count)
                    if n > 0 {
                        self.lock.lock()
                        self.outputData.append(buffer, count: n)
                        self.lock.unlock()
                    } else if n == 0 {
                        break
                    } else {
                        usleep(10_000)
                    }
                }
            }
            self.drainThread = thread
            thread.start()
        }

        func output() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: outputData, encoding: .utf8) ?? ""
        }

        func write(_ str: String) {
            str.utf8CString.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress, ptr.count > 1 else { return }
                _ = Darwin.write(masterFD, base, ptr.count - 1)
            }
        }

        @discardableResult
        func waitForOutput(containing text: String, timeout: TimeInterval = 2.0) -> Bool {
            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                if output().contains(text) {
                    return true
                }
                usleep(20_000)
            }
            return output().contains(text)
        }

        func waitForExit(timeout: TimeInterval = 3.0) -> Bool {
            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                if !process.isRunning {
                    return true
                }
                usleep(20_000)
            }
            return !process.isRunning
        }

        func close() {
            isDraining = false
            Darwin.close(masterFD)
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private func spawnInPTY(
        arguments: [String] = [],
        initialCols: UInt16 = 80,
        initialRows: UInt16 = 24,
        environment: [String: String]? = nil
    ) throws -> PTYSession {
        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        var ws = winsize(ws_row: initialRows, ws_col: initialCols, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&masterFD, &slaveFD, nil, nil, &ws) == 0 else {
            throw MacBayError.unsupportedOperation("Failed to open PTY")
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments

        var env = environment ?? ProcessInfo.processInfo.environment
        if env["TERM"] == nil || env["TERM"] == "dumb" {
            env["TERM"] = "xterm-256color"
        }
        process.environment = env

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        try process.run()
        Darwin.close(slaveFD)

        return PTYSession(process: process, masterFD: masterFD)
    }

    func testZeroArgumentLaunchesTUIAndQuitsCleanly() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let session = try spawnInPTY(arguments: [])
        defer { session.close() }

        // Wait for MacBay header
        let hasHeader = session.waitForOutput(containing: "MacBay", timeout: 2.0)
        XCTAssertTrue(hasHeader, "TUI should output MacBay header on zero-arg in PTY")

        // Send 'q' to quit
        session.write("q")

        // Wait for clean exit
        XCTAssertTrue(session.waitForExit(timeout: 3.0), "TUI should exit within timeout after 'q'")
        XCTAssertEqual(session.process.terminationStatus, 0)

        let totalOutput = session.output()
        // Check terminal cleanup codes
        XCTAssertTrue(totalOutput.contains("\u{001B}[?1049l") || totalOutput.contains("\u{001B}[?25h"),
                      "Terminal must restore alt screen and cursor")
    }

    func testKeyInputNavigationInPTY() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let session = try spawnInPTY(arguments: ["tui"])
        defer { session.close() }

        XCTAssertTrue(session.waitForOutput(containing: "MacBay", timeout: 2.0))

        // Navigate down to Restore Application (item index 1)
        session.write("\u{001B}[B")
        usleep(100_000)

        // Press Enter to open Restore Application. The home menu also renders the string
        // "Restore Application", so match the restore screen's blue breadcrumb instead.
        session.write("\r")
        let restoreScreenMarker = "\u{001B}[1;34mRestore Application\u{001B}[0m"
        let openedRestore = session.waitForOutput(containing: restoreScreenMarker, timeout: 2.0)
        XCTAssertTrue(openedRestore, "Expected the restore screen breadcrumb, not the home menu entry")

        // Press 'q' to quit from the subscreen
        session.write("q")
        XCTAssertTrue(session.waitForExit(timeout: 3.0))
        XCTAssertEqual(session.process.terminationStatus, 0)
    }

    func testSigtermShutsDownCleanly() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let session = try spawnInPTY(arguments: [])
        defer { session.close() }

        XCTAssertTrue(session.waitForOutput(containing: "MacBay", timeout: 2.0))

        // External termination must trigger the same clean shutdown as pressing 'q'
        XCTAssertEqual(Darwin.kill(session.process.processIdentifier, SIGTERM), 0)

        XCTAssertTrue(session.waitForExit(timeout: 3.0), "TUI should exit within timeout after SIGTERM")
        XCTAssertEqual(session.process.terminationStatus, 0)

        let totalOutput = session.output()
        XCTAssertTrue(totalOutput.contains("\u{001B}[?1049l") || totalOutput.contains("\u{001B}[?25h"),
                      "Terminal must restore alt screen and cursor after SIGTERM")
    }

    func testPTYScreenResizeShowsResizeWarning() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("Binary not found at \(binaryURL.path)")
        }

        let session = try spawnInPTY(arguments: [], initialCols: 80, initialRows: 24)
        defer { session.close() }

        XCTAssertTrue(session.waitForOutput(containing: "MacBay", timeout: 2.0))

        // Resize PTY to 60x15 (too small)
        var smallWs = winsize(ws_row: 15, ws_col: 60, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(session.masterFD, TIOCSWINSZ, &smallWs)

        // Wait for resize notice
        let showsNotice = session.waitForOutput(containing: "Terminal Window Too Small", timeout: 2.0)
        XCTAssertTrue(showsNotice, "Should display resize notice on small window")

        // Send 'q' to quit
        session.write("q")
        XCTAssertTrue(session.waitForExit(timeout: 3.0))
        XCTAssertEqual(session.process.terminationStatus, 0)
    }
}
