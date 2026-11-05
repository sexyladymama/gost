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
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let region = MKCoordinateRegion(center: center, latitudinalMeters: radiusMeters * 2, longitudinalMeters: radiusMeters * 2)
        var found: [PlaceResult] = [], seen = Set<String>()
        // Apple Plans comprend mal certaines formulations (« club de boxe » → 1 résultat, « boxe » → 23) : on essaie des variantes
        // et on garde d'abord ce que la formulation exacte a trouvé.
        for variant in Self.variants(of: query) {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = variant
            request.region = region
            guard let items = try? await MKLocalSearch(request: request).start().mapItems else { continue }
            let batch = items.prefix(maxResults * 2).compactMap { item -> PlaceResult? in
                guard let name = item.name, !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
                let c = item.placemark.coordinate
                let distance = origin.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                guard distance <= radiusMeters * 2.5 else { return nil }
                return PlaceResult(id: "\(name)|\(c.latitude)|\(c.longitude)", name: name, address: item.placemark.title ?? "",
                                   phone: item.phoneNumber, url: item.url?.absoluteString, latitude: c.latitude, longitude: c.longitude,
                                   distanceMeters: distance)
            }
            found += batch.sorted { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }
            if found.count >= maxResults { break }
        }
        return Array(found.prefix(maxResults))
    }

    /// La question telle quelle, puis son cœur (« club de boxe » → « boxe »), puis « salle de … ».
    static func variants(of query: String) -> [String] {
        let core = query.replacingOccurrences(of: #"(?i)^(?:un |une |des |les |le |la |l')?(?:club|salle|cours|école|ecole)\s+(?:de |d')?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        var out = [query]
        for v in [core, "salle de \(core)"] where !v.isEmpty && !out.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) { out.append(v) }
        return out
    }
}
#endif
