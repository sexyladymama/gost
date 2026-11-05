import SwiftUI
import GhostKit

/// Écran de consentement affiché au premier lancement. GHOST ne regarde rien tant que l'utilisateur n'a pas accepté ici.
struct OnboardingView: View {
    let perception: PerceptionController
    @Environment(\.dismiss) private var dismiss
    @State private var screen = true
    @State private var calendar = true
    @State private var search = true
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GhostWordmark(size: 30, subtitle: "bienvenue")
            Text("GHOST travaille pour vous, sans que vous ayez à brancher quoi que ce soit.")
                .font(.title3.weight(.semibold))
            point("eye", "Il regarde votre écran",
                  "Il lit le texte de la fenêtre au premier plan — messages, e-mails, pages web, quelle que soit l'application — pour repérer ce qu'on vous demande et vos rendez-vous. La lecture se fait sur ce Mac : rien n'est envoyé ailleurs.")
            point("calendar.badge.plus", "Il ajoute vos rendez-vous à l'agenda",
                  "Quand un message annonce « dîner le 10 novembre à 21h », GHOST l'ajoute directement, vérifie l'ajout et vous laisse l'annuler en un clic. Si l'heure est incertaine, il vous le propose seulement.")
            VStack(alignment: .leading, spacing: 6) {
                Text("Ce que GHOST ne fait jamais").font(.headline)
                Label("Il ne garde aucune image : seul le texte utile est conservé.", systemImage: "photo.slash")
                Label("Il ignore les gestionnaires de mots de passe, les sites de banque et les fenêtres de navigation privée.", systemImage: "lock.shield")
                Label("Il ne lit pas sa propre fenêtre et ne regarde rien quand l'écran est verrouillé.", systemImage: "lock")
                Label("⌃⌥⌘G met GHOST en pause immédiatement ; tout se désactive dans Sources.", systemImage: "pause.circle")
            }
            .font(.callout).foregroundStyle(.secondary)
            Divider()
            Toggle("Autoriser GHOST à regarder mon écran", isOn: $screen)
            Toggle("Autoriser GHOST à ajouter directement des rendez-vous à mon agenda", isOn: $calendar)
            Toggle("Autoriser GHOST à chercher en ligne pour répondre à mes demandes (lieux, avec Apple Plans : seules la question et la zone sont envoyées)", isOn: $search)
            Text("macOS vous demandera ensuite l'autorisation « Enregistrement de l'écran » et l'accès à l'agenda. GHOST ne peut pas les accorder à votre place ; après avoir accordé l'enregistrement de l'écran, quittez et relancez GHOST.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Plus tard") { finish(screen: false, calendar: false, search: false) }.buttonStyle(GhostButtonStyle())
                Button("Commencer") { finish(screen: screen, calendar: calendar, search: search) }
                    .buttonStyle(GhostButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .padding(26)
        .frame(width: 580)
        .background(GhostBackdrop())
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).frame(width: 30).foregroundStyle(GhostTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func finish(screen: Bool, calendar: Bool, search: Bool) {
        busy = true
        Task {
            await perception.completeOnboarding(screen: screen, calendarAutoAdd: calendar, search: search)
            dismiss()
        }
    }
}
