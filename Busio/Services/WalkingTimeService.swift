@preconcurrency import MapKit
import BusioKit

/// Temps de marche jusqu'à un arrêt, calculé par Plans (MapKit).
@MainActor
final class WalkingTimeService {
    private var cache: [String: (date: Date, value: TimeInterval)] = [:]

    func walkingTime(from origin: Coordinate, to destination: Coordinate) async -> TimeInterval {
        // Ignore les petits déplacements (~50 m) pour réutiliser le calcul.
        let key = "\(Int(origin.latitude * 2_000)),\(Int(origin.longitude * 2_000))>\(Int(destination.latitude * 10_000)),\(Int(destination.longitude * 10_000))"
        if let hit = cache[key], Date().timeIntervalSince(hit.date) < 15 * 60 { return hit.value }

        let straight = Self.estimate(from: origin, to: destination)
        var value = straight
        if origin.distance(to: destination) > 30 {
            let request = MKDirections.Request()
            request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
            request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
            request.transportType = .walking
            if let eta = try? await MKDirections(request: request).calculateETA() {
                value = eta.expectedTravelTime
            }
        }
        cache[key] = (Date(), value)
        return value
    }

    /// Vol d'oiseau × 1,3 à 4,5 km/h.
    nonisolated static func estimate(from origin: Coordinate, to destination: Coordinate) -> TimeInterval {
        origin.distance(to: destination) * 1.3 / 1.25
    }
}
