import SwiftUI

/// Bot/engine API documentation, bundled into the app and rendered in-place.
/// A sidebar lists the docs; the pane renders the selected one.
struct ApiDocsTab: View {
    @State private var selected: MarkdownDoc = MarkdownDoc.all.first!

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            MarkdownView(markdown: selected.load())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(MarkdownDoc.all) { doc in
                Button(action: { selected = doc }) {
                    Text(doc.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(selected == doc ? Color.accentColor.opacity(0.20) : Color.clear)
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 200)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
