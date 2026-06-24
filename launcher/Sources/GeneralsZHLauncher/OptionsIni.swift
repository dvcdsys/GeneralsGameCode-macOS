import Foundation

/// Minimal round-trip editor for the engine's `Options.ini` (a `key = value`
/// preferences file). Only the lines we touch are rewritten; every other line is
/// preserved verbatim, so the launcher never clobbers settings it doesn't manage.
///
/// Matches the engine's parsing (`UserPreferences::load`): split on the first
/// `=`, trim both sides. `Resolution` is space-separated `W H` (engine `sscanf`).
struct OptionsIni {
    private var lines: [String]
    /// lowercased key -> index into `lines`
    private var index: [String: Int]

    private init(lines: [String]) {
        self.lines = lines
        var idx: [String: Int] = [:]
        for (i, line) in lines.enumerated() {
            if let key = Self.key(of: line) {
                idx[key.lowercased()] = i
            }
        }
        self.index = idx
    }

    /// Loads the file; a missing/unreadable file yields an empty document.
    static func load(from url: URL) -> OptionsIni {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return OptionsIni(lines: [])
        }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }   // drop trailing-newline artefact
        return OptionsIni(lines: parts)
    }

    /// Trimmed value for `key`, case-insensitively (nil if absent).
    func get(_ key: String) -> String? {
        guard let i = index[key.lowercased()] else { return nil }
        return Self.value(of: lines[i])
    }

    /// Sets `key`, replacing its line in place (keeping the original key casing)
    /// or appending a new `key = value` line.
    mutating func set(_ key: String, _ value: String) {
        if let i = index[key.lowercased()] {
            let original = Self.key(of: lines[i]) ?? key
            lines[i] = "\(original) = \(value)"
        } else {
            lines.append("\(key) = \(value)")
            index[key.lowercased()] = lines.count - 1
        }
    }

    /// Writes back, creating the parent directory if needed.
    func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Resolution convenience

    /// Parses `Resolution = W H` (space/tab-separated, matching engine `sscanf`).
    var resolution: (w: Int, h: Int)? {
        guard let raw = get("Resolution") else { return nil }
        let nums = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .compactMap { Int($0) }
        guard nums.count >= 2 else { return nil }
        return (nums[0], nums[1])
    }

    mutating func setResolution(_ w: Int, _ h: Int) {
        set("Resolution", "\(w) \(h)")
    }

    // MARK: - line helpers

    private static func key(of line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let k = line[..<eq].trimmingCharacters(in: .whitespaces)
        return k.isEmpty ? nil : k
    }

    private static func value(of line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    }
}
