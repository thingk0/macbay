import Foundation

enum JSONMCPExtractor {
    static func extract(data: Data) -> MCPExtraction {
        var result = MCPExtraction()

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return MCPExtraction(error: "the JSON could not be parsed: \(error.localizedDescription)")
        }

        guard let root = object as? [String: Any] else {
            return MCPExtraction(error: "the top-level JSON value is not an object")
        }
        guard let serversValue = root["mcpServers"] else {
            return result
        }
        guard let servers = serversValue as? [String: Any] else {
            return MCPExtraction(error: "'mcpServers' is not an object")
        }

        for name in sortedKeys(of: servers) {
            guard let server = servers[name] as? [String: Any] else {
                result.recordIssue(
                    location: "mcpServers.\(name)",
                    reason: "the server entry is not an object",
                    serverName: name
                )
                continue
            }
            if let disabled = server["disabled"] as? Bool, disabled { continue }
            if let enabled = server["enabled"] as? Bool, !enabled { continue }

            let base = "mcpServers.\(name)"

            for flag in ["enabled", "disabled"] {
                if let value = server[flag], !(value is NSNull), !(value is Bool) {
                    result.recordIssue(location: "\(base).\(flag)", reason: "value is not a boolean", serverName: name)
                }
            }

            if let command = server["command"], !(command is NSNull) {
                if let text = command as? String {
                    result.setCommand(text, location: "\(base).command", server: name)
                } else {
                    result.recordIssue(location: "\(base).command", reason: "value is not a string", serverName: name)
                }
            }

            if let argsValue = server["args"], !(argsValue is NSNull) {
                if let args = argsValue as? [Any] {
                    for (index, element) in args.enumerated() {
                        if let text = element as? String {
                            result.appendArgument(text, location: "\(base).args[\(index)]", server: name)
                        } else if !(element is NSNull) {
                            result.recordIssue(location: "\(base).args[\(index)]", reason: "array element is not a string", serverName: name)
                        }
                    }
                } else {
                    result.recordIssue(location: "\(base).args", reason: "value is not an array", serverName: name)
                }
            }

            if let envValue = server["env"], !(envValue is NSNull) {
                if let env = envValue as? [String: Any] {
                    for key in sortedKeys(of: env) {
                        guard let value = env[key], !(value is NSNull) else { continue }
                        if let text = value as? String {
                            result.appendEnvironment(text, location: "\(base).env.\(key)", server: name)
                        } else {
                            result.recordIssue(location: "\(base).env.\(key)", reason: "value is not a string", serverName: name)
                        }
                    }
                } else {
                    result.recordIssue(location: "\(base).env", reason: "value is not an object", serverName: name)
                }
            }
        }

        return result
    }

    private static func sortedKeys(of dictionary: [String: Any]) -> [String] {
        dictionary.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
