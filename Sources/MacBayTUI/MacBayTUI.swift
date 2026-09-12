import Foundation
import MacBayKit

public enum MacBayTUI {
    public static func isInteractiveTerminal(
        stdinFD: Int32 = STDIN_FILENO,
        stdoutFD: Int32 = STDOUT_FILENO,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        TerminalController.isInteractiveTerminal(
            stdinFD: stdinFD,
            stdoutFD: stdoutFD,
            environment: environment
        )
    }

    public static func run(service: TUIServiceProtocol = DefaultTUIService()) throws {
        let controller = TerminalController()
        let app = TUIApp(service: service, controller: controller)
        try app.run()
    }
}
