import Foundation
import CoreLocation
#if canImport(MapKit)
import MapKit
#endif

/// Recherche de lieux. Seule la question (« club de boxe ») et la zone (« La Défense ») sont transmises au service.
public protocol PlaceSearcher: Sendable {
    func search(query: String, area: String) async throws -> [PlaceResult]
}

#if canImport(MapKit)
/// Apple Plans (MapKit) : sans clé ni compte. La zone est d'abord localisée, puis la recherche est menée autour d'elle.
public struct MapKitPlaceSearcher: PlaceSearcher {
    public var radiusMeters: Double
    public var maxResults: Int
    public init(radiusMeters: Double = 4_000, maxResults: Int = 8) { self.radiusMeters = radiusMeters; self.maxResults = maxResults }

    public func search(query: String, area: String) async throws -> [PlaceResult] {
        let locate = MKLocalSearch.Request()
        locate.naturalLanguageQuery = area
        guard let center = try await MKLocalSearch(request: locate).start().mapItems.first?.placemark.coordinate else {
            throw MindError.invalid("Zone introuvable : « \(area) ».")
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: center, latitudinalMeters: radiusMeters * 2, longitudinalMeters: radiusMeters * 2)
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let items = try await MKLocalSearch(request: request).start().mapItems
        return items.prefix(maxResults * 2).compactMap { item -> PlaceResult? in
            guard let name = item.name, !name.isEmpty else { return nil }
            let c = item.placemark.coordinate
            let distance = origin.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            guard distance <= radiusMeters * 2.5 else { return nil }
            return PlaceResult(id: "\(name)|\(c.latitude)|\(c.longitude)", name: name, address: item.placemark.title ?? "",
                               phone: item.phoneNumber, url: item.url?.absoluteString, latitude: c.latitude, longitude: c.longitude,
                               distanceMeters: distance)
        }
        .sorted { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }
        .prefix(maxResults).map { $0 }
    }
}
#endif
