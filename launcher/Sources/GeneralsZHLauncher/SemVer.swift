import Foundation

/// Minimal semantic-version parse + compare. Tolerates a leading prefix
/// (e.g. `engine-v`, `launcher-v`, `v`) and any trailing pre-release/build
/// suffix (`1.2.3-rc1`, `1.2.3-test`).
struct SemVer: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String { "\(major).\(minor).\(patch)" }

    init?(_ raw: String) {
        guard let firstDigit = raw.firstIndex(where: { $0.isNumber }) else { return nil }
        // Take the leading run of digits and dots from the first digit on.
        let head = raw[firstDigit...].prefix { $0.isNumber || $0 == "." }
        let parts = head.split(separator: ".").map { Int($0) ?? 0 }
        guard !parts.isEmpty else { return nil }
        major = parts[0]
        minor = parts.count > 1 ? parts[1] : 0
        patch = parts.count > 2 ? parts[2] : 0
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
