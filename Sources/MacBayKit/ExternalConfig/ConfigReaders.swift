import Foundation

enum StructuredConfigReader {
    static func extractJSON(data: Data, skipKeyPrefixes: [String] = []) -> ConfigReadResult {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return ConfigReadResult(error: "the JSON could not be parsed: \(error.localizedDescription)")
        }
        return walk(object, path: "", method: .json, skipKeyPrefixes: skipKeyPrefixes)
    }

    static func extractPlist(data: Data) -> ConfigReadResult {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            return ConfigReadResult(error: "the plist could not be parsed: \(error.localizedDescription)")
        }
        return walk(object, path: "", method: .plist, skipKeyPrefixes: [])
    }

    private static func walk(
        _ object: Any,
        path: String,
        method: ExtractionMethod,
        skipKeyPrefixes: [String],
        depth: Int = 0
    ) -> ConfigReadResult {
        var result = ConfigReadResult()
        guard depth < 32 else { return result }
        if shouldSkip(path, prefixes: skipKeyPrefixes) { return result }

        if let string = object as? String {
            for value in AppPathExtractor.paths(in: string) {
                result.references.append(ExtractedPathReference(
                    path: value,
                    location: path.isEmpty ? "(root)" : path,
                    method: method,
                    note: nil
                ))
            }
            return result
        }

        if let array = object as? [Any] {
            for (index, element) in array.enumerated() {
                let child = path.isEmpty ? "[\(index)]" : "\(path)[\(index)]"
                result.append(contentsOf: walk(element, path: child, method: method, skipKeyPrefixes: skipKeyPrefixes, depth: depth + 1))
            }
            return result
        }

        if let dictionary = object as? [String: Any] {
            for key in dictionary.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                guard let value = dictionary[key] else { continue }
                let child = path.isEmpty ? key : "\(path).\(key)"
                result.append(contentsOf: walk(value, path: child, method: method, skipKeyPrefixes: skipKeyPrefixes, depth: depth + 1))
            }
        }

        return result
    }

    private static func shouldSkip(_ path: String, prefixes: [String]) -> Bool {
        prefixes.contains { prefix in
            path == prefix || path.hasPrefix(prefix + ".") || path.hasPrefix(prefix + "[")
        }
    }
}

enum HeuristicTextReader {
    static func extract(_ text: String, skippedLines: Set<Int> = []) -> ConfigReadResult {
        var result = ConfigReadResult()
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            if skippedLines.contains(lineNumber) { continue }
            let raw = String(line)
            if isSkippableLine(raw) { continue }
            let location = "line \(lineNumber)"
            for path in AppPathExtractor.paths(in: raw) {
                result.references.append(ExtractedPathReference(
                    path: path,
                    location: location,
                    method: .text,
                    note: nil
                ))
            }
        }
        return result
    }

    private static func isSkippableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        return trimmed.hasPrefix("#") || trimmed.hasPrefix("//") || trimmed.hasPrefix(";")
    }
}

struct ConfigFileReader {
    func read(file: DiscoveredConfigFile, data: Data) -> ConfigReadResult {
        switch file.format {
        case .json:
            return readJSON(data: data)
        case .plist:
            return StructuredConfigReader.extractPlist(data: data)
        case .toml:
            return readTOML(data: data)
        case .yaml, .text:
            return readText(data: data)
        }
    }

    private func readJSON(data: Data) -> ConfigReadResult {
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return ConfigReadResult(error: "the JSON could not be parsed: \(error.localizedDescription)")
        }

        var result = ConfigReadResult()
        if let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
           root["mcpServers"] != nil {
            let mcp = JSONMCPExtractor.extract(data: data)
            if let error = mcp.error {
                result.issues.append(ConfigReadIssue(
                    location: "mcpServers",
                    reason: error,
                    confirmedOmission: true
                ))
            } else {
                result.append(contentsOf: MCPAdapter.references(from: mcp))
            }
            result.coveredKeyPrefixes.append("mcpServers")
        }

        let structured = StructuredConfigReader.extractJSON(data: data, skipKeyPrefixes: result.coveredKeyPrefixes)
        if structured.error != nil, result.references.isEmpty, result.issues.isEmpty {
            return structured
        }
        if structured.error == nil {
            result.append(contentsOf: structured)
        }
        return result
    }

    private func readTOML(data: Data) -> ConfigReadResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return ConfigReadResult(error: "the file is not valid UTF-8 text")
        }

        let mcp = LimitedTOMLReader().extract(text)

        var result = ConfigReadResult()
        if mcp.error == nil {
            result.append(contentsOf: MCPAdapter.references(from: mcp))
            result.coveredLineNumbers = mcp.coveredLineNumbers
        }

        let heuristic = HeuristicTextReader.extract(text, skippedLines: result.coveredLineNumbers)
        result.append(contentsOf: heuristic)
        return result
    }

    private func readText(data: Data) -> ConfigReadResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return ConfigReadResult(error: "the file is not valid UTF-8 text")
        }
        return HeuristicTextReader.extract(text)
    }
}

enum MCPAdapter {
    static func references(from extraction: MCPExtraction) -> ConfigReadResult {
        var result = ConfigReadResult()
        result.issues = extraction.issues.compactMap { issue in
            if let serverName = issue.serverName, extraction.servers[serverName]?.isDisabled == true {
                return nil
            }
            return ConfigReadIssue(location: issue.location, reason: issue.reason, confirmedOmission: true)
        }
        result.error = extraction.error
        result.coveredLineNumbers = extraction.coveredLineNumbers

        let serverNames = extraction.servers.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        for serverName in serverNames {
            guard let server = extraction.servers[serverName], !server.isDisabled else { continue }
            var values: [(entry: MCPExtractedValue, isEnvironment: Bool)] = []
            if let command = server.command { values.append((command, false)) }
            values.append(contentsOf: server.args.map { ($0, false) })
            values.append(contentsOf: server.env.map { ($0, true) })

            for value in values {
                for path in AppPathExtractor.paths(in: value.entry.value) {
                    result.references.append(ExtractedPathReference(
                        path: path,
                        location: value.entry.location,
                        method: .mcp,
                        note: serverName
                    ))
                }
            }
        }
        return result
    }
}
