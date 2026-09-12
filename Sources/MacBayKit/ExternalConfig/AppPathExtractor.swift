import Foundation

enum TemplateTokenDetector {
    static func containsTemplateToken(_ raw: String) -> Bool {
        let scalars = Array(raw.unicodeScalars)
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "<" {
                var cursor = scalars.index(after: index)
                var length = 0
                while cursor < scalars.endIndex, scalars[cursor] != ">", length < 64 {
                    cursor = scalars.index(after: cursor)
                    length += 1
                }
                if cursor < scalars.endIndex, length > 0 {
                    return true
                }
            } else if scalar == "{" {
                var cursor = scalars.index(after: index)
                var length = 0
                while cursor < scalars.endIndex, scalars[cursor] != "}", length < 64 {
                    cursor = scalars.index(after: cursor)
                    length += 1
                }
                if cursor < scalars.endIndex, length > 0 {
                    return true
                }
            }
            index = scalars.index(after: index)
        }
        return false
    }
}

enum AppPathExtractor {
    private static let maxJSONDepth = 4
    private static let pathDelimiters: Set<Character> = [
        " ", "\t", "\n", "\r", "\"", "'", "`",
        ",", ";", "]", "}", ")", "(", "<", ">", "|", "&", "=", ":"
    ]

    static func paths(in rawValue: String) -> [String] {
        var found: [String] = []
        collect(rawValue: rawValue, depth: 0, into: &found)

        var seen = Set<String>()
        var results: [String] = []
        for candidate in found {
            guard let normalized = normalize(candidate), seen.insert(normalized).inserted else {
                if let decoded = fileURLDecoded(candidate), seen.insert(decoded).inserted {
                    results.append(decoded)
                }
                continue
            }
            results.append(normalized)
        }
        return results
    }

    static func hasAmbiguousAppToken(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().contains(".app") else { return false }
        if trimmed.contains("$") || trimmed.contains("`") { return true }
        if trimmed.hasPrefix("~") { return true }
        if trimmed.hasPrefix(".") { return true }
        return false
    }

    private static func collect(rawValue: String, depth: Int, into found: inout [String]) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if depth < maxJSONDepth, trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                for string in stringValues(in: object) {
                    collect(rawValue: string, depth: depth + 1, into: &found)
                }
            }
        }

        for quoted in quotedStrings(in: trimmed) {
            collect(rawValue: quoted, depth: depth, into: &found)
        }

        if trimmed.hasPrefix("/") {
            found.append(trimmed)
        }

        for component in trimmed.split(separator: ":", omittingEmptySubsequences: true) {
            let part = component.trimmingCharacters(in: .whitespaces)
            if part.hasPrefix("/") {
                found.append(part)
            }
        }

        found.append(contentsOf: embeddedAbsolutePaths(in: trimmed))
    }

    private static func quotedStrings(in string: String) -> [String] {
        let characters = Array(string)
        var results: [String] = []
        var index = 0
        while index < characters.count {
            let quote = characters[index]
            guard quote == "\"" || quote == "'" else {
                index += 1
                continue
            }
            index += 1
            var value = ""
            var escaped = false
            while index < characters.count {
                let character = characters[index]
                if escaped {
                    value.append(unescape(character))
                    escaped = false
                    index += 1
                    continue
                }
                if character == "\\" && quote == "\"" {
                    escaped = true
                    index += 1
                    continue
                }
                if character == quote {
                    results.append(value)
                    index += 1
                    break
                }
                if character == "\n" { break }
                value.append(character)
                index += 1
            }
        }
        return results
    }

    private static func unescape(_ character: Character) -> String {
        switch character {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "\"": return "\""
        case "\\": return "\\"
        case "'": return "'"
        default: return String(character)
        }
    }

    private static func embeddedAbsolutePaths(in string: String) -> [String] {
        let characters = Array(string)
        var results: [String] = []
        var index = 0
        while index < characters.count {
            if characters[index] == "/", isPathStart(characters, index: index) {
                var end = index + 1
                while end < characters.count, !pathDelimiters.contains(characters[end]) {
                    end += 1
                }
                results.append(String(characters[index..<end]))
                index = end
            } else {
                index += 1
            }
        }
        return results
    }

    private static func isPathStart(_ characters: [Character], index: Int) -> Bool {
        guard index == 0 else {
            let previous = characters[index - 1]
            if previous.isLetter || previous.isNumber || previous == "_" || previous == "$" || previous == "." {
                return false
            }
            if previous == "~" { return false }
            return true
        }
        return true
    }

    private static func stringValues(in object: Any, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        if let string = object as? String { return [string] }
        if let array = object as? [Any] {
            return array.flatMap { stringValues(in: $0, depth: depth + 1) }
        }
        if let dictionary = object as? [String: Any] {
            return dictionary.values.flatMap { stringValues(in: $0, depth: depth + 1) }
        }
        return []
    }

    private static func normalize(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        guard !path.contains("\n"), !path.contains("\u{0}") else { return nil }
        guard !path.contains("$"), !path.contains("`") else { return nil }
        guard !path.contains("://") else { return nil }
        guard !path.contains("*"), !path.contains("?"), !path.contains("[") else { return nil }
        guard !path.contains("{"), !path.contains("}") else { return nil }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        guard TemplateTokenDetector.containsTemplateToken(raw) == false else { return nil }

        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.hasPrefix("/") else { return nil }
        guard AppPathReference.parse(standardized) != nil else { return nil }
        return standardized
    }

    static func fileURLDecoded(_ raw: String) -> String? {
        guard raw.contains("%") else { return nil }
        guard raw.hasPrefix("file://") else { return nil }
        var path = String(raw.dropFirst("file://".count))
        if path.hasPrefix("localhost") {
            path = String(path.dropFirst("localhost".count))
        }
        if let hash = path.firstIndex(of: "#") {
            path = String(path[..<hash])
        }
        if let query = path.firstIndex(of: "?") {
            path = String(path[..<query])
        }
        guard !path.isEmpty else { return nil }
        guard let decoded = path.removingPercentEncoding, decoded != path else { return nil }
        if decoded.contains("*") || decoded.contains("?") || decoded.contains("[") { return nil }
        if decoded.contains("{") || decoded.contains("}") { return nil }
        guard TemplateTokenDetector.containsTemplateToken(decoded) == false else { return nil }
        guard decoded.hasPrefix("/") else { return nil }
        return normalize(decoded)
    }
}
