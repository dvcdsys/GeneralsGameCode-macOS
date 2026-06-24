import SwiftUI

/// Placeholder for the future "Eternal Bot control" panel — monitoring and
/// start/stop of the bot running in a Docker container (a separate build).
/// Inert for now; see docs/COMMANDER_PLAN.md and the API Docs tab.
struct BotControlTab: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cpu")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)
            Text("Bot Control")
                .font(.title2).bold()
            Text("Coming soon")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Monitoring and start/stop for the Eternal Bot (running in a Docker "
               + "container, built separately) will live here. See the API Docs tab "
               + "for the bot/engine control API in the meantime.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .disabled(true)
    }
}
