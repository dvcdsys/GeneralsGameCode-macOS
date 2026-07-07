import SwiftUI

/// The tabbed window root: Play / Extensions / Bot Control / API Docs. One shared
/// `LauncherModel` drives every tab (injected once from the App).
struct RootView: View {
    @EnvironmentObject var model: LauncherModel

    enum Tab: Hashable { case play, extensions, bot, docs }
    @State private var tab: Tab = .play

    var body: some View {
        TabView(selection: $tab) {
            PlayTab()
                .tabItem { Label("Play", systemImage: "play.fill") }
                .tag(Tab.play)

            ExtensionsTab()
                .tabItem { Label("Mods & Extensions", systemImage: "puzzlepiece.extension") }
                .tag(Tab.extensions)

            BotControlTab()
                .tabItem { Label("Bot Control", systemImage: "cpu") }
                .tag(Tab.bot)

            ApiDocsTab()
                .tabItem { Label("API Docs", systemImage: "doc.text") }
                .tag(Tab.docs)
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 620, idealHeight: 760)
    }
}
