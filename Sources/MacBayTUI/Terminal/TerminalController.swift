import Foundation
import Darwin
import MacBayKit

public final class TerminalController: @unchecked Sendable {
    private static var activeInstance: TerminalController?
    private let lock = NSLock()

    private var originalTermios: termios?
    private var isRawMode = false
    private var resizeFlag = false
    private var quitSignalFlag = false
    private var inputBuffer: [UInt8] = []

    // Signal handlers must run on their own queue: the main thread sits in the synchronous UI loop,
    // so sources registered on DispatchQueue.main would never fire.
    private let signalQueue = DispatchQueue(label: "macbay.tui.signals")

    private var winchSource: DispatchSourceSignal?
    private var intSource: DispatchSourceSignal?
    private var termSource: DispatchSourceSignal?

    private var lastCols = 80
    private var lastRows = 24

    public init() {
        Self.installEmergencyExitHandler()
    }

    public static func isInteractiveTerminal(
        stdinFD: Int32 = STDIN_FILENO,
        stdoutFD: Int32 = STDOUT_FILENO,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard isatty(stdinFD) != 0 else { return false }
        guard isatty(stdoutFD) != 0 else { return false }
        guard let term = environment["TERM"], !term.isEmpty, term != "dumb" else {
            return false
        }
        return true
    }

    public func enableRawMode() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isRawMode else { return }

        var term = termios()
        guard tcgetattr(STDIN_FILENO, &term) == 0 else {
            throw MacBayError.unsupportedOperation("Failed to get terminal attributes")
        }
        originalTermios = term

        var raw = term
        cfmakeraw(&raw)
        withUnsafeMutableBytes(of: &raw.c_cc) { bytes in
            bytes[Int(VMIN)] = 0
            bytes[Int(VTIME)] = 1 // 100ms read timeout
        }

        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            throw MacBayError.unsupportedOperation("Failed to set raw terminal attributes")
        }

        isRawMode = true
        Self.activeInstance = self

        // Enter alternate screen buffer & hide cursor
        Self.writeStdout("\u{001B}[?1049h\u{001B}[?25l")

        setupSignalHandlers()
        let size = getWindowSize()
        lastCols = size.cols
        lastRows = size.rows
    }

    public func restore() {
        lock.lock()
        defer { lock.unlock() }

        teardownSignalHandlers()

        if isRawMode {
            // Show cursor & exit alternate screen buffer
            Self.writeStdout("\u{001B}[?7h\u{001B}[?25h\u{001B}[?1049l")

            if var term = originalTermios {
                tcsetattr(STDIN_FILENO, TCSANOW, &term)
            }
            isRawMode = false
        }
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
    }

    private static func installEmergencyExitHandler() {
        struct Once {
            static let installed: Void = {
                atexit {
                    TerminalController.emergencyRestore()
                }
            }()
        }
        _ = Once.installed
    }

    public static func emergencyRestore() {
        Self.writeStdout("\u{001B}[?7h\u{001B}[?25h\u{001B}[?1049l")
        if let active = activeInstance, var term = active.originalTermios {
            tcsetattr(STDIN_FILENO, TCSANOW, &term)
        }
    }

    private func setupSignalHandlers() {
        // Ignore standard SIGINT/SIGTERM from killing instantly without cleanup
        Darwin.signal(SIGINT, SIG_IGN)
        Darwin.signal(SIGTERM, SIG_IGN)
        Darwin.signal(SIGWINCH, SIG_IGN)

        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: signalQueue)
        winch.setEventHandler { [weak self] in
            self?.lock.lock()
            self?.resizeFlag = true
            self?.lock.unlock()
        }
        winch.resume()
        self.winchSource = winch

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        sigint.setEventHandler { [weak self] in
            self?.lock.lock()
            self?.quitSignalFlag = true
            self?.lock.unlock()
        }
        sigint.resume()
        self.intSource = sigint

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        sigterm.setEventHandler { [weak self] in
            self?.lock.lock()
            self?.quitSignalFlag = true
            self?.lock.unlock()
        }
        sigterm.resume()
        self.termSource = sigterm
    }

    private func teardownSignalHandlers() {
        winchSource?.cancel()
        winchSource = nil
        intSource?.cancel()
        intSource = nil
        termSource?.cancel()
        termSource = nil

        Darwin.signal(SIGINT, SIG_DFL)
        Darwin.signal(SIGTERM, SIG_DFL)
        Darwin.signal(SIGWINCH, SIG_DFL)
    }

    public func getWindowSize() -> (cols: Int, rows: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }

    public func readKey() -> Key {
        lock.lock()
        if quitSignalFlag {
            quitSignalFlag = false
            lock.unlock()
            return .ctrlC
        }
        if resizeFlag {
            resizeFlag = false
            lock.unlock()
            return .resize
        }
        lock.unlock()

        // Check if window dimensions changed
        let currentSize = getWindowSize()
        if currentSize.cols != lastCols || currentSize.rows != lastRows {
            lastCols = currentSize.cols
            lastRows = currentSize.rows
            return .resize
        }

        if let buffered = consumeBufferedKey() {
            return buffered
        }

        guard fillInputBuffer(timeoutMs: 50) else { return .none }
        return consumeBufferedKey() ?? .none
    }

    private func consumeBufferedKey() -> Key? {
        guard !inputBuffer.isEmpty else { return nil }

        if let parsed = Key.parsePrefix(bytes: inputBuffer) {
            inputBuffer.removeFirst(parsed.consumed)
            return parsed.key
        }

        // Partial sequence: give the remaining bytes a moment to arrive.
        if fillInputBuffer(timeoutMs: 30), let parsed = Key.parsePrefix(bytes: inputBuffer) {
            inputBuffer.removeFirst(parsed.consumed)
            return parsed.key
        }

        // A lone ESC is a key press, not the start of a sequence that never came.
        if inputBuffer == [27] {
            inputBuffer.removeFirst()
            return .escape
        }

        return nil
    }

    @discardableResult
    private func fillInputBuffer(timeoutMs: Int32) -> Bool {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let pollRes = poll(&pfd, 1, timeoutMs)
        guard pollRes > 0, (pfd.revents & Int16(POLLIN)) != 0 else { return false }

        var buffer = [UInt8](repeating: 0, count: 64)
        let bytesRead = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        guard bytesRead > 0 else { return false }
        inputBuffer.append(contentsOf: buffer[0..<bytesRead])
        return true
    }

    public func render(_ text: String) {
        Self.writeStdout(Self.frameOutput(text))
    }

    /// Address rows explicitly: newline-based painting can scroll the entire screen at
    /// the bottom margin when a terminal measures a glyph wider than our renderer.
    static func frameOutput(_ text: String) -> String {
        var output = "\u{001B}[?7l"
        for (index, row) in text.components(separatedBy: "\r\n").enumerated() {
            let singleLine = row.replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            output += "\u{001B}[\(index + 1);1H\u{001B}[0m\u{001B}[2K" + singleLine
        }
        // Move away from the bottom-right cell before restoring automatic wrapping.
        return output + "\u{001B}[0m\u{001B}[H\u{001B}[?7h"
    }

    private static func writeStdout(_ str: String) {
        str.utf8CString.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress, ptr.count > 1 else { return }
            _ = Darwin.write(STDOUT_FILENO, base, ptr.count - 1)
        }
    }

    deinit {
        restore()
    }
}
