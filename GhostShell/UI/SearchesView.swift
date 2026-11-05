import SwiftUI
import GhostMind

/// Réponses aux demandes de recherche (« trouve un club de boxe vers chez nous », « les bars vers La Défense »).
struct SearchesView: View {
    let perception: PerceptionController
    private var center: MindCenter { perception.mind }

    var body: some View {
        Group {
            if center.searches.isEmpty {
                ContentUnavailableView("Aucune recherche", systemImage: "magnifyingglass",
                                       description: Text("Quand un message vous demande de trouver quelque chose (« trouve un club de boxe », « regarde les bars vers La Défense »), GHOST cherche et présente les résultats ici."))
            } else {
                ScrollView { VStack(spacing: 14) { ForEach(center.searches) { SearchCard(search: $0, perception: perception) } }.padding(14) }
            }
        }
        .task { await center.reload() }
    }
}

private struct SearchCard: View {
    let search: PlaceSearch
    let perception: PerceptionController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(search.query.prefix(1).uppercased() + search.query.dropFirst()).font(.headline)
                if let area = search.area { Text("· autour de \(area)").foregroundStyle(.secondary) }
                if let when = search.when { Text("· \(when)").foregroundStyle(.secondary) }
                Spacer()
                Chip(text: label.0, color: label.1)
            }
            Text("D'après : « \(search.basis) »").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let note = search.note { Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.orange) }
            ForEach(search.results) { place in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name).font(.callout.weight(.medium))
                        Text(place.address).font(.caption).foregroundStyle(.secondary)
                        if let phone = place.phone { Text(phone).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let distance = place.distanceMeters { Text(distance < 1000 ? "\(Int(distance)) m" : String(format: "%.1f km", distance / 1000)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Button("Plans") { open(place) }.buttonStyle(GhostButtonStyle())
                }
                Divider()
            }
            HStack {
                Button("Chercher à nouveau") { run { try await $0.rerunSearch(search.id) } }.buttonStyle(GhostButtonStyle())
                Button("Fermer") { run { try await $0.hideSearch(search.id) } }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(14)
        .ghostGlass(cornerRadius: 14)
    }

    private var label: (String, Color) {
        switch search.status {
        case .done: return ("\(search.results.count) résultat(s)", .green); case .noResults: return ("Aucun résultat", .orange)
        case .needsArea: return ("Zone à préciser", .orange); case .notAuthorized: return ("Non autorisée", .red); case .failed: return ("Échec", .red)
        }
    }
    private func open(_ place: PlaceResult) {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: place.name), URLQueryItem(name: "ll", value: "\(place.latitude),\(place.longitude)")]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
    private func run(_ action: @escaping @Sendable (MindEngine) async throws -> Void) { Task { await perception.mind.perform(action) } }
}
