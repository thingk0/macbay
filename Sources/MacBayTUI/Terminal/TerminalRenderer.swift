import Foundation
import MacBayKit

public struct TerminalRenderer {
    // Screens that keep their buttons pinned below a scrollable body.
    private static let confirmFooterHeight = 2
    // Screens that scroll their body and pin only a scroll indicator below it.
    private static let outcomeFooterHeight = 1

    public init() {}

    public func render(state: TUIState, width: Int, height: Int) -> String {
        if width < 80 || height < 24 {
            return renderTooSmall(width: width, height: height)
        }

        var lines: [String] = []

        // 1. Header (lines 0..2)
        lines.append(renderHeader(state: state, width: width))
        lines.append(renderSubheader(state: state, width: width))
        lines.append(String(repeating: "─", count: width))

        // 2. Content area (lines 3 .. height - 3)
        let contentHeight = height - 5
        let contentLines = renderContent(state: state, width: width, height: contentHeight)
        for i in 0..<contentHeight {
            if i < contentLines.count {
                lines.append(contentLines[i])
            } else {
                lines.append("")
            }
        }

        // 3. Footer (lines height-2 .. height-1)
        lines.append(renderStatusLine(state: state, width: width))
        lines.append(renderFooter(state: state, width: width))

        // Every physical row must stay exactly one line long: wrapping would shift the whole frame.
        return lines
            .map { padRight(truncate($0, width: width), width: width) }
            .joined(separator: "\r\n")
    }

    /// Rows the list body can occupy on `screen` in a terminal `terminalHeight` rows tall.
    public func listVisibleRows(for screen: TUIScreen, terminalHeight: Int) -> Int {
        guard terminalHeight >= 24 else { return 1 }
        let contentHeight = terminalHeight - 5
        switch screen {
        case .appMoveList, .appRestoreList, .explorer:
            return max(4, contentHeight - 13)
        case .purgeList, .historyList:
            return max(1, contentHeight - 8)
        case .doctorSummary:
            return max(4, contentHeight - 10)
        default:
            return max(1, contentHeight)
        }
    }

    /// Viewport size and body length for screens that scroll their body while keeping a fixed footer.
    public func scrollableDetailMetrics(state: TUIState, width: Int, height: Int) -> (viewport: Int, total: Int)? {
        guard width >= 80, height >= 24 else { return nil }
        let contentHeight = height - 5
        switch state.currentScreen {
        case .undoPreview(let plan, let report), .undoConfirmation(let plan, let report):
            return (max(1, contentHeight - 2), undoPreviewBody(plan: plan, report: report, confirming: state.currentScreen == .undoConfirmation(plan, report), width: width).count)
        case .undoResult(let report, let error, let attempted):
            return (max(1, contentHeight - 1), undoResultBody(report: report, error: error, attempted: attempted, width: width).count)
        case .xcodePreview(let plan), .xcodeConfirmation(let plan):
            return (max(1, contentHeight - 2), xcodePreviewBody(plan: plan, confirming: state.currentScreen == .xcodeConfirmation(plan), width: width).count)
        case .xcodeResult(let report, let error):
            return (max(1, contentHeight - 1), xcodeResultBody(report: report, error: error, options: state.executedXcodeOptions, width: width).count)
        case .purgePreview(let preview), .purgeConfirmation(let preview):
            return (max(1, contentHeight - 2), purgePreviewBody(preview: preview, confirming: state.currentScreen == .purgeConfirmation(preview), width: width).count)
        case .purgeResult(let report, let error):
            return (max(1, contentHeight - 1), purgeResultBody(report: report, error: error, width: width).count)
        case .batchPreview(let preview), .batchConfirmation(let preview):
            let confirming = state.currentScreen == .batchConfirmation(preview)
            return (max(1, contentHeight - 2), batchPreviewBody(preview: preview, confirming: confirming, riskAccepted: state.batchRiskAccepted, width: width).count)
        case .batchResult(let report):
            return (max(1, contentHeight - 1), batchResultBody(report: report, width: width).count)
        case .recovery(let view):
            return (max(1, contentHeight - 2), recoveryBody(view, width: width).count)
        case .doctorFindingDetail(let finding):
            return (max(1, contentHeight - 1), wrapped(renderDoctorFindingDetail(finding: finding, width: width, height: contentHeight), width: width).count)
        case .riskReview(let candidate):
            let body = riskReviewBody(candidate: candidate, width: width)
            return (max(1, contentHeight - Self.confirmFooterHeight), body.count)
        case .dryRunPreview(let plan):
            let body = dryRunPreviewBody(plan: plan, width: width)
            return (max(1, contentHeight - Self.confirmFooterHeight), body.count)
        case .adoptReview(let plan):
            let body = adoptReviewBody(plan: plan, riskAccepted: state.adoptRiskAccepted, width: width)
            return (max(1, contentHeight - Self.confirmFooterHeight), body.count)
        case .adoptOutcome(let outcome):
            let body = adoptOutcomeBody(outcome: outcome, width: width)
            return (max(1, contentHeight - Self.outcomeFooterHeight), body.count)
        default:
            return nil
        }
    }

    private func renderTooSmall(width: Int, height: Int) -> String {
        var lines = [String](repeating: String(repeating: " ", count: width), count: height)
        let boxWidth = min(50, width - 2)
        let boxHeight = 7
        let startY = max(0, (height - boxHeight) / 2)
        let startX = max(0, (width - boxWidth) / 2)

        let top = "┌" + String(repeating: "─", count: boxWidth - 2) + "┐"
        let bottom = "└" + String(repeating: "─", count: boxWidth - 2) + "┘"
        let title = center("Terminal Window Too Small", width: boxWidth - 2)
        let msg1 = center("MacBay TUI requires at least 80 x 24.", width: boxWidth - 2)
        let msg2 = center("Current: \(width) x \(height)", width: boxWidth - 2)
        let msg3 = center("Please enlarge your window or press 'q'", width: boxWidth - 2)

        let boxLines = [
            top,
            "│" + title + "│",
            "│" + String(repeating: " ", count: boxWidth - 2) + "│",
            "│" + msg1 + "│",
            "│" + msg2 + "│",
            "│" + msg3 + "│",
            bottom
        ]

        for (idx, line) in boxLines.enumerated() {
            let y = startY + idx
            if y < height {
                let padded = String(repeating: " ", count: startX) + line
                lines[y] = padRight(padded, width: width)
            }
        }

        return lines.joined(separator: "\r\n")
    }

    private func renderHeader(state: TUIState, width: Int) -> String {
        let left = "\u{001B}[1;36mMacBay\u{001B}[0m \u{001B}[2mv\(MacBayVersion.current)\u{001B}[0m · Developer Storage Externalizer"
        let leftLen = displayWidth(left)

        let right: String
        if let vol = state.sessionVolumePath {
            let budget = max(12, width - leftLen - 12)
            right = "\u{001B}[2mTarget:\u{001B}[0m \u{001B}[33m\(shortenPath(vol, maxWidth: budget))\u{001B}[0m"
        } else if let def = state.cachedStatus?.defaultVolume {
            right = "\u{001B}[2mDefault:\u{001B}[0m \u{001B}[32m\(def.name)\u{001B}[0m"
        } else {
            right = "\u{001B}[2mTarget: Auto\u{001B}[0m"
        }

        let rightLen = displayWidth(right)
        let spacing = max(1, width - leftLen - rightLen)
        return left + String(repeating: " ", count: spacing) + right
    }

    private func renderSubheader(state: TUIState, width: Int) -> String {
        let breadcrumb: String
        switch state.currentScreen {
        case .historyList: breadcrumb = "Home > History & Undo"
        case .undoPreview: breadcrumb = "Home > History & Undo > Dry-Run Preview"
        case .undoConfirmation: breadcrumb = "Home > History & Undo > Confirm Undo"
        case .undoResult: breadcrumb = "Home > History & Undo > Result"
        case .xcodeOptions: breadcrumb = "Home > Xcode Storage > Options"
        case .xcodePreview: breadcrumb = "Home > Xcode Storage > Preview"
        case .xcodeConfirmation: breadcrumb = "Home > Xcode Storage > Confirm"
        case .xcodeResult: breadcrumb = "Home > Xcode Storage > Results"
        case .purgeList: breadcrumb = "Home > Cache Cleanup"
        case .purgePreview: breadcrumb = "Home > Cache Cleanup > Preview"
        case .purgeConfirmation: breadcrumb = "Home > Cache Cleanup > Confirm Deletion"
        case .purgeResult: breadcrumb = "Home > Cache Cleanup > Results"
        case .home:
            breadcrumb = "\u{001B}[1mHome\u{001B}[0m"
        case .appMoveList:
            breadcrumb = "\u{001B}[2mHome >\u{001B}[0m \u{001B}[1;32mMove Application\u{001B}[0m"
        case .appFilter(let restoring):
            let section = restoring ? "Restore" : "Move"
            breadcrumb = "\u{001B}[2mHome > \(section) >\u{001B}[0m \u{001B}[1;36mFilter Applications\u{001B}[0m"
        case .explorer:
            breadcrumb = "\u{001B}[2mHome >\u{001B}[0m \u{001B}[1;32mExplore Disk Usage\u{001B}[0m"
        case .explorerDetail(let entry):
            breadcrumb = "\u{001B}[2mHome > Explore >\u{001B}[0m \u{001B}[1m\(entry.name)\u{001B}[0m"
        case .riskReview(let cand):
            breadcrumb = "\u{001B}[2mHome > Move >\u{001B}[0m \u{001B}[1;33mRisk Review (\(cand.name))\u{001B}[0m"
        case .volumeSelect(let cand, _):
            breadcrumb = "\u{001B}[2mHome > Move >\u{001B}[0m \u{001B}[1;36mSelect Volume (\(cand.name))\u{001B}[0m"
        case .batchVolumeSelect:
            breadcrumb = "Home > Move > Select Volume (batch)"
        case .batchPreview(let preview):
            breadcrumb = "Home > \(preview.operation.verb) > Batch Preview"
        case .batchConfirmation(let preview):
            breadcrumb = "Home > \(preview.operation.verb) > Confirm Batch"
        case .batchResult(let report):
            breadcrumb = "Home > \(report.operation.verb) > Batch Results"
        case .dryRunPreview(let plan):
            breadcrumb = "\u{001B}[2mHome >\u{001B}[0m \u{001B}[1;36mDry-Run Preview (\(plan.appName))\u{001B}[0m"
        case .mutatingProgress(let op, let app):
            breadcrumb = "\u{001B}[1;33mExecuting \(op.capitalized) (\(app))\u{001B}[0m"
        case .operationResult(let res, let err, _):
            if err != nil {
                breadcrumb = "\u{001B}[1;31mOperation Failed\u{001B}[0m"
            } else {
                breadcrumb = "\u{001B}[1;32mOperation Succeeded (\(res?.name ?? ""))\u{001B}[0m"
            }
        case .appRestoreList:
            breadcrumb = "\u{001B}[2mHome >\u{001B}[0m \u{001B}[1;34mRestore Application\u{001B}[0m"
        case .adoptReview(let plan):
            breadcrumb = "\u{001B}[2mHome > Restore >\u{001B}[0m \u{001B}[1;33mAdoption Review (\(plan.appName))\u{001B}[0m"
        case .adoptOutcome(let outcome):
            if case .failed = outcome.status {
                breadcrumb = "\u{001B}[1;31mAdoption Failed (\(outcome.appName))\u{001B}[0m"
            } else {
                breadcrumb = "\u{001B}[1;32mAdoption Succeeded (\(outcome.appName))\u{001B}[0m"
            }
        case .infoModal(let title, _, _):
            breadcrumb = "\u{001B}[1;33mNotice: \(title)\u{001B}[0m"
        case .recovery:
            breadcrumb = "Home > Diagnosis > Recovery"
        case .doctorSummary:
            breadcrumb = "\u{001B}[2mHome >\u{001B}[0m \u{001B}[1;35mDoctor Diagnosis\u{001B}[0m"
        case .doctorFindingDetail(let finding):
            breadcrumb = "\u{001B}[2mHome > Doctor >\u{001B}[0m \u{001B}[1mFinding: \(finding.name)\u{001B}[0m"
        }
        return breadcrumb
    }

    private func renderStatusLine(state: TUIState, width: Int) -> String {
        if state.quitDeferred {
            return "\u{001B}[1;33m⚠  Quit requested. MacBay exits after the active operation completes.\u{001B}[0m"
        }
        if let err = state.errorMessage {
            return "\u{001B}[1;31mError: \(err)\u{001B}[0m"
        }
        if let notice = state.volumeNotice {
            return "\u{001B}[1;33m⏏ \(notice)\u{001B}[0m"
        }
        if state.isLoading {
            return "\u{001B}[33m⟳ \(state.loadingMessage ?? "Loading…")\u{001B}[0m"
        }
        return String(repeating: "─", count: width)
    }

    private func renderFooter(state: TUIState, width: Int) -> String {
        let text: String
        switch state.currentScreen {
        case .historyList:
            text = "[↑/↓] Scroll [Enter/u] Preview undo [r] Refresh [Esc] Back"
        case .undoPreview, .undoConfirmation:
            text = "[↑/↓] Scroll [←/→/Tab] Button [Enter] Select [Esc] Cancel"
        case .undoResult:
            text = "[↑/↓] Scroll [Enter / Esc] Return to history"
        case .xcodeOptions:
            text = "[↑/↓] Option [←/→/Space] Change [Enter] Preview [r] Refresh [Esc] Back"
        case .xcodePreview, .xcodeConfirmation:
            text = "[↑/↓] Scroll [←/→/Tab] Button [Enter] Select [Esc] Cancel"
        case .xcodeResult:
            text = "[↑/↓] Scroll [Enter / Esc] Return to options for a fresh preview"
        case .purgeList:
            text = "[↑/↓] Move [Space] Toggle [a] All [c] Clear [Enter] Preview [r] Scan [Esc] Back"
        case .purgePreview, .purgeConfirmation:
            text = "[↑/↓] Scroll [←/→/Tab] Button [Enter] Select [Esc] Cancel"
        case .purgeResult:
            text = "[↑/↓] Scroll [Enter / Esc] Return to cache list"
        case .home:
            text = "\u{001B}[1m[↑/↓/j/k]\u{001B}[0m Navigate  \u{001B}[1m[Enter]\u{001B}[0m Select  \u{001B}[1m[r]\u{001B}[0m Refresh  \u{001B}[1m[q]\u{001B}[0m Quit"
        case .appMoveList, .appRestoreList:
            text = state.isSearching
                ? "Type to search · [Enter] Apply · [Esc] Clear · [Backspace] Delete"
                : "[↑/↓] Move [Enter] Select [/] Search [f] Filter [s] Sort [c] Clear [Esc] Back"
        case .appFilter:
            text = "[↑/↓] Condition [←/→] Change value [Enter] Apply [Esc] Cancel"
        case .explorer, .explorerDetail:
            text = state.isSearching
                ? "Type to search · [Enter] Apply · [Esc] Clear · [Backspace] Delete"
                : "[↑/↓] Move [Enter] Open [←] Up [/] Search [s] Sort [c] Clear [m] Move [o] Finder [r] Rescan [Esc] Back"
        case .riskReview:
            text = "\u{001B}[1m[↑/↓]\u{001B}[0m Scroll  \u{001B}[1m[←/→/Tab]\u{001B}[0m Button  \u{001B}[1m[Enter]\u{001B}[0m Select  \u{001B}[1m[Esc]\u{001B}[0m Cancel"
        case .volumeSelect, .batchVolumeSelect:
            text = "\u{001B}[1m[↑/↓]\u{001B}[0m Move  \u{001B}[1m[Enter]\u{001B}[0m Select  \u{001B}[1m[Esc]\u{001B}[0m Cancel"
        case .batchPreview, .batchConfirmation:
            text = "[↑/↓] Scroll [←/→/Tab] Button [Enter] Select [Esc] Cancel"
        case .batchResult:
            text = "[↑/↓] Scroll [Enter / Esc] Return to application list"
        case .dryRunPreview:
            text = "\u{001B}[1m[↑/↓]\u{001B}[0m Scroll  \u{001B}[1m[←/→/Tab]\u{001B}[0m Button  \u{001B}[1m[Enter]\u{001B}[0m Select  \u{001B}[1m[Esc]\u{001B}[0m Cancel"
        case .adoptReview:
            text = "\u{001B}[1m[↑/↓]\u{001B}[0m Scroll  \u{001B}[1m[←/→/Tab]\u{001B}[0m Button  \u{001B}[1m[Enter]\u{001B}[0m Select  \u{001B}[1m[Esc]\u{001B}[0m Cancel"
        case .mutatingProgress:
            text = "\u{001B}[33mOperation in progress. Please wait for completion…\u{001B}[0m"
        case .operationResult, .infoModal:
            text = "\u{001B}[1m[Enter / Esc]\u{001B}[0m Return"
        case .adoptOutcome:
            text = "\u{001B}[1m[Enter / Esc]\u{001B}[0m Return to application list"
        case .doctorSummary:
            text = "\u{001B}[1m[↑/↓/j/k]\u{001B}[0m Navigate  \u{001B}[1m[Enter]\u{001B}[0m View  \u{001B}[1m[r]\u{001B}[0m Re-run  \u{001B}[1m[Esc]\u{001B}[0m Back  \u{001B}[1m[q]\u{001B}[0m Quit"
        case .recovery:
            text = "[↑/↓] Scroll [←/→/Tab] Choose [Enter] Select [Esc] Cancel"
        case .doctorFindingDetail(let finding):
            let action = finding.code == .localDataDetected ? "[p] Compare copies " : (finding.code == .incompleteOperation ? "[b] Review rollback " : "")
            text = action + "[r] Recheck [↑/↓] Scroll [Esc] Back"
        }
        return text
    }

    // MARK: - Content Views

    private func renderContent(state: TUIState, width: Int, height: Int) -> [String] {
        switch state.currentScreen {
        case .historyList:
            return renderHistoryList(state: state, width: width, height: height)
        case .undoPreview(let plan, let report), .undoConfirmation(let plan, let report):
            let confirming = state.currentScreen == .undoConfirmation(plan, report)
            let body = undoPreviewBody(plan: plan, report: report, confirming: confirming, width: width)
            let label = confirming ? "Confirm & Undo" : "Continue to Confirmation"
            let cancel = state.confirmFocusIndex == 0 ? "\u{001B}[7;1m [ Cancel ] \u{001B}[0m" : " [ Cancel ] "
            let execute = state.confirmFocusIndex == 1 ? "\u{001B}[7;1m [ \(label) ] \u{001B}[0m" : " [ \(label) ] "
            return composeDetail(body: body, footer: [scrollIndicator(bodyCount: body.count, viewport: height - 2, scrollOffset: state.detailScrollOffset), "  \(cancel)   \(execute)"], height: height, scrollOffset: state.detailScrollOffset)
        case .undoResult(let report, let error, let attempted):
            let body = undoResultBody(report: report, error: error, attempted: attempted, width: width)
            return composeDetail(body: body, footer: [scrollIndicator(bodyCount: body.count, viewport: height - 1, scrollOffset: state.detailScrollOffset)], height: height, scrollOffset: state.detailScrollOffset)
        case .xcodeOptions:
            return renderXcodeOptions(state: state, width: width)
        case .xcodePreview(let plan), .xcodeConfirmation(let plan):
            let confirming = state.currentScreen == .xcodeConfirmation(plan)
            let body = xcodePreviewBody(plan: plan, confirming: confirming, width: width)
            let label = confirming ? (plan.options.force ? "Force & Execute" : "Confirm & Execute") : "Continue to Confirmation"
            let cancel = state.confirmFocusIndex == 0 ? "\u{001B}[7;1m [ Cancel ] \u{001B}[0m" : " [ Cancel ] "
            let execute = state.confirmFocusIndex == 1 ? "\u{001B}[7;1m [ \(label) ] \u{001B}[0m" : " [ \(label) ] "
            return composeDetail(body: body, footer: [scrollIndicator(bodyCount: body.count, viewport: height - 2, scrollOffset: state.detailScrollOffset), "  \(cancel)   \(execute)"], height: height, scrollOffset: state.detailScrollOffset)
        case .xcodeResult(let report, let error):
            let body = xcodeResultBody(report: report, error: error, options: state.executedXcodeOptions, width: width)
            return composeDetail(body: body, footer: [scrollIndicator(bodyCount: body.count, viewport: height - 1, scrollOffset: state.detailScrollOffset)], height: height, scrollOffset: state.detailScrollOffset)
        case .purgeList:
            return renderPurgeList(state: state, width: width, height: height)
        case .purgePreview(let preview), .purgeConfirmation(let preview):
            let confirming = state.currentScreen == .purgeConfirmation(preview)
            let body = purgePreviewBody(preview: preview, confirming: confirming, width: width)
            let cancel = state.confirmFocusIndex == 0 ? "\u{001B}[7;1m [ Cancel ] \u{001B}[0m" : " [ Cancel ] "
            let label = confirming ? "Confirm & Purge" : "Continue to Confirmation"
            let proceed = state.confirmFocusIndex == 1 ? "\u{001B}[7;1m [ \(label) ] \u{001B}[0m" : " [ \(label) ] "
            return composeDetail(body: body, footer: [scrollIndicator(bodyCount: body.count, viewport: height - 2, scrollOffset: state.detailScrollOffset), "  \(cancel)   \(proceed)"], height: height, scrollOffset: state.detailScrollOffset)
        case .purgeResult(let report, let error):
            let body = purgeResultBody(report: report, error: error, width: width)
            return composeDetail(body: body, footer: [scrollIndicator(bodyCount: body.count, viewport: height - 1, scrollOffset: state.detailScrollOffset)], height: height, scrollOffset: state.detailScrollOffset)
        case .home:
            return renderHome(state: state, width: width, height: height)
        case .appMoveList:
            return renderAppMoveList(state: state, width: width, height: height)
        case .appFilter(let restoring):
            return renderAppFilter(state: state, restoring: restoring, width: width, height: height)
        case .explorer:
            return renderExplorer(state: state, width: width, height: height)
        case .explorerDetail(let entry):
            let body = explorerDetailBody(state: state, entry: entry, width: width)
            let viewport = max(1, height - Self.outcomeFooterHeight)
            let footer = [scrollIndicator(bodyCount: body.count, viewport: viewport, scrollOffset: state.detailScrollOffset)]
            return composeDetail(body: body, footer: footer, height: height, scrollOffset: state.detailScrollOffset)
        case .riskReview(let candidate):
            let body = riskReviewBody(candidate: candidate, width: width)
            let viewport = max(1, height - Self.confirmFooterHeight)
            let footer = riskReviewFooter(state: state, bodyCount: body.count, viewport: viewport)
            return composeDetail(body: body, footer: footer, height: height, scrollOffset: state.detailScrollOffset)
        case .volumeSelect(let candidate, _):
            return renderVolumeSelect(state: state, subject: candidate.name, width: width)
        case .batchVolumeSelect:
            return renderVolumeSelect(state: state, subject: "\(state.selectedMovePaths.count) applications", width: width)
        case .batchPreview(let preview), .batchConfirmation(let preview):
            let confirming = state.currentScreen == .batchConfirmation(preview)
            let body = batchPreviewBody(preview: preview, confirming: confirming, riskAccepted: state.batchRiskAccepted, width: width)
            let label: String
            if confirming {
                label = "Confirm & \(preview.operation.verb) \(preview.included.count) App(s)"
            } else {
                switch batchConfirmAction(preview: preview, riskAccepted: state.batchRiskAccepted) {
                case .unavailable: label = "Back to List"
                case .acceptRisk: label = "Accept Risk for \(preview.riskItems.count) App(s)"
                case .continueToConfirmation: label = "Continue to Confirmation"
                }
            }
            let cancel = state.confirmFocusIndex == 0 ? "\u{001B}[7;1m [ Cancel ] \u{001B}[0m" : " [ Cancel ] "
            let proceed = state.confirmFocusIndex == 1 ? "\u{001B}[7;1m [ \(label) ] \u{001B}[0m" : " [ \(label) ] "
            return composeDetail(body: body, footer: [scrollIndicator(bodyCount: body.count, viewport: height - 2, scrollOffset: state.detailScrollOffset), "  \(cancel)   \(proceed)"], height: height, scrollOffset: state.detailScrollOffset)
        case .batchResult(let report):
            let body = batchResultBody(report: report, width: width)
            return composeDetail(body: body, footer: [scrollIndicator(bodyCount: body.count, viewport: height - 1, scrollOffset: state.detailScrollOffset)], height: height, scrollOffset: state.detailScrollOffset)
        case .dryRunPreview(let plan):
            let body = dryRunPreviewBody(plan: plan, width: width)
            let viewport = max(1, height - Self.confirmFooterHeight)
            let footer = dryRunPreviewFooter(state: state, plan: plan, bodyCount: body.count, viewport: viewport)
            return composeDetail(body: body, footer: footer, height: height, scrollOffset: state.detailScrollOffset)
        case .mutatingProgress(let op, let app):
            return renderMutatingProgress(state: state, op: op, app: app, width: width, height: height)
        case .operationResult(let res, let err, let details):
            return renderOperationResult(result: res, error: err, errorDetails: details, width: width, height: height)
        case .appRestoreList:
            return renderAppRestoreList(state: state, width: width, height: height)
        case .adoptReview(let plan):
            let body = adoptReviewBody(plan: plan, riskAccepted: state.adoptRiskAccepted, width: width)
            let viewport = max(1, height - Self.confirmFooterHeight)
            let footer = adoptReviewFooter(state: state, plan: plan, bodyCount: body.count, viewport: viewport)
            return composeDetail(body: body, footer: footer, height: height, scrollOffset: state.detailScrollOffset)
        case .adoptOutcome(let outcome):
            let body = adoptOutcomeBody(outcome: outcome, width: width)
            let viewport = max(1, height - Self.outcomeFooterHeight)
            let footer = [scrollIndicator(bodyCount: body.count, viewport: viewport, scrollOffset: state.detailScrollOffset)]
            return composeDetail(body: body, footer: footer, height: height, scrollOffset: state.detailScrollOffset)
        case .infoModal(_, let message, let guidance):
            return renderInfoModal(message: message, guidance: guidance, width: width, height: height)
        case .doctorSummary:
            return renderDoctorSummary(state: state, width: width, height: height)
        case .doctorFindingDetail(let finding):
            let body = wrapped(renderDoctorFindingDetail(finding: finding, width: width, height: height), width: width)
            return composeDetail(body: body, footer: [scrollIndicator(bodyCount: body.count, viewport: height - 1, scrollOffset: state.detailScrollOffset)], height: height, scrollOffset: state.detailScrollOffset)
        case .recovery(let view):
            return renderRecovery(state: state, view: view, width: width, height: height)
        }
    }

    // MARK: - History and Undo Views

    private func historyTime(_ timestamp: String) -> String {
        let base = timestamp.replacingOccurrences(of: "T", with: " ")
        return String(base.prefix(16))
    }

    private func historyEntryLabel(_ entry: HistoryEntry) -> String {
        "\(entry.command) \(entry.subject) (\(historyTime(entry.timestamp)))"
    }

    private func historyUndoExplanation(state: TUIState, selected: HistoryEntry) -> String {
        if let plan = state.undoPlan {
            if selected == plan.entry {
                return "Eligible: this is the latest successful operation. Enter previews the dry run."
            }
            if selected.outcome == .failure {
                return "Not undoable: it failed and changed nothing."
            }
            return "Not undoable: only the latest successful operation can be undone."
        }
        if selected.outcome == .failure {
            return "Not undoable: it failed and changed nothing."
        }
        if let first = state.historyEntries.first(where: { $0.outcome != .failure }), first == selected {
            return state.undoRefusal ?? "Not undoable."
        }
        return "Not undoable: only the latest successful operation is considered."
    }

    private func renderHistoryList(state: TUIState, width: Int, height: Int) -> [String] {
        if state.historyLoading && !state.historyLoaded { return ["Loading operation history…"] }
        guard state.historyLoaded else { return ["History unavailable. Press r to retry."] }
        let entries = state.historyEntries
        var lines = ["Recent operations: \(entries.count) (newest first) · Only the latest dock/move can be undone"]
        var eligibility: [String]
        if let plan = state.undoPlan {
            eligibility = wrapped(["Can undo: \(historyEntryLabel(plan.entry)) by running \(plan.command)"], width: width)
        } else {
            eligibility = wrapped(["Cannot undo: \(state.undoRefusal ?? "unknown reason")"], width: width)
        }
        if eligibility.count > 3 {
            eligibility = Array(eligibility.prefix(2)) + [truncate(eligibility[2] + "…", width: width - 2)]
        }
        lines += eligibility
        while lines.count < 4 { lines.append("") }
        lines.append("")
        guard !entries.isEmpty else {
            return lines + ["No recorded operations yet.", "Operations you run with MacBay appear here."]
        }
        let capacity = max(1, height - 8)
        let offset = min(state.historyScrollOffset, max(0, entries.count - capacity))
        let eligibleIndex = state.undoEntryIndex
        for index in offset..<min(entries.count, offset + capacity) {
            let entry = entries[index]
            let outcome: String
            switch entry.outcome {
            case .success: outcome = "✓ success"
            case .partial: outcome = "~ partial"
            case .failure: outcome = "✗ failed "
            }
            let mark = index == eligibleIndex ? "↩" : " "
            let label = "\(mark) \(outcome) \(historyTime(entry.timestamp))  \(entry.command)  \(entry.subject)"
            let clipped = truncate(label, width: width - 4)
            lines.append(index == state.historyIndex ? "\u{001B}[7;1m> \(clipped)\u{001B}[0m" : "  " + clipped)
        }
        while lines.count < 5 + capacity { lines.append("") }
        lines.append("Entries \(offset + 1)-\(min(entries.count, offset + capacity)) of \(entries.count) · ↩ marks the undoable entry")
        if entries.indices.contains(state.historyIndex) {
            let selected = entries[state.historyIndex]
            lines.append(truncate("Detail: " + (selected.detail ?? "none"), width: width - 2))
            lines.append(truncate(historyUndoExplanation(state: state, selected: selected), width: width - 2))
        }
        return lines
    }

    private func undoPreviewBody(plan: UndoPlan, report: UndoReport, confirming: Bool, width: Int) -> [String] {
        var lines = [
            confirming ? "Confirm undo" : "Undo · Dry-run preview",
            "Operation: \(historyEntryLabel(plan.entry))",
            "Reversed with: \(plan.command)",
            confirming ? "Confirm & Undo changes your files. Execution rechecks history and current state."
                       : "The dry run changed nothing. Continue to a separate confirmation.",
            ""
        ]
        lines += migrationLines(report.result)
        return wrapped(lines, width: width)
    }

    private func migrationLines(_ result: MigrationResult) -> [String] {
        var lines = ["\(result.operation.capitalized) \(result.name)",
                     "  From: \(result.sourcePath)", "  To: \(result.destinationPath)",
                     "  Size: \(OutputFormatter.humanBytes(result.sizeBytes))"]
        lines += result.messages.map { "  " + $0 }
        return lines
    }

    private func undoResultBody(report: UndoReport?, error: String?, attempted: Bool, width: Int) -> [String] {
        guard let report else {
            return wrapped([
                attempted ? "Undo failed" : "Nothing was undone",
                error ?? "Unknown error",
                "",
                attempted ? "Review the history; the operation may be partly applied." : "No files were changed. Return to history and review the current state."
            ], width: width)
        }
        var lines = ["Undo finished",
                     "Reversed: \(report.entry.command) \(report.entry.subject) (\(historyTime(report.entry.timestamp)))",
                     "Ran: \(report.command)", ""]
        lines += migrationLines(report.result)
        lines += ["", "The undo was recorded in history and cannot itself be undone."]
        return wrapped(lines, width: width)
    }

    // MARK: - Xcode Storage Views

    private func renderXcodeOptions(state: TUIState, width: Int) -> [String] {
        if state.xcodeEnvironmentLoading { return ["Checking Xcode and destination volumes…"] }
        guard state.xcodeEnvironmentLoaded else { return ["Xcode storage unavailable. Press r to retry."] }
        let options = state.xcodeOptions
        let available = state.xcodeVolumes.contains { $0.path == state.xcodeVolumePath }
        var lines = [
            "Standard workflow (always included):",
            "  Externalize iOS DeviceSupport and Archives; delete unavailable simulators.",
            "",
            state.xcodeRunning == true ? "Xcode is running: quit Xcode or explicitly enable Force below." : "Xcode is not running.",
            available ? "Destination is an eligible external APFS volume." : "Destination unavailable: connect a drive, refresh and select its volume.",
            ""
        ]
        let fields = [
            "Destination: " + (state.xcodeVolumePath ?? "Select a volume with Left/Right"),
            "[\(options.externalizeDerivedData ? "x" : " ")] Externalize DerivedData (advanced)",
            "[\(options.cleanDerivedData ? "x" : " ")] Clean DerivedData build caches",
            "[\(options.cleanCaches ? "x" : " ")] Clean CoreSimulator and Xcode caches",
            "[\(options.force ? "x" : " ")] Force while Xcode runs (explicit risk acceptance)"
        ]
        for (index, field) in fields.enumerated() {
            lines.append(index == state.xcodeFieldIndex ? "\u{001B}[7;1m> \(field)\u{001B}[0m" : "  " + field)
        }
        lines += ["", options.force ? "Force enabled: running builds may lose data. Quit Xcode when possible." : "Force is off. Running Xcode blocks preview and execution.",
                  "Externalization and cleanup can both be selected for DerivedData.",
                  "Cleanup deletes generated data and cannot be undone.",
                  "Enter opens a read-only preview, then a separate confirmation."]
        return lines
    }

    private func xcodePreviewBody(plan: XcodeStoragePlan, confirming: Bool, width: Int) -> [String] {
        var lines = [
            confirming ? "Confirm selected Xcode storage actions" : "Xcode storage · Read-only preview",
            "Destination: \(plan.volumePath)",
            "Copy estimate: \(OutputFormatter.humanBytes(plan.requiredBytes)) · Available: \(OutputFormatter.humanBytes(plan.availableBytes))",
            "Cache cleanup estimate: \(OutputFormatter.humanBytes(plan.report.freedBytes))",
            "Force: \(plan.options.force ? "explicitly enabled" : "off") · Xcode: \(plan.xcodeRunning ? "running" : "not running")",
            confirming ? "Execution rechecks these conditions. Changes require a fresh preview." : "No files or simulator devices have been changed.",
            "Cleanup deletes generated data and unavailable simulators permanently.",
            ""
        ]
        if plan.options.force { lines += ["Force accepted: running builds may lose data.", ""] }
        let migrations = [
            ("DeviceSupport", plan.options.externalizeDeviceSupport, plan.report.deviceSupport),
            ("Archives", plan.options.externalizeArchives, plan.report.archives),
            ("DerivedData", plan.options.externalizeDerivedData, plan.report.derivedData)
        ]
        for (name, selected, result) in migrations where selected {
            lines.append("Externalize \(name):")
            if let result {
                lines += ["  From: \(result.sourcePath)", "  To: \(result.destinationPath)", "  Size: \(OutputFormatter.humanBytes(result.sizeBytes))"]
                lines += result.messages.map { "  " + $0 }
            } else {
                lines.append("  Not present; no migration needed.")
            }
        }
        lines += ["Unavailable simulators: \(plan.unavailableSimulatorIDs.count) device(s)"]
        lines += plan.unavailableSimulatorIDs.map { "  " + $0 }
        for summary in [plan.report.derivedDataCleanup, plan.report.cacheCleanup].compactMap({ $0 }) {
            lines += [summary.command, "  " + summary.output]
        }
        return wrapped(lines, width: width)
    }

    private func xcodeResultBody(report: XcodeDoctorReport?, error: String?, options: XcodeDoctorOptions?, width: Int) -> [String] {
        guard let report else {
            return wrapped(["Xcode storage stopped", error ?? "Unknown error", "", "Return to options and review a fresh preview."], width: width)
        }
        var lines = [report.hasFailures ? "Xcode storage finished with failures" : "Xcode storage finished",
                     "Cache storage reclaimed: \(OutputFormatter.humanBytes(report.freedBytes))", ""]
        for (name, result) in [("DeviceSupport", report.deviceSupport), ("Archives", report.archives), ("DerivedData", report.derivedData)] {
            if let result {
                lines += ["Completed: \(name) · \(OutputFormatter.humanBytes(result.sizeBytes))",
                          "  \(result.sourcePath)", "  -> \(result.destinationPath)"]
                lines += result.messages
            }
        }
        for summary in [report.simulatorCleanup, report.derivedDataCleanup, report.cacheCleanup].compactMap({ $0 }) {
            lines += ["\(summary.succeeded ? "Completed" : "Failed"): \(summary.command)", summary.output]
        }
        for failure in report.failedActions { lines += ["Failed: \(failure.action)", failure.reason] }
        if report.deviceSupport == nil && !report.failedActions.contains(where: { $0.action.contains("DeviceSupport") }) {
            lines.append("DeviceSupport: not present; no migration needed.")
        }
        if report.archives == nil && !report.failedActions.contains(where: { $0.action.contains("Archives") }) {
            lines.append("Archives: not present; no migration needed.")
        }
        if options?.externalizeDerivedData == true, report.derivedData == nil,
           !report.failedActions.contains(where: { $0.action.contains("DerivedData") }) {
            lines.append("DerivedData: not present; no migration needed.")
        }
        return wrapped(lines, width: width)
    }

    // MARK: - Batch Views

    public enum BatchConfirmAction: Equatable {
        case unavailable
        case acceptRisk
        case continueToConfirmation
    }

    /// What the second button on a batch preview does. Input handling and rendering share this.
    public func batchConfirmAction(preview: BatchPreview, riskAccepted: Bool) -> BatchConfirmAction {
        guard preview.canProceed else { return .unavailable }
        if !preview.riskItems.isEmpty && !riskAccepted { return .acceptRisk }
        return .continueToConfirmation
    }

    /// The rule above a list's detail pane, carrying the batch selection and its keys.
    private func batchSelectionRule(count: Int, bytes: UInt64, outsideFilter: Int, width: Int) -> String {
        let text: String
        if count == 0 {
            text = " [Space] Select · [a] Select shown · Enter opens one app "
        } else {
            let hidden = outsideFilter > 0 ? " · \(outsideFilter) outside filter" : ""
            text = " Batch: \(count) apps · \(OutputFormatter.humanBytes(bytes))\(hidden) · [Enter] Preview · [x] Clear "
        }
        let ruleWidth = min(width - 4, max(70, displayWidth(text) + 4))
        return "  ──" + text + String(repeating: "─", count: max(0, ruleWidth - 2 - displayWidth(text)))
    }

    private func batchPreviewBody(preview: BatchPreview, confirming: Bool, riskAccepted: Bool, width: Int) -> [String] {
        let operation = preview.operation
        let included = preview.included
        var lines = [
            confirming
                ? "Confirm batch \(operation.verb.lowercased()) · \(included.count) application(s)"
                : "Batch \(operation.verb.lowercased()) preview · \(included.count) of \(preview.items.count) application(s) · Preview only",
            operation == .dock
                ? "Destination volume: \(preview.volumePath ?? "Auto")"
                : "Destination: internal /Applications",
            "Required: \(OutputFormatter.humanBytes(preview.requiredBytes)) · Free: "
                + (preview.availableBytes.map { OutputFormatter.humanBytes($0) } ?? "unknown; each app is checked before it runs")
        ]
        if preview.shortfallBytes > 0 {
            lines.append("Not enough space: \(OutputFormatter.humanBytes(preview.shortfallBytes)) short. Deselect apps and preview again.")
        }
        if included.isEmpty {
            lines.append("No selected application can run. Review the exclusions below.")
        }
        lines.append("Rule: apps run one at a time in this order.")
        lines.append("MacBay stops at the first failure and does not start the rest.")
        lines.append(confirming
            ? "Confirm & \(operation.verb) changes files; each app is rechecked against this preview."
            : "No files have changed. Continue to a separate confirmation.")
        let risky = preview.riskItems
        if !risky.isEmpty {
            lines.append(riskAccepted
                ? "Risk accepted (--force) for: \(risky.map(\.appName).joined(separator: ", "))"
                : "\(risky.count) app(s) need explicit risk acceptance (--force) before continuing.")
        }

        lines += ["", "Included (\(included.count))"]
        for (index, item) in included.enumerated() {
            guard let result = item.preview else { continue }
            let grade: String
            switch item.compatibility?.grade {
            case .safe: grade = "Safe"
            case .popupRisk: grade = "Review"
            case .blocked: grade = "Blocked"
            case .none: grade = operation == .dock ? "Unknown" : "Managed"
            }
            lines.append("\(index + 1). \(item.appName) · \(grade) · \(OutputFormatter.humanBytes(result.sizeBytes))")
            lines.append("   To: \(result.destinationPath)")
            if item.requiresRiskAcceptance, let reasons = item.compatibility?.reasons, !reasons.isEmpty {
                lines.append("   Risk: \(reasons.joined(separator: "; "))")
            }
        }
        let excluded = preview.excluded
        if !excluded.isEmpty {
            lines += ["", "Excluded (\(excluded.count)) · these apps are not run"]
            for item in excluded {
                lines.append("- \(item.appName): \(item.exclusion ?? "Unavailable")")
            }
        }
        return wrapped(lines, width: width)
    }

    private func batchResultBody(report: BatchReport, width: Int) -> [String] {
        let operation = report.operation
        let headline: String
        if report.allSucceeded {
            headline = "All \(report.results.count) application(s) \(operation.pastTense)"
        } else if report.failedCount > 0 {
            headline = "Batch \(operation.verb.lowercased()) stopped after a failure"
        } else {
            headline = "Batch \(operation.verb.lowercased()) stopped before finishing"
        }
        var lines = [
            headline,
            "Succeeded: \(report.succeededCount) · Failed: \(report.failedCount) · Not started: \(report.notStartedCount)"
                + (report.excluded.isEmpty ? "" : " · Excluded: \(report.excluded.count)"),
            ""
        ]
        for result in report.results {
            switch result.status {
            case .succeeded(let migration):
                lines.append("OK      \(result.appName) · \(OutputFormatter.humanBytes(migration.sizeBytes))")
                lines.append("        \(migration.destinationPath)")
            case .failed(let message, let details):
                lines.append("FAILED  \(result.appName)")
                lines.append("        \(message)")
                if let details { lines.append("        \(details)") }
            case .notStarted:
                lines.append("SKIPPED \(result.appName) · not started")
            }
        }
        for item in report.excluded {
            lines.append("EXCLUDED \(item.appName) · \(item.exclusion ?? "Unavailable")")
        }
        if report.failedCount > 0 {
            lines += ["", "Run mb doctor to check links and records before retrying failed apps."]
        }
        lines.append("Each executed app is recorded in mb history.")
        return wrapped(lines, width: width)
    }

    // MARK: - Cache Cleanup Views

    private func renderPurgeList(state: TUIState, width: Int, height: Int) -> [String] {
        let eligible = state.purgeItems.filter { !$0.isRunning }
        let skipped = state.purgeItems.filter(\.isRunning)
        let selected = state.selectedPurgeItems
        var lines = [
            "Reclaimable: \(OutputFormatter.humanBytes(eligible.reduce(0) { $0 + $1.sizeBytes })) · \(eligible.count) target(s)",
            "Selected: \(selected.count) · \(OutputFormatter.humanBytes(selected.reduce(0) { $0 + $1.sizeBytes })) (estimated)",
            "Skipped: \(skipped.count) · running applications; close them and rescan.",
            ""
        ]
        if state.purgeLoading { return lines + ["Scanning purgeable caches…"] }
        if !state.purgeLoaded { return lines + ["Cache scan unavailable. Press r to retry."] }
        guard !state.purgeItems.isEmpty else {
            return lines + ["No purgeable caches found.", "Browsing and cancellation make no changes."]
        }
        let rows = state.purgeRows
        let capacity = max(1, height - 8)
        let offset = min(state.purgeListScrollOffset, max(0, rows.count - capacity))
        for index in offset..<min(rows.count, offset + capacity) {
            let row = rows[index]
            let ids = Set(row.eligibleItems.map(\.id))
            let mark = ids.isEmpty ? "-" : (ids.isSubset(of: state.selectedPurgeIDs) ? "x" : (ids.isDisjoint(with: state.selectedPurgeIDs) ? " " : "~"))
            let label: String
            switch row {
            case .application(let group):
                let bytes = row.eligibleItems.reduce(UInt64(0)) { $0 + $1.sizeBytes }
                label = "[\(mark)] \(group.appName) · \(OutputFormatter.humanBytes(bytes)) · \(group.items.count) target(s)"
            case .target(let item):
                label = "  [\(mark)] \(URL(fileURLWithPath: item.path).lastPathComponent) · \(OutputFormatter.humanBytes(item.sizeBytes))"
                    + (item.isRunning ? " [Skipped: running]" : "")
            }
            lines.append(index == state.purgeListIndex ? "\u{001B}[7;1m> \(label)\u{001B}[0m" : "  " + label)
        }
        while lines.count < 4 + capacity { lines.append("") }
        lines.append("Rows \(offset + 1)-\(min(rows.count, offset + capacity)) of \(rows.count) · Space toggles an app or target")
        if rows.indices.contains(state.purgeListIndex) {
            switch rows[state.purgeListIndex] {
            case .application(let group):
                lines += ["App: \(group.appName)", "Space selects this app's eligible caches."]
            case .target(let item):
                lines += ["Path: \(shortenPath(item.path, maxWidth: width - 6))", "Type: \(item.category.displayName)"]
            }
        }
        lines.append("No files are removed until the separate confirmation.")
        return lines
    }

    private func purgePreviewBody(preview: PurgePreview, confirming: Bool, width: Int) -> [String] {
        var lines = [
            confirming ? "Confirm cache deletion" : "Selected cache targets · Preview only",
            "Selected: \(preview.items.count) · Estimated reclaimable: \(OutputFormatter.humanBytes(preview.sizeBytes))",
            confirming ? "Confirm & Purge removes cache contents. This cannot be undone." : "No files have been removed. Continue to a separate confirmation.",
            "Running applications are skipped; execution checks their status again.",
            ""
        ]
        for group in PurgeAppGroup.group(items: preview.items) {
            lines.append("App: \(group.appName) · \(OutputFormatter.humanBytes(group.totalSizeBytes))")
            for item in group.items {
                lines.append("  \(item.category.displayName) · \(OutputFormatter.humanBytes(item.sizeBytes))")
                lines.append("  \(item.path)")
            }
        }
        if !preview.skippedItems.isEmpty {
            lines += ["", "Skipped: \(preview.skippedItems.count) target(s) belonging to running applications"]
            for item in preview.skippedItems { lines += ["  \(item.appName): \(item.path)"] }
        }
        return wrapped(lines, width: width)
    }

    private func purgeResultBody(report: PurgeReport?, error: String?, width: Int) -> [String] {
        guard let report else { return wrapped(["Cache cleanup failed", error ?? "Unknown error"], width: width) }
        var lines = [
            report.failedItems.isEmpty ? "Cache cleanup finished" : "Cache cleanup finished with failures",
            "Reclaimed: \(OutputFormatter.humanBytes(report.totalReclaimedBytes))",
            "Purged: \(report.purgedItems.count) · Skipped: \(report.skippedItems.count) · Failures: \(report.failedItems.count)",
            ""
        ]
        for item in report.purgedItems {
            lines += ["Purged: \(item.appName) · \(OutputFormatter.humanBytes(item.sizeBytes))", "  \(item.path)"]
        }
        for item in report.skippedItems {
            lines += ["Skipped: \(item.appName) · application is running", "  \(item.path)"]
        }
        for failure in report.failedItems {
            lines += ["Failed: \(failure.appName)", "  \(failure.path)", "  \(failure.reason)"]
        }
        lines += report.messages
        return wrapped(lines, width: width)
    }

    // MARK: - Home View

    private func renderHome(state: TUIState, width: Int, height: Int) -> [String] {
        var lines: [String] = []

        lines.append("\u{001B}[1mStorage Overview\u{001B}[0m")

        if let status = state.cachedStatus {
            // Internal Volume
            let iv = status.internalVolume
            let ivRatio = iv.totalBytes > 0 ? Double(iv.usedBytes) / Double(iv.totalBytes) : 0
            lines.append("  \u{001B}[1mInternal\u{001B}[0m · \(iv.name) (\(iv.path))")
            lines.append("  \(makeProgressBar(ratio: ivRatio, width: 24)) \(Int(ivRatio * 100))%  Used: \(OutputFormatter.humanBytes(iv.usedBytes)) / Avail: \(OutputFormatter.humanBytes(iv.availableBytes)) (Total: \(OutputFormatter.humanBytes(iv.totalBytes)))")

            lines.append("")

            // External Volumes
            if status.externalVolumes.isEmpty {
                lines.append("  \u{001B}[33mExternal\u{001B}[0m · None detected (Connect an APFS drive to externalize applications)")
            } else {
                for ev in status.externalVolumes {
                    let evRatio = ev.totalBytes > 0 ? Double(ev.usedBytes) / Double(ev.totalBytes) : 0
                    lines.append("  \u{001B}[1mExternal\u{001B}[0m · \(ev.name) (\(ev.path))")
                    lines.append("  \(makeProgressBar(ratio: evRatio, width: 24)) \(Int(evRatio * 100))%  Used: \(OutputFormatter.humanBytes(ev.usedBytes)) / Avail: \(OutputFormatter.humanBytes(ev.availableBytes)) (Total: \(OutputFormatter.humanBytes(ev.totalBytes)))")
                }
            }

            lines.append("")
            let count = status.dockedItems.filter { $0.kind == .application }.count
            lines.append("  \u{001B}[1mManaged Applications:\u{001B}[0m \u{001B}[32m\(count)\u{001B}[0m apps docked on external storage")

            if !status.warnings.isEmpty {
                lines.append("  \u{001B}[33mWarnings:\u{001B}[0m \(status.warnings.count) volume warning(s) reported")
            }
        } else {
            lines.append("  Loading storage status…")
        }

        lines.append("")
        lines.append("\u{001B}[1mActions\u{001B}[0m")

        let menuOptions = [
            ("Move Application", "Move internal apps to external APFS storage (dock)"),
            ("Explore Disk Usage", "Browse folders by disk usage and move large items out"),
            ("Restore Application", "Restore external apps back to /Applications (undock)"),
            ("Diagnosis", "Run doctor checks on links, records, and volume health"),
            ("Cache Cleanup", "Select and purge disposable caches (purge)"),
            ("Xcode Storage", "Externalize Xcode data and select cleanup options"),
            ("History & Undo", "Review recent operations and undo the latest dock or move"),
            ("Quit", "Exit MacBay TUI")
        ]

        // Keep every action visible even with multiple external volumes at 80×24.
        if lines.count + menuOptions.count > height {
            lines = Array(lines.prefix(max(0, height - menuOptions.count - 2)))
            lines.append("")
            lines.append("\u{001B}[1mActions\u{001B}[0m")
        }
        for (idx, item) in menuOptions.enumerated() {
            let isSelected = idx == state.homeMenuIndex
            let prefix = isSelected ? "\u{001B}[1;36m ➜ " : "   "
            let title = isSelected ? "\u{001B}[1;36m\(item.0)\u{001B}[0m" : "\u{001B}[1m\(item.0)\u{001B}[0m"
            let desc = "\u{001B}[2m— \(item.1)\u{001B}[0m"
            lines.append("\(prefix)\(title) \(desc)")
        }

        return lines
    }

    /// Where a move would go right now, so connect/disconnect changes are visible on the list.
    private func moveDestinationLine(state: TUIState) -> String {
        guard state.statusLoaded else { return "" }
        let volumes = state.eligibleVolumesList
        if let session = state.sessionVolumePath {
            return "  \u{001B}[2mDestination:\u{001B}[0m \(session) (this session)"
        }
        if let def = state.cachedStatus?.defaultVolume {
            if let mounted = def.mountedPath {
                return "  \u{001B}[2mDestination:\u{001B}[0m \(def.name) at \(mounted) (default)"
            }
            return "  \u{001B}[33m⚠ Default volume \(def.name) is not connected. Connect it or set another default.\u{001B}[0m"
        }
        switch volumes.count {
        case 0: return "  \u{001B}[33m⚠ No external APFS volume connected. Connect one to move apps.\u{001B}[0m"
        case 1: return "  \u{001B}[2mDestination:\u{001B}[0m \(volumes[0].name) at \(volumes[0].path)"
        default: return "  \u{001B}[2mDestination:\u{001B}[0m chosen on Enter (\(volumes.count) volumes connected)"
        }
    }

    private func renderListSearch(query: String, editing: Bool, filter: String, sort: String, count: Int) -> [String] {
        let field = query.isEmpty ? (editing ? "Type an app name" : "Search apps") : query
        let hint = editing ? "▏  [Enter] Apply · [Esc] Clear" : "  [/] Search"
        let color = editing ? "\u{001B}[1;36m" : "\u{001B}[1m"
        return [
            "",
            "  \(color)Search  [ \(field) ]\u{001B}[0m\(hint)",
            "  \u{001B}[2m[f] Filter: \(filter)   [s] Sort: \(sort)   · \(count) apps\u{001B}[0m",
            ""
        ]
    }

    private func renderAppFilter(state: TUIState, restoring: Bool, width: Int, height: Int) -> [String] {
        let section = restoring ? "Restore" : "Move"
        let statusLabel: String
        let sizeLabel: String
        if restoring {
            statusLabel = state.restoreFilterStatusDraft.label
            sizeLabel = state.restoreFilterSizeDraft.label
        } else {
            statusLabel = state.moveFilterStatusDraft.label
            sizeLabel = state.moveFilterSizeDraft.label
        }

        func row(_ title: String, _ value: String, selected: Bool) -> String {
            let marker = selected ? "\u{001B}[1;36m➜\u{001B}[0m" : " "
            let titleColor = selected ? "\u{001B}[1;36m" : "\u{001B}[1m"
            return "  \(marker) \(titleColor)\(title):\u{001B}[0m \(value)"
        }

        let currentStatus: String
        let currentSize: String
        if restoring {
            currentStatus = state.restoreStatusFilter.label
            currentSize = state.restoreSizeFilter.label
        } else {
            currentStatus = state.moveStatusFilter.label
            currentSize = state.moveSizeFilter.label
        }
        let search = restoring
            ? (state.restoreSearch.isEmpty ? "All names" : state.restoreSearch)
            : (state.moveSearch.isEmpty ? "All names" : state.moveSearch)

        return [
            "",
            "  \u{001B}[1mFilter \(section) Applications\u{001B}[0m",
            "  \u{001B}[2mChoose a condition, then use ←/→ to change its value.\u{001B}[0m",
            "",
            row("Status", statusLabel, selected: state.filterFieldIndex == 0),
            row("Size", sizeLabel, selected: state.filterFieldIndex == 1),
            "",
            "  \u{001B}[2mCurrent filter: \(currentStatus) · \(currentSize)\u{001B}[0m",
            "  \u{001B}[2mName search: \(search)\u{001B}[0m",
            "",
            "  \u{001B}[1m[Enter]\u{001B}[0m Apply filter    \u{001B}[1m[Esc]\u{001B}[0m Cancel",
            ""
        ]
    }

    // MARK: - App Move List View

    private func renderExplorer(state: TUIState, width: Int, height: Int) -> [String] {
        var lines: [String] = []
        if let status = state.cachedStatus {
            let iv = status.internalVolume
            let ivRatio = iv.totalBytes > 0 ? Double(iv.usedBytes) / Double(iv.totalBytes) : 0
            lines.append("  \u{001B}[1mInternal\u{001B}[0m \(Int(ivRatio * 100))% used (\(OutputFormatter.humanBytes(iv.usedBytes)) / \(OutputFormatter.humanBytes(iv.totalBytes))) · avail \(OutputFormatter.humanBytes(iv.availableBytes))")
            if let external = status.externalVolumes.first {
                lines.append("  \u{001B}[1mExternal\u{001B}[0m \(external.name): \(OutputFormatter.humanBytes(external.availableBytes)) free")
            } else {
                lines.append("  \u{001B}[33mExternal: none detected\u{001B}[0m")
            }
        }
        if let report = state.cachedExplorer {
            lines.append("  \u{001B}[1mExplore:\u{001B}[0m \(report.rootPath) · allocated \(OutputFormatter.humanBytes(report.totalAllocatedBytes)) · logical \(OutputFormatter.humanBytes(report.totalLogicalBytes))")
            if !report.complete {
                lines.append("  \u{001B}[33mPartial scan: \(report.unreadablePaths.count) unreadable path(s), not 0 B\u{001B}[0m")
            }
            if report.previousGeneratedAt == nil {
                lines.append("  \u{001B}[2mFirst scan recorded; deltas appear on the next scan\u{001B}[0m")
            }
        } else if state.explorerLoading {
            lines.append("  Scanning directory by disk usage…")
        } else {
            lines.append("  \u{001B}[1mExplore:\u{001B}[0m \(state.explorerRoot)")
        }
        let entries = state.explorerEntries
        lines.append(contentsOf: renderListSearch(query: state.explorerSearch, editing: state.isSearching,
                                                   filter: "All",
                                                   sort: state.explorerSortByName ? "Name" : "Size", count: entries.count))

        if entries.isEmpty {
            if state.explorerLoading {
                lines.append(center("Scanning… entries appear as they are measured.", width: width))
            } else {
                lines.append(center("No matching entries. Clear filters with [c] or rescan with [r].", width: width))
            }
            return lines
        }

        let deltas = state.explorerDeltaByPath
        let listHeight = listVisibleRows(for: .explorer, terminalHeight: height + 5)
        let selectedIndex = min(max(0, state.explorerIndex), entries.count - 1)

        lines.append("\u{001B}[1m  Entry                              Disk Use      Change\u{001B}[0m")
        lines.append("  " + String(repeating: "─", count: min(width - 4, 70)))

        let startIndex = min(state.explorerScrollOffset, max(0, entries.count - listHeight))
        let endIndex = min(entries.count, startIndex + listHeight)

        for i in startIndex..<endIndex {
            let item = entries[i]
            let isSelected = (i == selectedIndex)
            let marker: String
            switch item.kind {
            case .directory: marker = "▸"
            case .application: marker = "◈"
            case .file: marker = "•"
            case .symlink: marker = "→"
            case .other: marker = "?"
            }
            let nameCol = padRight(marker + " " + item.name, width: 34)
            let sizeCol = padLeft(item.unreadable ? "unreadable" : OutputFormatter.humanBytes(item.allocatedBytes), width: 11)
            let deltaCol = padRight(explorerDeltaShort(deltas[item.path]), width: 10)
            if isSelected {
                lines.append("\u{001B}[7m ➜ \(nameCol) \(sizeCol) \(deltaCol) \u{001B}[0m")
            } else {
                lines.append("   \(nameCol) \(sizeCol) \(deltaCol)")
            }
        }

        lines.append(contentsOf: repeatElement("", count: listHeight - (endIndex - startIndex)))
        lines.append("")
        lines.append("  " + String(repeating: "─", count: min(width - 4, 70)))
        let sel = entries[selectedIndex]
        let delta = deltas[sel.path].map { OutputFormatter.explorerDeltaText($0) } ?? ""
        lines.append("  \u{001B}[1mSelected:\u{001B}[0m \(sel.name) (\(sel.unreadable ? "unreadable" : OutputFormatter.humanBytes(sel.allocatedBytes))\(delta)) [\(sel.action.label)]")
        lines.append("  \u{001B}[2mPath:\u{001B}[0m \(shortenPath(sel.path, maxWidth: max(12, width - 10)))")

        return lines
    }

    private func explorerDeltaShort(_ delta: ExplorerDelta?) -> String {
        guard let delta else { return "" }
        switch delta.status {
        case .unchanged, .uncomparable: return ""
        case .added: return "new"
        case .removed: return "removed"
        case .grown:
            guard let amount = delta.deltaAllocatedBytes else { return "+”" }
            return "+\(OutputFormatter.humanBytes(UInt64(amount)))"
        case .shrunk:
            guard let amount = delta.deltaAllocatedBytes else { return "-”" }
            return "-\(OutputFormatter.humanBytes(amount.magnitude))"
        }
    }

    private func explorerDetailBody(state: TUIState, entry: ExplorerEntry, width: Int) -> [String] {
        var lines: [String] = []
        let pathBudget = max(12, width - 14)
        let delta = state.explorerDeltaByPath[entry.path].map { OutputFormatter.explorerDeltaText($0) } ?? ""
        lines.append("\u{001B}[1mExplore Detail · \(entry.name)\u{001B}[0m")
        lines.append("")
        lines.append("  \u{001B}[1mPath:\u{001B}[0m \(shortenPath(entry.path, maxWidth: pathBudget))")
        lines.append("  \u{001B}[1mKind:\u{001B}[0m \(entry.kind.rawValue)")
        lines.append("  \u{001B}[1mDisk use:\u{001B}[0m \(entry.unreadable ? "unreadable (not 0 B)" : OutputFormatter.humanBytes(entry.allocatedBytes))\(delta)")
        lines.append("  \u{001B}[1mLogical:\u{001B}[0m \(OutputFormatter.humanBytes(entry.logicalBytes))")
        lines.append("  \u{001B}[1mFiles:\u{001B}[0m \(entry.fileCount)")
        lines.append("  \u{001B}[1mAction:\u{001B}[0m \(entry.action.label)")
        if let target = entry.externalTarget {
            lines.append("  \u{001B}[1mLink target:\u{001B}[0m \(shortenPath(target, maxWidth: pathBudget))")
        }
        if case .blocked(let reason) = entry.action, !reason.isEmpty {
            lines.append("")
            lines.append("  \u{001B}[33m\(reason)\u{001B}[0m")
        }
        lines.append("")
        lines.append("  Allocated size is an upper bound; APFS clones, shared blocks, and snapshots can make the actual freed space smaller.")
        lines.append("  Moving keeps a symlink at the original path; disconnecting the external volume makes this data unavailable.")
        lines.append("")
        lines.append("  \u{001B}[1mPress [m] to move, [o] to reveal in Finder, [Esc] to return.\u{001B}[0m")
        return lines
    }

    private func renderAppMoveList(state: TUIState, width: Int, height: Int) -> [String] {
        var lines: [String] = []
        let candidates = state.moveCandidates
        lines.append(contentsOf: renderListSearch(query: state.moveSearch, editing: state.isSearching,
                                                   filter: "\(state.moveStatusFilter.label) · \(state.moveSizeFilter.label)",
                                                   sort: state.moveSortByName ? "Name" : "Size", count: candidates.count))
        lines[0] = moveDestinationLine(state: state)

        if candidates.isEmpty {
            lines.append(center("No matching applications. Clear filters with [c] or refresh with [r].", width: width))
            lines.append(center("Press [r] to refresh or [Esc] to return.", width: width))
            return lines
        }

        let listHeight = listVisibleRows(for: .appMoveList, terminalHeight: height + 5)
        let selectedIndex = min(max(0, state.moveListIndex), candidates.count - 1)

        lines.append("\u{001B}[1m      Status      Application Name                       Size\u{001B}[0m")
        lines.append("  " + String(repeating: "─", count: min(width - 4, 70)))

        let startIndex = min(state.moveListScrollOffset, max(0, candidates.count - listHeight))
        let endIndex = min(candidates.count, startIndex + listHeight)

        for i in startIndex..<endIndex {
            let item = candidates[i]
            let isSelected = (i == selectedIndex)

            let badge: String
            switch item.compatibility?.grade {
            case .safe:
                badge = "\u{001B}[32m[Safe]   \u{001B}[0m"
            case .popupRisk:
                badge = "\u{001B}[33m[Review] \u{001B}[0m"
            case .blocked:
                badge = "\u{001B}[31m[Blocked]\u{001B}[0m"
            case .none:
                badge = "[Unknown]"
            }

            let nameCol = padRight(item.name, width: 38)
            let sizeCol = padLeft(OutputFormatter.humanBytes(item.sizeBytes), width: 10)
            let mark = item.compatibility?.grade == .blocked ? "[-]" : (state.selectedMovePaths.contains(item.path) ? "[x]" : "[ ]")

            if isSelected {
                lines.append("\u{001B}[7m ➜ \(mark) \(badge) \(nameCol) \(sizeCol) \u{001B}[0m")
            } else {
                lines.append("   \(mark) \(badge) \(nameCol) \(sizeCol)")
            }
        }

        // Keep the detail pane at the same row even when fewer candidates fill the list.
        lines.append(contentsOf: repeatElement("", count: listHeight - (endIndex - startIndex)))

        // Detail pane for selected candidate
        lines.append("")
        let batch = state.selectedMoveCandidates
        lines.append(batchSelectionRule(
            count: batch.count,
            bytes: batch.reduce(0) { $0 + $1.sizeBytes },
            outsideFilter: state.moveSelectionOutsideFilter,
            width: width
        ))
        let sel = candidates[selectedIndex]
        lines.append("  \u{001B}[1mSelected:\u{001B}[0m \(sel.name) (\(OutputFormatter.humanBytes(sel.sizeBytes)))")
        lines.append("  \u{001B}[2mPath:\u{001B}[0m \(shortenPath(sel.path, maxWidth: max(12, width - 10)))")

        if let comp = sel.compatibility {
            switch comp.grade {
            case .safe:
                lines.append("  \u{001B}[32mCompatibility:\u{001B}[0m Checks passed. No known relocation risks detected; app behavior can vary.")
            case .popupRisk:
                let reasons = comp.reasons.joined(separator: ", ")
                lines.append("  \u{001B}[33mCompatibility Review Required:\u{001B}[0m \(reasons)")
                if !comp.evidence.isEmpty {
                    lines.append("  \u{001B}[2mEvidence:\u{001B}[0m \(comp.evidence.joined(separator: "; "))")
                }
            case .blocked:
                let reasons = comp.reasons.joined(separator: ", ")
                lines.append("  \u{001B}[31mCompatibility Blocked:\u{001B}[0m \(reasons)")
                if !comp.evidence.isEmpty {
                    lines.append("  \u{001B}[2mEvidence:\u{001B}[0m \(comp.evidence.joined(separator: "; "))")
                }
            }
        }

        return lines
    }

    // MARK: - Risk Review View

    private func riskReviewBody(candidate: AppCandidate, width: Int) -> [String] {
        var lines: [String] = []

        lines.append("\u{001B}[1;33m⚠  Relocation Risk Review · \(candidate.name)\u{001B}[0m")
        lines.append("")
        lines.append("  \u{001B}[1mApplication:\u{001B}[0m \(candidate.name)")
        lines.append("  \u{001B}[1mPath:\u{001B}[0m \(shortenPath(candidate.path, maxWidth: max(12, width - 10)))")
        lines.append("  \u{001B}[1mSize:\u{001B}[0m \(OutputFormatter.humanBytes(candidate.sizeBytes))")
        lines.append("")

        if let comp = candidate.compatibility {
            lines.append("  \u{001B}[1mRisk Factors Identified:\u{001B}[0m")
            for reason in comp.reasons {
                lines.append("  • \u{001B}[33m\(reason)\u{001B}[0m")
            }
            if !comp.evidence.isEmpty {
                lines.append("")
                lines.append("  \u{001B}[2mTechnical Evidence:\u{001B}[0m")
                for evidence in comp.evidence {
                    lines.append("    \(evidence)")
                }
            }
        }

        lines.append("")
        lines.append("  \u{001B}[1mNotice:\u{001B}[0m Moving this application may trigger system permission popups")
        lines.append("  or require re-enabling helper tools. MacBay will proceed using \u{001B}[1m--force\u{001B}[0m.")
        lines.append("")
        lines.append("  Do you accept the risk and want to proceed with dry-run preview?")

        return lines
    }

    private func riskReviewFooter(state: TUIState, bodyCount: Int, viewport: Int) -> [String] {
        let cancelBtn = state.riskFocusIndex == 0 ? "\u{001B}[7;1m [ Cancel ] \u{001B}[0m" : " [ Cancel ] "
        let acceptBtn = state.riskFocusIndex == 1 ? "\u{001B}[7;1;33m [ Accept Risk & Proceed ] \u{001B}[0m" : " [ Accept Risk & Proceed ] "

        return [
            scrollIndicator(bodyCount: bodyCount, viewport: viewport, scrollOffset: state.detailScrollOffset),
            "    \(cancelBtn)      \(acceptBtn)"
        ]
    }

    // MARK: - Volume Select View

    private func renderVolumeSelect(state: TUIState, subject: String, width: Int) -> [String] {
        var lines: [String] = []

        lines.append("\u{001B}[1;36mSelect Target External Volume · \(subject)\u{001B}[0m")
        lines.append("  \u{001B}[2mMultiple eligible external volumes were found. Choose one for this session:\u{001B}[0m")
        lines.append("")

        let volumes = state.eligibleVolumesList
        for (idx, vol) in volumes.enumerated() {
            let isSelected = idx == state.volumeSelectIndex
            let prefix = isSelected ? "\u{001B}[7m ➜ " : "   "
            let name = padRight(vol.name, width: 24)
            let path = padRight(vol.path, width: 28)
            let avail = OutputFormatter.humanBytes(vol.availableBytes) + " free"
            let line = "\(prefix)\(name) \(path) (\(avail))\u{001B}[0m"
            lines.append(line)
        }

        lines.append("")
        lines.append("  \u{001B}[2mNote: This volume choice will apply to your current TUI session only.\u{001B}[0m")

        return lines
    }

    // MARK: - Dry Run Preview View

    private func dryRunPreviewBody(plan: MigrationPlanPreview, width: Int) -> [String] {
        var lines: [String] = []

        let opTitle: String
        switch plan.operation {
        case "dock": opTitle = "Move Application (dock)"
        case "move": opTitle = "Move to External Storage (move)"
        default: opTitle = "Restore Application (undock)"
        }
        lines.append("\u{001B}[1;36mDry-Run Migration Preview · \(opTitle)\u{001B}[0m")
        lines.append("")

        if let notice = plan.notice, !notice.isEmpty {
            lines.append("  \u{001B}[1;32m✔  \(notice)\u{001B}[0m")
            lines.append("")
        }

        let pathBudget = max(12, width - 18)
        lines.append("  \u{001B}[1mApplication:\u{001B}[0m \(plan.appName)")
        lines.append("  \u{001B}[1mSize:\u{001B}[0m        \(OutputFormatter.humanBytes(plan.sizeBytes))")
        lines.append("  \u{001B}[1mSource:\u{001B}[0m      \(shortenPath(plan.sourcePath, maxWidth: pathBudget))")
        lines.append("  \u{001B}[1mDestination:\u{001B}[0m \(shortenPath(plan.destinationPath, maxWidth: pathBudget))")

        if plan.force {
            lines.append("  \u{001B}[33mMode:\u{001B}[0m        Forced (--force risk accepted)")
        }

        lines.append("")
        lines.append("  \u{001B}[1mStorage Space Estimates:\u{001B}[0m")
        for msg in plan.messages {
            lines.append("  • \(msg)")
        }

        lines.append("")
        lines.append("  \u{001B}[1mProceed with actual migration?\u{001B}[0m")

        return lines
    }

    private func dryRunPreviewFooter(state: TUIState, plan: MigrationPlanPreview, bodyCount: Int, viewport: Int) -> [String] {
        let cancelBtn = state.confirmFocusIndex == 0 ? "\u{001B}[7;1m [ Cancel ] \u{001B}[0m" : " [ Cancel ] "
        let confirmText = plan.operation == "undock" ? "[ Confirm & Restore ]" : "[ Confirm & Move ]"
        let confirmBtn = state.confirmFocusIndex == 1 ? "\u{001B}[7;1;32m \(confirmText) \u{001B}[0m" : " \(confirmText) "

        return [
            scrollIndicator(bodyCount: bodyCount, viewport: viewport, scrollOffset: state.detailScrollOffset),
            "    \(cancelBtn)      \(confirmBtn)"
        ]
    }

    // MARK: - Mutating Progress View

    private func renderMutatingProgress(state: TUIState, op: String, app: String, width: Int, height: Int) -> [String] {
        var lines: [String] = []

        lines.append("\u{001B}[1;33mOperation in Progress · \(op.capitalized) \(app)\u{001B}[0m")
        lines.append("")

        let elapsedStr = String(format: "%.1fs", state.operationElapsed)
        lines.append("  \u{001B}[2mTotal elapsed time:\u{001B}[0m \(elapsedStr)")
        if state.batchTotal > 0 {
            let succeeded = state.batchResults.filter { if case .succeeded = $0.status { return true }; return false }.count
            let failed = state.batchResults.count - succeeded
            lines.append("  Batch: \(succeeded) succeeded · \(failed) failed · \(state.batchTotal - state.batchResults.count) remaining · stops at first failure")
        }
        lines.append("")

        lines.append("  \u{001B}[1mCompleted Steps:\u{001B}[0m")
        if state.completedSteps.isEmpty {
            lines.append("    Starting operation…")
        } else {
            for step in state.completedSteps.suffix(max(1, height - 13)) {
                let durationStr = String(format: "%.1fs", step.duration)
                lines.append("    \u{001B}[32m✔\u{001B}[0m \(step.label) (\(durationStr))")
            }
        }

        lines.append("")
        if let current = state.currentStepLabel {
            lines.append("  \u{001B}[1;36m➜ Current:\u{001B}[0m \(current)…")
        }

        if let sample = state.copyProgress {
            lines.append("  Copy estimate: \(Int(sample.fraction * 100))% · \(OutputFormatter.humanBytes(sample.observedBytes)) / \(OutputFormatter.humanBytes(sample.totalBytes))")
            if let speed = sample.bytesPerSecond {
                lines.append("  Average growth: \(OutputFormatter.humanBytes(speed))/s · verification follows")
            }
        }

        if let notice = state.volumeNotice {
            lines.append("")
            lines.append(contentsOf: wrapped(["[!] \(notice)"], width: width - 2).map { "  \u{001B}[1;33m\($0)\u{001B}[0m" })
        }

        if state.quitDeferred {
            lines.append("")
            lines.append("  \u{001B}[1;33m[!] Quit requested. MacBay will safely finish the operation before exiting.\u{001B}[0m")
        }

        return lines
    }

    // MARK: - Operation Result View

    private func renderOperationResult(result: MigrationResult?, error: String?, errorDetails: String?, width: Int, height: Int) -> [String] {
        var lines: [String] = []

        if let err = error {
            lines.append("\u{001B}[1;31m✖  Migration Failed\u{001B}[0m")
            lines.append("")
            lines.append("  \u{001B}[1mError:\u{001B}[0m")
            lines.append("  \(err)")

            if let details = errorDetails, !details.isEmpty {
                lines.append("")
                lines.append("  \u{001B}[1mDetails:\u{001B}[0m")
                lines.append("  \(details)")
            }

            lines.append("")
            lines.append("  \u{001B}[1;33mThe application is not guaranteed to be in its original state. A failure after")
            lines.append("  the link update can leave the bundle relocated while records are unsaved.\u{001B}[0m")
            lines.append("")
            lines.append("  \u{001B}[1mRecommended Action:\u{001B}[0m")
            lines.append("  Run \u{001B}[1mmb doctor\u{001B}[0m to inspect link and record integrity before retrying.")
        } else if let res = result {
            let pathBudget = max(12, width - 18)
            lines.append("\u{001B}[1;32m✔  Migration Completed Successfully\u{001B}[0m")
            lines.append("")
            lines.append("  \u{001B}[1mApplication:\u{001B}[0m \(res.name)")
            lines.append("  \u{001B}[1mSource:\u{001B}[0m      \(shortenPath(res.sourcePath, maxWidth: pathBudget))")
            lines.append("  \u{001B}[1mDestination:\u{001B}[0m \(shortenPath(res.destinationPath, maxWidth: pathBudget))")
            lines.append("  \u{001B}[1mSize:\u{001B}[0m        \(OutputFormatter.humanBytes(res.sizeBytes))")
            lines.append("")
            for msg in res.messages {
                lines.append("  • \(msg)")
            }
        }

        lines.append("")
        lines.append("  \u{001B}[1mPress [Enter] or [Esc] to return to application list.\u{001B}[0m")

        return lines
    }

    // MARK: - App Restore List View

    private func renderAppRestoreList(state: TUIState, width: Int, height: Int) -> [String] {
        var lines: [String] = []
        let items = state.restoreItems
        lines.append(contentsOf: renderListSearch(query: state.restoreSearch, editing: state.isSearching,
                                                   filter: "\(state.restoreStatusFilter.label) · \(state.restoreSizeFilter.label)",
                                                   sort: state.restoreSortBySize ? "Size" : "Name", count: items.count))

        if items.isEmpty {
            lines.append(center("No matching external apps. Clear filters with [c] or refresh with [r].", width: width))
            lines.append(center("Press [r] to refresh or [Esc] to return.", width: width))
            return lines
        }

        let listHeight = listVisibleRows(for: .appRestoreList, terminalHeight: height + 5)
        let selectedIndex = min(max(0, state.restoreListIndex), items.count - 1)

        lines.append("\u{001B}[1m      Status        Application Name                     Size\u{001B}[0m")
        lines.append("  " + String(repeating: "─", count: min(width - 4, 70)))

        let startIndex = min(state.restoreListScrollOffset, max(0, items.count - listHeight))
        let endIndex = min(items.count, startIndex + listHeight)

        for i in startIndex..<endIndex {
            let item = items[i]
            let isSelected = (i == selectedIndex)

            let badge: String
            switch item.status {
            case .managed:
                badge = "\u{001B}[32m[Managed]   \u{001B}[0m"
            case .unmanaged:
                badge = "\u{001B}[33m[Unmanaged] \u{001B}[0m"
            case .unconfirmed:
                badge = "\u{001B}[35m[Unconfirmed]\u{001B}[0m"
            case .unresolved:
                badge = "\u{001B}[31m[Unresolved]\u{001B}[0m"
            }

            let nameCol = padRight(item.name, width: 36)
            let sizeCol = padLeft(item.sizeBytes.map { OutputFormatter.humanBytes($0) } ?? "Unknown", width: 10)
            let mark = !item.isRestorable ? "[-]" : (state.selectedRestorePaths.contains(item.sourcePath) ? "[x]" : "[ ]")

            if isSelected {
                lines.append("\u{001B}[7m ➜ \(mark) \(badge) \(nameCol) \(sizeCol) \u{001B}[0m")
            } else {
                lines.append("   \(mark) \(badge) \(nameCol) \(sizeCol)")
            }
        }

        lines.append("")
        let batch = state.selectedRestoreItems
        lines.append(batchSelectionRule(
            count: batch.count,
            bytes: batch.reduce(0) { $0 + ($1.sizeBytes ?? 0) },
            outsideFilter: state.restoreSelectionOutsideFilter,
            width: width
        ))
        let sel = items[selectedIndex]
        lines.append("  \u{001B}[1mSelected:\u{001B}[0m \(sel.name)")
        lines.append("  \u{001B}[2mExternal Path:\u{001B}[0m \(shortenPath(sel.externalPath, maxWidth: max(12, width - 19)))")

        // With a batch selection, Enter previews the batch instead of acting on this row.
        let batchHint = "  Press \u{001B}[1m[Enter]\u{001B}[0m to preview the batch; press [x] to clear it and act on one app."
        switch sel.status {
        case .managed:
            lines.append("  \u{001B}[32mStatus:\u{001B}[0m Managed by MacBay. Ready to restore back to internal /Applications.")
            lines.append(batch.isEmpty ? "  Press \u{001B}[1m[Enter]\u{001B}[0m to preview restore operation." : batchHint)
        case .unmanaged:
            lines.append("  \u{001B}[33mStatus:\u{001B}[0m External symlink is not registered with MacBay.")
            lines.append(batch.isEmpty ? "  Press \u{001B}[1m[Enter]\u{001B}[0m to review adoption into MacBay standard storage." : batchHint)
        case .unconfirmed:
            lines.append("  \u{001B}[35mStatus:\u{001B}[0m Unconfirmed target on external volume.")
            lines.append("  \u{001B}[1mCLI Guidance:\u{001B}[0m Run 'mb doctor' to diagnose link integrity.")
        case .unresolved(let reason):
            lines.append("  \u{001B}[31mStatus:\u{001B}[0m Unresolved symlink: \(reason)")
            lines.append("  \u{001B}[1mCLI Guidance:\u{001B}[0m Run 'mb doctor' to inspect broken symlinks.")
        }

        return lines
    }

    // MARK: - Adoption Views

    public enum AdoptConfirmAction: Equatable {
        case acceptRisk
        case adopt
        case unavailable
    }

    /// What pressing the second button on the adoption review screen does. Input handling and
    /// rendering share this so a button never advertises an action that cannot run.
    public func adoptConfirmAction(plan: AdoptPlan, riskAccepted: Bool) -> AdoptConfirmAction {
        switch plan.status {
        case .blocked, .conflict, .alreadyAdopted:
            return .unavailable
        case .reviewRequired:
            return riskAccepted ? .adopt : .acceptRisk
        case .ready:
            return .adopt
        }
    }

    private func adoptReviewBody(plan: AdoptPlan, riskAccepted: Bool, width: Int) -> [String] {
        var lines: [String] = []
        let labelWidth = 17
        let pathBudget = max(12, width - labelWidth - 4)

        func row(_ label: String, _ value: String) -> String {
            "  \u{001B}[1m\(padRight(label, width: labelWidth))\u{001B}[0m \(value)"
        }

        let action = adoptConfirmAction(plan: plan, riskAccepted: riskAccepted)
        let headline = action == .unavailable ? "✖" : "⚠"
        lines.append("\u{001B}[1;33m\(headline)  Adoption Review · \(plan.appName)\u{001B}[0m")
        if riskAccepted, case .reviewRequired = plan.status {
            lines.append("  \u{001B}[1;32m✔ Risk accepted for this adoption; MacBay will proceed using \u{001B}[1m--force\u{001B}[0m\u{001B}[1;32m.\u{001B}[0m")
        }
        lines.append("")
        lines.append(row("Application:", plan.appName))
        lines.append(row("Size:", OutputFormatter.humanBytes(plan.sizeBytes)))
        lines.append(row("Mode:", adoptModeDescription(plan.mode)))
        lines.append(row("Current Location:", shortenPath(plan.targetURL.path, maxWidth: pathBudget)))
        lines.append(row("Standard Storage:", shortenPath(plan.destinationURL.path, maxWidth: pathBudget)))
        lines.append(row("Link Change:", shortenPath(plan.symlinkURL.path, maxWidth: pathBudget)))
        lines.append(
            "  \(String(repeating: " ", count: labelWidth)) → "
                + shortenPath(plan.destinationURL.path, maxWidth: max(10, pathBudget - 2))
        )
        lines.append(row("Volume:", shortenPath(plan.volumeURL.path, maxWidth: pathBudget)))

        switch plan.status {
        case let .blocked(reason, solution):
            lines.append("")
            lines.append("  \u{001B}[1;31mBlocked:\u{001B}[0m \(reason)")
            lines.append("")
            lines.append("  \u{001B}[1mSolution:\u{001B}[0m")
            lines.append("  \(solution)")
            lines.append("")
            lines.append("  \u{001B}[2mAdoption cannot proceed while these signals are present.\u{001B}[0m")
        case let .conflict(reason):
            lines.append("")
            lines.append("  \u{001B}[1;31mConflict:\u{001B}[0m \(reason)")
            lines.append("")
            lines.append("  \u{001B}[2mRun 'mb doctor' to inspect the existing MacBay records.\u{001B}[0m")
        case let .reviewRequired(reasons, evidence):
            lines.append("")
            lines.append("  \u{001B}[1mRisk Factors Identified:\u{001B}[0m")
            for reason in reasons {
                lines.append("  • \u{001B}[33m\(reason)\u{001B}[0m")
            }
            if !evidence.isEmpty {
                lines.append("")
                lines.append("  \u{001B}[2mTechnical Evidence:\u{001B}[0m")
                for item in evidence {
                    lines.append("    \(item)")
                }
            }
            lines.append("")
            if riskAccepted {
                lines.append("  \u{001B}[2mThe risks above were accepted for this adoption.\u{001B}[0m")
            } else {
                lines.append("  \u{001B}[1mNotice:\u{001B}[0m Adopting may trigger system permission popups or require re-enabling")
                lines.append("  helper tools. Continuing accepts these risks using \u{001B}[1m--force\u{001B}[0m.")
            }
        case let .alreadyAdopted(details):
            lines.append("")
            lines.append("  \u{001B}[32mAlready adopted:\u{001B}[0m \(details)")
            lines.append("")
            lines.append("  \u{001B}[2mNo files will be changed. Press [Enter] to continue to the restore preview.\u{001B}[0m")
        case .ready:
            break
        }

        lines.append("")
        if action == .unavailable {
            lines.append("  \u{001B}[1mPress [Enter] or [Esc] to return to the application list.\u{001B}[0m")
        } else if action == .acceptRisk {
            lines.append("  \u{001B}[1mAccept the risk to continue with the adoption preview.\u{001B}[0m")
        } else {
            lines.append("  \u{001B}[1mProceed with adoption into MacBay standard storage?\u{001B}[0m")
        }

        return lines
    }

    private func adoptReviewFooter(state: TUIState, plan: AdoptPlan, bodyCount: Int, viewport: Int) -> [String] {
        let indicator = scrollIndicator(bodyCount: bodyCount, viewport: viewport, scrollOffset: state.detailScrollOffset)

        guard let confirmLabel = adoptConfirmLabel(plan: plan, riskAccepted: state.adoptRiskAccepted) else {
            return [indicator, "    \u{001B}[7;1m [ Close ] \u{001B}[0m"]
        }

        let cancelBtn = state.adoptReviewFocusIndex == 0 ? "\u{001B}[7;1m [ Cancel ] \u{001B}[0m" : " [ Cancel ] "
        let confirmBtn = state.adoptReviewFocusIndex == 1
            ? "\u{001B}[7;1;32m [ \(confirmLabel) ] \u{001B}[0m"
            : " [ \(confirmLabel) ] "
        return [indicator, "    \(cancelBtn)      \(confirmBtn)"]
    }

    private func adoptConfirmLabel(plan: AdoptPlan, riskAccepted: Bool) -> String? {
        switch adoptConfirmAction(plan: plan, riskAccepted: riskAccepted) {
        case .acceptRisk: return "Accept Risk & Continue"
        case .adopt: return "Confirm & Adopt"
        case .unavailable: return nil
        }
    }

    private func adoptModeDescription(_ mode: AdoptMode) -> String {
        switch mode {
        case .moveAndAdopt:
            return "Move bundle to standard storage and register"
        case .registerOnly:
            return "Register only (bundle already at standard storage, nothing moves)"
        case .alreadyAdopted:
            return "Already adopted (no changes needed)"
        }
    }

    private func adoptOutcomeBody(outcome: AdoptOutcome, width: Int) -> [String] {
        var lines: [String] = []
        let labelWidth = 17
        let pathBudget = max(12, width - labelWidth - 4)

        func row(_ label: String, _ value: String) -> String {
            "  \u{001B}[1m\(padRight(label, width: labelWidth))\u{001B}[0m \(value)"
        }

        switch outcome.status {
        case .completed:
            lines.append("\u{001B}[1;32m✔  Adoption Completed · \(outcome.appName)\u{001B}[0m")
            lines.append("")
            if let mode = outcome.mode {
                lines.append(row("Mode:", adoptModeDescription(mode)))
            }
            if let size = outcome.sizeBytes {
                lines.append(row("Size:", OutputFormatter.humanBytes(size)))
            }
            if let location = outcome.currentLocation {
                lines.append(row("Location:", shortenPath(location, maxWidth: pathBudget)))
            }
            if let destination = outcome.destinationPath {
                lines.append(row("Standard Storage:", shortenPath(destination, maxWidth: pathBudget)))
            }
            if let volume = outcome.volumePath {
                lines.append(row("Volume:", shortenPath(volume, maxWidth: pathBudget)))
            }
            lines.append("")
            lines.append("  The application is registered in MacBay records on that volume.")

            if let previewError = outcome.restorePreviewError {
                lines.append("")
                lines.append("  \u{001B}[1;33m⚠  Restore Preview Failed\u{001B}[0m")
                lines.append("  \(previewError)")
                lines.append("")
                lines.append("  \u{001B}[1mThe adoption above did complete; only the restore preview failed.\u{001B}[0m")
                lines.append("  Run \u{001B}[1mmb doctor\u{001B}[0m before retrying, or press [r] to refresh the list.")
            } else {
                lines.append("  Preparing the restore preview for this application…")
            }

        case let .failed(stage, message):
            lines.append("\u{001B}[1;31m✖  Adoption Failed · \(outcome.appName)\u{001B}[0m")
            lines.append("")
            if let stage {
                lines.append(row("Failed Stage:", stage))
                lines.append("")
            }
            lines.append("  \u{001B}[1mError:\u{001B}[0m")
            lines.append("  \(message)")

            if let details = outcome.errorDetails, !details.isEmpty {
                lines.append("")
                lines.append("  \u{001B}[1mDetails:\u{001B}[0m")
                lines.append("  \(details)")
            }

            lines.append("")
            lines.append("  \u{001B}[1mRollback:\u{001B}[0m")
            if outcome.rollbackActions.isEmpty, outcome.rollbackError == nil {
                lines.append("  No changes had been applied yet, so nothing needed to be rolled back.")
            } else {
                for action in outcome.rollbackActions {
                    lines.append("    \u{001B}[32m✔\u{001B}[0m \(action)")
                }
                if let rollbackError = outcome.rollbackError {
                    lines.append("    \u{001B}[1;31m✖ \(rollbackError)\u{001B}[0m")
                }
            }

            if !outcome.manualInterventionNeeded.isEmpty {
                lines.append("")
                lines.append("  \u{001B}[1;33mManual Intervention Needed:\u{001B}[0m")
                for item in outcome.manualInterventionNeeded {
                    lines.append("  • \(item)")
                }
            }

            lines.append("")
            lines.append("  \u{001B}[1;33mThe application is not guaranteed to be in its original state, and the restore")
            lines.append("  preview was not prepared. Inspect the paths above before retrying.\u{001B}[0m")
            lines.append("")
            lines.append("  \u{001B}[1mRecommended Action:\u{001B}[0m")
            lines.append("  Run \u{001B}[1mmb doctor\u{001B}[0m to inspect link and record integrity.")
        }

        return lines
    }

    // MARK: - Info Modal View

    private func renderInfoModal(message: String, guidance: String?, width: Int, height: Int) -> [String] {
        var lines: [String] = []

        lines.append("  \(message)")

        if let g = guidance {
            lines.append("")
            lines.append("  \u{001B}[1mRecommended Action:\u{001B}[0m")
            lines.append("  \(g)")
        }

        lines.append("")
        lines.append("  \u{001B}[1mPress [Enter] or [Esc] to dismiss.\u{001B}[0m")

        return lines
    }

    // MARK: - Doctor Views

    private func renderDoctorSummary(state: TUIState, width: Int, height: Int) -> [String] {
        var lines: [String] = []

        if let doc = state.cachedDoctor {
            let s = doc.summary
            lines.append("  \u{001B}[1mSummary:\u{001B}[0m Checked: \(s.checked)  |  \u{001B}[32mHealthy: \(s.healthy)\u{001B}[0m  |  \u{001B}[33mNeeds Attention: \(s.needsAttention)\u{001B}[0m  |  \u{001B}[35mUnverified: \(s.unableToVerify)\u{001B}[0m")
            lines.append("  " + String(repeating: "─", count: min(width - 4, 70)))

            let findings = doc.findings
            if findings.isEmpty {
                lines.append("")
                lines.append(center("No doctor findings reported.", width: width))
                return lines
            }

            let listHeight = max(4, height - 10)
            let selectedIndex = min(max(0, state.doctorListIndex), findings.count - 1)

            let startIndex = min(state.doctorListScrollOffset, max(0, findings.count - listHeight))
            let endIndex = min(findings.count, startIndex + listHeight)

            for i in startIndex..<endIndex {
                let f = findings[i]
                let isSelected = (i == selectedIndex)

                let badge: String
                switch f.status {
                case .healthy:
                    badge = "\u{001B}[32m[Healthy]    \u{001B}[0m"
                case .needsAttention:
                    badge = "\u{001B}[33m[Attention]  \u{001B}[0m"
                case .unableToVerify:
                    badge = "\u{001B}[35m[Unverified] \u{001B}[0m"
                }

                let name = padRight(f.name, width: 34)
                let category = padRight(f.category.rawValue, width: 18)

                if isSelected {
                    lines.append("\u{001B}[7m ➜ \(badge) \(name) \(category) \u{001B}[0m")
                } else {
                    lines.append("   \(badge) \(name) \(category)")
                }
            }

            // Detail pane
            lines.append("")
            lines.append("  " + String(repeating: "─", count: min(width - 4, 70)))
            let sel = findings[selectedIndex]
            lines.append("  \u{001B}[1mFinding:\u{001B}[0m \(sel.name) (\(sel.code.rawValue))")
            lines.append("  \u{001B}[2mDetail:\u{001B}[0m  \(sel.detail)")
            lines.append("  \u{001B}[1;33mRecommended Action:\u{001B}[0m \(sel.recommendation)")
        } else {
            lines.append("  Running doctor inspection…")
        }

        return lines
    }

    private func wrapped(_ lines: [String], width: Int) -> [String] {
        let capacity = max(1, width - 2)
        return lines.flatMap { $0.components(separatedBy: .newlines) }.flatMap { line -> [String] in
            guard !line.isEmpty else { return [""] }
            let plain = line.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            var result: [String] = []
            var row = ""
            var columns = 0
            for character in plain {
                let nextWidth = characterWidth(character)
                if columns + nextWidth > capacity, !row.isEmpty {
                    result.append(row)
                    row = ""
                    columns = 0
                }
                row.append(character)
                columns += nextWidth
            }
            result.append(row)
            return result
        }
    }

    private func recoveryBody(_ view: RecoveryView, width: Int) -> [String] {
        let formatter = OutputFormatter(useColor: false)
        let text: String
        switch view {
        case .comparison(let comparison):
            func describe(_ label: String, _ copy: AppCopyInfo) -> String {
                "\(label): \(copy.path)\n  Version: \(copy.version ?? "Unknown") · Build: \(copy.buildNumber ?? "Unknown")\n  Identifier: \(copy.bundleIdentifier ?? "Unknown")\n  Size: \(OutputFormatter.humanBytes(copy.sizeBytes))\n  Signature: \(copy.signatureStatus)\n  Compatibility: \(copy.compatibilityGrade)"
            }
            text = "Compare copies · \(comparison.appName)\nVolume: \(comparison.volumePath)\n\n" + describe("Local", comparison.localCopy) + "\n\n" + describe("External", comparison.externalCopy) + "\n" + comparison.redockBlockers.joined(separator: "\n") + "\n\nRedock: move the local app externally; archive the old external copy.\nKeep local: retain both copies; remove the management record.\nChoose an action to preview. No files have changed."
        case .preview(let plan):
            var warning = ""
            switch plan.status {
            case .blocked(let reason, let solution): warning = "Blocked: \(reason)\n\(solution)"
            case .reviewRequired(let reasons, let evidence): warning = "Risk acceptance required:\n" + (reasons + evidence).joined(separator: "\n")
            case .ready: break
            }
            text = warning + "\n" + formatter.formatRepairPlan(plan: plan, force: false, dryRun: true) + "\n" + plan.warnings.joined(separator: "\n")
        case .rollback(let record):
            text = "Review interrupted repair rollback: \(record.appName)\nPhase: \(record.phase.rawValue)\nVolume: \(record.volumePath)\nLocal: \(record.localPath)\nExternal: \(record.externalPath)\nExternal backup: \(record.backupPath)\nLocal backup: \(record.localBackupPath)\nStaging: \(record.stagingPath)\n\nRollback uses this journal to restore previous paths and records, and may remove staged files. No changes have been made yet."
        case .result(let message): text = message
        }
        return wrapped(text.components(separatedBy: "\n"), width: width)
    }

    private func renderRecovery(state: TUIState, view: RecoveryView, width: Int, height: Int) -> [String] {
        let body = recoveryBody(view, width: width)
        let labels: [String]
        switch view {
        case .comparison(let comparison):
            labels = ["Cancel", comparison.canRedock ? "Preview redock" : "Redock unavailable", "Preview keep local"]
        case .preview(let plan):
            switch plan.status {
            case .blocked: labels = ["Close"]
            case .reviewRequired: labels = ["Cancel", "Accept risk & repair"]
            case .ready: labels = ["Cancel", "Confirm repair"]
            }
        case .rollback: labels = ["Cancel", "Confirm rollback"]
        case .result: labels = ["Back", "Recheck diagnosis"]
        }
        let buttons = labels.enumerated().map { index, label in
            index == state.recoveryFocus ? "\u{001B}[7m [ \(label) ] \u{001B}[0m" : " [ \(label) ] "
        }.joined(separator: "  ")
        return composeDetail(body: body, footer: [scrollIndicator(bodyCount: body.count, viewport: height - 2, scrollOffset: state.detailScrollOffset), buttons], height: height, scrollOffset: state.detailScrollOffset)
    }

    private func renderDoctorFindingDetail(finding: DoctorFinding, width: Int, height: Int) -> [String] {
        var lines: [String] = []

        lines.append("\u{001B}[1mDoctor Finding Details · \(finding.name)\u{001B}[0m")
        lines.append("")
        lines.append("  \u{001B}[1mCode:\u{001B}[0m        \(finding.code.rawValue)")
        lines.append("  \u{001B}[1mStatus:\u{001B}[0m      \(finding.status.rawValue)")
        lines.append("  \u{001B}[1mCategory:\u{001B}[0m    \(finding.category.rawValue)")
        lines.append("")
        lines.append("  \u{001B}[1mInvolved Paths:\u{001B}[0m")
        for path in finding.paths {
            lines.append("  • \(shortenPath(path, maxWidth: max(12, width - 4)))")
        }
        lines.append("")
        lines.append("  \u{001B}[1mDetail:\u{001B}[0m")
        lines.append("  \(finding.detail)")
        lines.append("")
        lines.append("  \u{001B}[1;33mRecommended Action:\u{001B}[0m")
        lines.append("  \(finding.recommendation)")
        lines.append("")
        lines.append("  \u{001B}[1mPress [Esc] or [Enter] to return.\u{001B}[0m")

        return lines
    }

    // MARK: - Utilities

    private func makeProgressBar(ratio: Double, width: Int) -> String {
        let clamped = max(0.0, min(1.0, ratio))
        let filled = Int((clamped * Double(width)).rounded())
        let empty = max(0, width - filled)
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
        if clamped >= 0.9 {
            return "\u{001B}[31m[\(bar)]\u{001B}[0m"
        } else if clamped >= 0.75 {
            return "\u{001B}[33m[\(bar)]\u{001B}[0m"
        } else {
            return "\u{001B}[32m[\(bar)]\u{001B}[0m"
        }
    }

    /// Windows `body` to the viewport and pins `footer` to the bottom of the content area.
    private func composeDetail(body: [String], footer: [String], height: Int, scrollOffset: Int) -> [String] {
        let viewport = max(1, height - footer.count)
        let maxOffset = max(0, body.count - viewport)
        let offset = min(max(0, scrollOffset), maxOffset)

        var lines = Array(body[offset..<min(body.count, offset + viewport)])
        while lines.count < viewport {
            lines.append("")
        }
        lines.append(contentsOf: footer)
        while lines.count < height {
            lines.append("")
        }
        return Array(lines.prefix(height))
    }

    private func scrollIndicator(bodyCount: Int, viewport: Int, scrollOffset: Int) -> String {
        guard bodyCount > viewport else { return "" }
        let maxOffset = bodyCount - viewport
        let offset = min(max(0, scrollOffset), maxOffset)
        let lastVisible = min(bodyCount, offset + viewport)
        return "\u{001B}[2m[↑/↓] Scroll · lines \(offset + 1)-\(lastVisible) of \(bodyCount)\u{001B}[0m"
    }

    private func padRight(_ text: String, width: Int) -> String {
        let visible = displayWidth(text)
        guard visible < width else { return text }
        return text + String(repeating: " ", count: width - visible)
    }

    private func padLeft(_ text: String, width: Int) -> String {
        let visible = displayWidth(text)
        guard visible < width else { return text }
        return String(repeating: " ", count: width - visible) + text
    }

    private func center(_ text: String, width: Int) -> String {
        let visible = displayWidth(text)
        guard visible < width else { return text }
        let leftSpace = (width - visible) / 2
        let rightSpace = width - visible - leftSpace
        return String(repeating: " ", count: leftSpace) + text + String(repeating: " ", count: rightSpace)
    }

    /// Cuts `text` to `width` display columns, keeps ANSI escapes intact, and marks the cut with an ellipsis.
    private func truncate(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }
        guard displayWidth(text) > width else { return text }

        var output = ""
        var used = 0
        var state: AnsiScanState = .text
        let limit = width - 1

        for ch in text {
            if state != .text || ch == "\u{001B}" {
                output.append(ch)
                state = nextAnsiState(state, reading: ch)
                continue
            }
            let chWidth = characterWidth(ch)
            if used + chWidth > limit { break }
            output.append(ch)
            used += chWidth
        }

        return output + "\u{001B}[0m…"
    }

    /// Shortens a path from the left so its deepest components stay readable.
    private func shortenPath(_ path: String, maxWidth: Int) -> String {
        guard maxWidth > 1 else { return "…" }
        guard displayWidth(path) > maxWidth else { return path }

        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var kept: [String] = []
        for component in components.reversed() {
            let candidate = (["…"] + kept + [component]).joined(separator: "/")
            if displayWidth(candidate) > maxWidth { break }
            kept.insert(component, at: 0)
        }

        guard !kept.isEmpty else { return truncate(path, width: maxWidth) }
        return "…/" + kept.joined(separator: "/")
    }

    private enum AnsiScanState {
        case text
        case escape
        case controlSequence
    }

    private func nextAnsiState(_ state: AnsiScanState, reading ch: Character) -> AnsiScanState {
        switch state {
        case .text:
            return ch == "\u{001B}" ? .escape : .text
        case .escape:
            guard let scalar = ch.unicodeScalars.first else { return .text }
            // CSI ('[') and SS3 ('O') introduce a control sequence; anything else ends the escape.
            return scalar.value == 0x5B || scalar.value == 0x4F ? .controlSequence : .text
        case .controlSequence:
            guard let scalar = ch.unicodeScalars.first else { return .text }
            // Parameters/intermediates run until a final byte in 0x40...0x7E.
            return scalar.value >= 0x40 && scalar.value <= 0x7E ? .text : .controlSequence
        }
    }

    private func displayWidth(_ text: String) -> Int {
        var width = 0
        var state: AnsiScanState = .text

        for ch in text {
            if state == .text, ch == "\u{001B}" {
                state = .escape
                continue
            }
            if state != .text {
                state = nextAnsiState(state, reading: ch)
                continue
            }
            width += characterWidth(ch)
        }
        return width
    }

    private func characterWidth(_ character: Character) -> Int {
        var width = 0
        for scalar in character.unicodeScalars {
            switch scalar.value {
            case 0x0300...0x036F, 0x200B...0x200F, 0x2060...0x206F, 0xFE00...0xFE0F, 0xFE20...0xFE2F:
                continue
            default:
                width = max(width, TerminalRenderer.scalarWidth(scalar.value))
            }
        }
        return width
    }

    private static func scalarWidth(_ value: UInt32) -> Int {
        switch value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
