import Foundation
#if canImport(EventKit)
import EventKit

/// Agenda réel de macOS (EventKit). Exige l'**accès complet** : sans lui GHOST ne pourrait ni vérifier l'ajout, ni éviter un doublon.
public final class EventKitCalendarWriter: CalendarWriter, @unchecked Sendable {
    private let store = EKEventStore()
    public init() {}

    public func authorization() async -> CalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied   // refusé, restreint ou « écriture seule » (insuffisant pour vérifier et dédoublonner)
        }
    }
    public func requestAccess() async -> Bool { (try? await store.requestFullAccessToEvents()) ?? false }

    public func events(around start: Date, window: TimeInterval) async throws -> [ExistingEvent] {
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-window), end: start.addingTimeInterval(window), calendars: nil)
        return store.events(matching: predicate).map {
            ExistingEvent(identifier: $0.eventIdentifier ?? "", title: $0.title ?? "", start: $0.startDate, end: $0.endDate)
        }
    }

    public func create(_ request: CalendarEventRequest) async throws -> String {
        guard let calendar = store.defaultCalendarForNewEvents else { throw CalendarError.notPermitted("Aucun agenda par défaut pour les nouveaux événements.") }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = request.title; event.startDate = request.start; event.endDate = request.end
        event.location = request.location; event.notes = request.notes
        try store.save(event, span: .thisEvent)
        guard let identifier = event.eventIdentifier else { throw CalendarError.verificationFailed("Identifiant de l'événement indisponible.") }
        return identifier
    }

    public func fetch(_ identifier: String) async throws -> ExistingEvent? {
        guard let event = store.event(withIdentifier: identifier) else { return nil }
        return ExistingEvent(identifier: identifier, title: event.title ?? "", start: event.startDate, end: event.endDate)
    }

    public func delete(_ identifier: String) async throws {
        guard let event = store.event(withIdentifier: identifier) else { return }
        try store.remove(event, span: .thisEvent)
    }
}
#endif
