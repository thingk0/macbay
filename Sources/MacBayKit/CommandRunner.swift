import Foundation

public protocol CommandRunner: Sendable {
    func run(_ executable: String, arguments: [String]) throws -> CommandResult
}

public struct SystemCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        let identifier = UUID().uuidString
        let outputURL = temporaryDirectory.appendingPathComponent("macbay-command-\(identifier)-out")
        let errorURL = temporaryDirectory.appendingPathComponent("macbay-command-\(identifier)-err")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
            throw MacBayError.commandFailed(
                executable: executable,
                status: -1,
                details: "Unable to create temporary command output files"
            )
        }

        var outputHandle: FileHandle?
        var errorHandle: FileHandle?
        var inputHandle: FileHandle?
        defer {
            try? outputHandle?.close()
            try? errorHandle?.close()
            try? inputHandle?.close()
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }

        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
            errorHandle = try FileHandle(forWritingTo: errorURL)
            inputHandle = FileHandle(forReadingAtPath: "/dev/null")
        } catch {
            throw MacBayError.commandFailed(
                executable: executable,
                status: -1,
                details: error.localizedDescription
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        do {
            try process.run()
        } catch {
            throw MacBayError.commandFailed(
                executable: executable,
                status: -1,
                details: error.localizedDescription
            )
        }

        process.waitUntilExit()
        try? outputHandle?.close()
        try? errorHandle?.close()
        outputHandle = nil
        errorHandle = nil
        let output = String(data: try Data(contentsOf: outputURL), encoding: .utf8) ?? ""
        let errorOutput = String(data: try Data(contentsOf: errorURL), encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, standardOutput: output, standardError: errorOutput)
    }
}
