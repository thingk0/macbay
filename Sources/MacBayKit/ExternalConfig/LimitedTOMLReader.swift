import Foundation

struct LimitedTOMLReader {
    func extract(_ text: String) -> MCPExtraction {
        var result = MCPExtraction()
        var scanner = TOMLScanner(text)
        do {
            try scanner.parse(into: &result)
        } catch let error as TOMLReadError {
            result.error = "the TOML could not be parsed (\(error.description))"
        } catch {
            result.error = "the TOML could not be parsed (\(error.localizedDescription))"
        }
        return result
    }
}

private enum TOMLValue {
    case string(String)
    case array([TOMLValue])
    case inlineTable
    case multilineString
    case bare(String)
}

private struct TOMLReadError: Error, CustomStringConvertible {
    let line: Int
    let message: String

    var description: String { "line \(line): \(message)" }
}

private struct TOMLScanner {
    private let characters: [Character]
    private var index = 0
    private var line = 1
    private var coverMCPLines = false
    private var coveredLineNumbers: Set<Int> = []

    init(_ text: String) {
        var characters = Array(text)
        if characters.first == "\u{FEFF}" {
            characters.removeFirst()
        }
        self.characters = characters
    }

    private var current: Character? {
        index < characters.count ? characters[index] : nil
    }

    private func peek(_ offset: Int) -> Character? {
        let position = index + offset
        return position < characters.count ? characters[position] : nil
    }

    private var isAtEnd: Bool {
        index >= characters.count
    }

    private mutating func advance() {
        if index < characters.count, characters[index] == "\n" {
            line += 1
            if coverMCPLines {
                coveredLineNumbers.insert(line)
            }
        }
        index += 1
    }

    mutating func parse(into result: inout MCPExtraction) throws {
        var tablePath: [String] = []
        while true {
            skipWhitespaceAndComments()
            guard let character = current else { break }
            if character == "[" {
                tablePath = try parseTableHeader(into: &result)
            } else {
                try parseKeyValue(tablePath: tablePath, into: &result)
            }
        }
        result.coveredLineNumbers.formUnion(coveredLineNumbers)
    }

    private mutating func skipWhitespaceAndComments() {
        while let character = current {
            switch character {
            case " ", "\t", "\n", "\r":
                advance()
            case "#":
                while let commentCharacter = current, commentCharacter != "\n" {
                    advance()
                }
            default:
                return
            }
        }
    }

    private mutating func skipHorizontalWhitespace() {
        while let character = current, character == " " || character == "\t" {
            advance()
        }
    }

    private mutating func parseTableHeader(into result: inout MCPExtraction) throws -> [String] {
        advance()
        var isArrayOfTables = false
        if current == "[" {
            isArrayOfTables = true
            advance()
        }

        let path = try parseKeyPath()
        guard current == "]" else {
            throw TOMLReadError(line: line, message: "unterminated table header")
        }
        advance()

        if isArrayOfTables {
            guard current == "]" else {
                throw TOMLReadError(line: line, message: "unterminated array-of-tables header")
            }
            advance()
            if path.first == "mcp_servers" {
                result.recordIssue(
                    location: path.joined(separator: "."),
                    reason: "array of tables is not inspected",
                    serverName: path.count > 1 ? path[1] : nil
                )
            }
        }
        coverMCPLines = path.first == "mcp_servers"
        if coverMCPLines {
            coveredLineNumbers.insert(line)
        }
        return path
    }

    private mutating func parseKeyPath() throws -> [String] {
        var segments: [String] = []
        while true {
            skipHorizontalWhitespace()
            segments.append(try parseKeySegment())
            skipHorizontalWhitespace()
            guard current == "." else { break }
            advance()
        }
        return segments
    }

    private mutating func parseKeySegment() throws -> String {
        guard let character = current else {
            throw TOMLReadError(line: line, message: "expected a key")
        }
        if character == "\"" {
            return try parseBasicString()
        }
        if character == "'" {
            return try parseLiteralString()
        }

        var segment = ""
        while let candidate = current, Self.isBareKeyCharacter(candidate) {
            segment.append(candidate)
            advance()
        }
        guard !segment.isEmpty else {
            throw TOMLReadError(line: line, message: "expected a key")
        }
        return segment
    }

    private static func isBareKeyCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    private mutating func parseKeyValue(tablePath: [String], into result: inout MCPExtraction) throws {
        let keyPath = try parseKeyPath()
        skipHorizontalWhitespace()
        guard current == "=" else {
            throw TOMLReadError(line: line, message: "expected '=' after key '\(keyPath.joined(separator: "."))'")
        }
        advance()
        skipHorizontalWhitespace()

        let fullPath = tablePath + keyPath
        let previous = coverMCPLines
        if fullPath.first == "mcp_servers" {
            coverMCPLines = true
            coveredLineNumbers.insert(line)
        }

        let value = try parseValue()
        try finishLine()
        coverMCPLines = previous || tablePath.first == "mcp_servers"
        handle(fullPath: fullPath, value: value, into: &result)
    }

    private mutating func finishLine() throws {
        skipHorizontalWhitespace()
        if current == "#" {
            while let character = current, character != "\n" {
                advance()
            }
        }
        guard let character = current else { return }
        if character == "\r" {
            advance()
            if current == "\n" { advance() }
        } else if character == "\n" {
            advance()
        } else {
            throw TOMLReadError(line: line, message: "unexpected text after a value")
        }
    }

    private mutating func parseValue() throws -> TOMLValue {
        guard let character = current else {
            throw TOMLReadError(line: line, message: "expected a value")
        }
        switch character {
        case "\"":
            if peek(1) == "\"", peek(2) == "\"" {
                try skipMultilineString(quote: "\"")
                return .multilineString
            }
            return .string(try parseBasicString())
        case "'":
            if peek(1) == "'", peek(2) == "'" {
                try skipMultilineString(quote: "'")
                return .multilineString
            }
            return .string(try parseLiteralString())
        case "[":
            return .array(try parseArray())
        case "{":
            try skipInlineTable()
            return .inlineTable
        default:
            return .bare(try parseBareValue())
        }
    }

    private mutating func parseBasicString() throws -> String {
        advance()
        var result = ""
        while let character = current {
            if character == "\"" {
                advance()
                return result
            }
            if character == "\\" {
                advance()
                result.append(try parseEscapeSequence())
                continue
            }
            if character == "\n" {
                throw TOMLReadError(line: line, message: "unterminated string")
            }
            result.append(character)
            advance()
        }
        throw TOMLReadError(line: line, message: "unterminated string")
    }

    private mutating func parseEscapeSequence() throws -> String {
        guard let character = current else {
            throw TOMLReadError(line: line, message: "unterminated escape sequence")
        }
        advance()
        switch character {
        case "b": return "\u{08}"
        case "t": return "\t"
        case "n": return "\n"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "\"": return "\""
        case "\\": return "\\"
        case "u": return try parseUnicodeEscape(length: 4)
        case "U": return try parseUnicodeEscape(length: 8)
        default:
            throw TOMLReadError(line: line, message: "unsupported escape sequence '\\\(character)'")
        }
    }

    private mutating func parseUnicodeEscape(length: Int) throws -> String {
        var hex = ""
        for _ in 0..<length {
            guard let character = current, character.isHexDigit else {
                throw TOMLReadError(line: line, message: "invalid unicode escape sequence")
            }
            hex.append(character)
            advance()
        }
        guard let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) else {
            throw TOMLReadError(line: line, message: "invalid unicode escape sequence")
        }
        return String(Character(scalar))
    }

    private mutating func parseLiteralString() throws -> String {
        advance()
        var result = ""
        while let character = current {
            if character == "'" {
                advance()
                return result
            }
            if character == "\n" {
                throw TOMLReadError(line: line, message: "unterminated string")
            }
            result.append(character)
            advance()
        }
        throw TOMLReadError(line: line, message: "unterminated string")
    }

    private mutating func skipMultilineString(quote: Character) throws {
        advance()
        advance()
        advance()
        while !isAtEnd {
            if current == quote, peek(1) == quote, peek(2) == quote {
                advance()
                advance()
                advance()
                var extra = 0
                while current == quote, extra < 2 {
                    advance()
                    extra += 1
                }
                return
            }
            advance()
        }
        throw TOMLReadError(line: line, message: "unterminated multiline string")
    }

    private mutating func parseArray() throws -> [TOMLValue] {
        advance()
        var values: [TOMLValue] = []
        while true {
            skipWhitespaceAndComments()
            guard let character = current else {
                throw TOMLReadError(line: line, message: "unterminated array")
            }
            if character == "]" {
                advance()
                return values
            }

            values.append(try parseValue())
            skipWhitespaceAndComments()
            if current == "," {
                advance()
                continue
            }
            if current == "]" {
                advance()
                return values
            }
            throw TOMLReadError(line: line, message: "expected ',' or ']' in an array")
        }
    }

    private mutating func parseBareValue() throws -> String {
        var token = ""
        while let character = current,
              character != "\n",
              character != "\r",
              character != "#",
              character != ",",
              character != "]",
              character != "}" {
            token.append(character)
            advance()
        }
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw TOMLReadError(line: line, message: "expected a value")
        }
        return trimmed
    }

    private mutating func skipInlineTable() throws {
        advance()
        var depth = 1
        while depth > 0 {
            guard let character = current else {
                throw TOMLReadError(line: line, message: "unterminated inline table")
            }
            switch character {
            case "\"":
                if peek(1) == "\"", peek(2) == "\"" {
                    try skipMultilineString(quote: "\"")
                } else {
                    _ = try parseBasicString()
                }
            case "'":
                if peek(1) == "'", peek(2) == "'" {
                    try skipMultilineString(quote: "'")
                } else {
                    _ = try parseLiteralString()
                }
            case "{":
                depth += 1
                advance()
            case "}":
                depth -= 1
                advance()
            default:
                advance()
            }
        }
    }

    private mutating func handle(fullPath: [String], value: TOMLValue, into result: inout MCPExtraction) {
        guard fullPath.first == "mcp_servers" else { return }
        let location = fullPath.joined(separator: ".")
        guard fullPath.count >= 2 else {
            result.recordIssue(location: location, reason: "value is not an MCP server table", serverName: nil)
            return
        }

        let serverName = fullPath[1]
        let fields = Array(fullPath.dropFirst(2))
        guard let field = fields.first else {
            result.recordIssue(location: location, reason: serverTableReason(for: value), serverName: serverName)
            return
        }

        switch field {
        case "command" where fields.count == 1:
            if case .string(let text) = value {
                result.setCommand(text, location: location, server: serverName)
            } else {
                result.recordIssue(location: location, reason: valueReason(for: value, expected: "a string"), serverName: serverName)
            }

        case "args" where fields.count == 1:
            guard case .array(let elements) = value else {
                result.recordIssue(location: location, reason: valueReason(for: value, expected: "an array of strings"), serverName: serverName)
                return
            }
            for (elementIndex, element) in elements.enumerated() {
                let elementLocation = "\(location)[\(elementIndex)]"
                switch element {
                case .string(let text):
                    result.appendArgument(text, location: elementLocation, server: serverName)
                case .array:
                    result.recordIssue(location: elementLocation, reason: "nested array is not inspected", serverName: serverName)
                case .inlineTable:
                    result.recordIssue(location: elementLocation, reason: "inline table is not inspected", serverName: serverName)
                case .multilineString:
                    result.recordIssue(location: elementLocation, reason: "multiline string is not inspected", serverName: serverName)
                case .bare:
                    result.recordIssue(location: elementLocation, reason: "array element is not a string", serverName: serverName)
                }
            }

        case "env" where fields.count == 1:
            result.recordIssue(location: location, reason: valueReason(for: value, expected: "a table"), serverName: serverName)

        case "env" where fields.count == 2:
            if case .string(let text) = value {
                result.appendEnvironment(text, location: location, server: serverName)
            } else {
                result.recordIssue(location: location, reason: valueReason(for: value, expected: "a string"), serverName: serverName)
            }

        case "enabled" where fields.count == 1, "disabled" where fields.count == 1:
            guard case .bare(let token) = value else {
                result.recordIssue(location: location, reason: "value is not a boolean", serverName: serverName)
                return
            }
            if (field == "enabled" && token == "false") || (field == "disabled" && token == "true") {
                result.markDisabled(server: serverName)
            }

        default:
            return
        }
    }

    private func serverTableReason(for value: TOMLValue) -> String {
        switch value {
        case .inlineTable: return "inline table is not inspected"
        case .multilineString: return "multiline string is not inspected"
        case .array, .string, .bare: return "value is not an MCP server table"
        }
    }

    private func valueReason(for value: TOMLValue, expected: String) -> String {
        switch value {
        case .inlineTable: return "inline table is not inspected"
        case .multilineString: return "multiline string is not inspected"
        case .array, .string, .bare: return "value is not \(expected)"
        }
    }
}
