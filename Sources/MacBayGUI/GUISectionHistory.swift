import Foundation

/// The same history is used by sidebar selections and links within a page.
public struct GUISectionHistory: Equatable {
    private var sections: [GUISection] = [.overview]
    private var index = 0

    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index + 1 < sections.count }

    mutating func visit(_ section: GUISection) {
        guard sections[index] != section else { return }
        sections.removeSubrange((index + 1)..<sections.count)
        sections.append(section)
        index += 1
    }

    mutating func goBack() -> GUISection? {
        guard canGoBack else { return nil }
        index -= 1
        return sections[index]
    }

    mutating func goForward() -> GUISection? {
        guard canGoForward else { return nil }
        index += 1
        return sections[index]
    }
}
