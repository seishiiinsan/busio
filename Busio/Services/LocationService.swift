@preconcurrency import CoreLocation
import Observation
import BusioKit

/// Position de l'utilisateur (arrêts proches, temps de marche).
@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    @ObservationIgnored private let manager = CLLocationManager()
    private(set) var authorization: CLAuthorizationStatus
    private(set) var lastCoordinate: Coordinate?
    @ObservationIgnored private var lastFix: Date?

    override init() {
        authorization = .notDetermined
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var canAsk: Bool { authorization == .notDetermined }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Position récente (moins de 30 s) ou nouvelle mesure (8 s max).
    func currentCoordinate() async -> Coordinate? {
        guard isAuthorized else { return nil }
        if let lastCoordinate, let lastFix, Date().timeIntervalSince(lastFix) < 30 { return lastCoordinate }
        let coordinate = await withTaskGroup(of: Coordinate?.self) { group -> Coordinate? in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                        if let location = update.location, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 200 {
                            return Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                        }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let coordinate {
            lastCoordinate = coordinate
            lastFix = Date()
            LocationMemory.store(coordinate)
            return coordinate
        }
        if let location = manager.location {
            return Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        }
        return lastCoordinate
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }
}
