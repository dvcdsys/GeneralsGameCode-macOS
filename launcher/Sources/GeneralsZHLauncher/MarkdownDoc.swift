import Foundation

/// One bundled markdown document, surfaced in the API Docs tab. The files are
/// copied into `Contents/Resources/docs/` by `launcher/build-app.sh`.
struct MarkdownDoc: Identifiable, Hashable {
    let title: String
    let file: String          // filename under Resources/docs
    var id: String { file }

    /// The documents to surface, in reading order.
    static let all: [MarkdownDoc] = [
        .init(title: "External-Control API", file: "EXTERNAL_CONTROL_API.md"),
        .init(title: "Agent Overview",       file: "AGENT_README.md"),
        .init(title: "Architecture",         file: "ARCHITECTURE.md"),
        .init(title: "Agent",                file: "AGENT.md"),
        .init(title: "Harness",              file: "HARNESS.md"),
        .init(title: "Commander Plan",       file: "COMMANDER_PLAN.md"),
    ]

    /// Loads the markdown text from the app bundle, or a friendly message if the
    /// doc wasn't bundled (e.g. running from a dev build without `build-app.sh`).
    func load() -> String {
        if let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "docs"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return "_Documentation file `\(file)` is not bundled in this build._\n\n"
             + "Run `launcher/build-app.sh` to package the docs into the app."
    }
}
