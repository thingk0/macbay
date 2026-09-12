import Foundation
import ArgumentParser
import MacBayKit
import Darwin

struct AdoptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adopt",
        abstract: "Adopt an externally located application into MacBay standard storage and manifest."
    )

    @Argument(help: "Application name, such as Example.app, or an application path.")
    var app: String

    @Flag(name: .long, help: "Force adoption for apps flagged with popup risk.")
    var force = false

    @OptionGroup var options: MutatingOptions

    func run() throws {
        let service = MacBayService()
        let formatter = CommandSupport.formatter(json: options.json)

        // 1. 사전 검사 (Preflight Inspection)
        let progress = TerminalProgress(json: options.json)
        let plan: AdoptPlan
        do {
            plan = try service.planAdopt(appName: app, volumePath: options.volume, progress: progress.update)
            progress.stop()
        } catch {
            progress.stop()
            throw error
        }

        // 2. 검사 결과 평가 및 다음 행동 안내
        switch plan.status {
        case let .blocked(reason, solution):
            if options.json {
                CommandSupport.printFailure(
                    MacBayError.compatibilityBlocked(path: plan.targetURL.path, assessment: plan.compatibility),
                    json: true
                )
                throw ExitCode(1)
            } else {
                print(formatter.formatBlocked(appName: plan.appName, reason: reason, solution: solution))
                throw ExitCode(1)
            }

        case let .alreadyAdopted(details):
            if options.json {
                try CommandSupport.printValue(plan, json: true) { _ in "" }
                return
            } else {
                print(formatter.formatAlreadyManaged(appName: plan.appName, details: details))
                return
            }

        case let .conflict(reason):
            if options.json {
                CommandSupport.printFailure(MacBayError.unsupportedOperation(reason), json: true)
                throw ExitCode(1)
            } else {
                fputs("Error: \(reason)\n", stderr)
                throw ExitCode(1)
            }

        case let .reviewRequired(reasons, _):
            guard force else {
                if options.json {
                    CommandSupport.printFailure(
                        MacBayError.forceRequired(path: plan.targetURL.path, assessment: plan.compatibility),
                        json: true
                    )
                    throw ExitCode(1)
                } else {
                    let cmd = "mb adopt \"\(plan.appName)\" --force"
                    print(formatter.formatReviewRequired(appName: plan.appName, reasons: reasons, commandToProceed: cmd))
                    throw ExitCode(1)
                }
            }

        case .ready:
            break
        }

        // 3. 실행 계획(Plan) 출력
        if !options.json {
            print(formatter.formatAdoptPlan(plan: plan, force: force, dryRun: options.dryRun))
        }

        // 4. --dry-run: 계획만 출력하고 파일 변경 없이 정상 종료
        if options.dryRun {
            if options.json {
                try CommandSupport.printValue(plan, json: true) { _ in "" }
            }
            return
        }

        // 5. 실행 확인
        if options.json {
            guard options.yes else {
                let errPayload = MacBayErrorPayload(
                    code: "configuration_error",
                    message: "Confirmation required to execute adopt for \(plan.appName). Re-run with --yes in non-interactive mode.",
                    details: "Target path: \(plan.targetURL.path), Destination: \(plan.destinationURL.path)"
                )
                if let jsonStr = try? formatter.json(errPayload) {
                    fputs("\(jsonStr)\n", stderr)
                }
                throw ExitCode(1)
            }
        } else {
            if !options.yes {
                print("\nProceed with adoption? [y/N] ", terminator: "")
                guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      answer == "y" || answer == "yes" else {
                    print("Cancelled. No files were changed.")
                    return
                }
            }
        }

        // 6. 실행 및 결과 출력
        let execProgress = TerminalProgress(json: options.json)
        let result: AdoptExecutionResult
        do {
            result = try service.executeAdopt(plan: plan, force: force, progress: execProgress.update)
            execProgress.stop()
        } catch {
            execProgress.stop()
            throw error
        }

        if options.json {
            try CommandSupport.printValue(result, json: true) { _ in "" }
        } else {
            print(formatter.formatAdoptExecutionResult(result))
        }
    }
}
