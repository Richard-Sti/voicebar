import Foundation

/// Reads ~/.config/voicebar/config.toml (the Python tool's config), used
/// once to seed the app's settings on first launch.
// ponytail: flat TOML subset (tables, strings, numbers, bools, one-line string
// arrays), enough for that file.
struct Config {
    static let url: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let new = home.appendingPathComponent(".config/voicebar/config.toml")
        // ponytail: pre-rename location, drop once nobody uses it
        return FileManager.default.fileExists(atPath: new.path)
            ? new : home.appendingPathComponent(".config/linux-voice/config.toml")
    }()

    private var tables: [String: [String: Any]] = [:]

    static func load(from file: URL = url) -> Config {
        var cfg = Config()
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return cfg }
        var table = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                table = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = equalsIndex(line) else { continue }
            let key = unquote(line[..<eq].trimmingCharacters(in: .whitespaces))
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            cfg.tables[table, default: [:]][key] = parseValue(value)
        }
        return cfg
    }

    func string(_ table: String, _ key: String) -> String? { tables[table]?[key] as? String }
    func strings(_ table: String, _ key: String) -> [String]? { tables[table]?[key] as? [String] }

    // MARK: - Parsing helpers

    /// Removes a trailing `# comment`, ignoring `#` inside quoted strings.
    private static func stripComment(_ line: String) -> String {
        var quote: Character? = nil
        var escaped = false
        for (i, c) in zip(line.indices, line) {
            if escaped { escaped = false; continue }
            if quote == "\"", c == "\\" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "#" { return String(line[..<i]) }
        }
        return line
    }

    /// First `=` outside a quoted key.
    private static func equalsIndex(_ line: String) -> String.Index? {
        var quote: Character? = nil
        for (i, c) in zip(line.indices, line) {
            if let q = quote { if c == q { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "=" { return i }
        }
        return nil
    }

    private static func parseValue(_ v: String) -> Any {
        if v.hasPrefix("[") { return parseArray(v) }
        if v.hasPrefix("\"") || v.hasPrefix("'") { return unquote(v) }
        if v == "true" { return true }
        if v == "false" { return false }
        if let i = Int(v) { return i }
        if let d = Double(v) { return d }
        return v
    }

    private static func parseArray(_ v: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character? = nil
        var escaped = false
        for c in v.dropFirst() {
            if escaped { current.append(c); escaped = false; continue }
            if quote == "\"", c == "\\" { current.append(c); escaped = true; continue }
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
                current.append(c)
            } else if c == "," || c == "]" {
                let item = current.trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { items.append(unquote(item)) }
                current = ""
            } else {
                current.append(c)
            }
        }
        return items
    }

    /// Strips quotes; basic ("...") strings get TOML escapes decoded.
    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, first == s.last, first == "\"" || first == "'" else {
            return s
        }
        let body = String(s.dropFirst().dropLast())
        if first == "'" { return body }
        var out = ""
        var escaped = false
        for c in body {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(c)  // \\ and \" decode to the character itself
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }
}
