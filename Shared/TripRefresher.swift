import Foundation
import WidgetKit
import BusioKit

/// Recalcule les trajets favoris et l'itinéraire suivi, puis propage (widgets, Live Activity, rappels).
/// Utilisé par l'app, la tâche de fond, les widgets et les intents.
enum TripRefresher {
    /// Instantané à jour d'un favori (enregistré pour les widgets).
    @discardableResult
    static func refresh(favorite: FavoriteTrip, now: Date = Date(), reloadWidgets: Bool = false) async throws -> TripSnapshot {
        let preferences = AppGroup.store.loadPreferences()
        let request = favorite.request(options: preferences.routing, at: now, currentLocation: LocationMemory.last)
        let previous = AppGroup.store.loadSnapshot(favoriteID: favorite.id)
        let snapshot = try await Transit.service.snapshot(for: request, favoriteID: favorite.id, title: favorite.displayName, now: now)
        AppGroup.store.save(snapshot)
        if reloadWidgets, previous.map(signature) != signature(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        return snapshot
    }

    /// Recalcule l'itinéraire suivi et met à jour la Live Activity (même premier bus si possible).
    static func refreshFollowed(now: Date = Date()) async {
        guard let followed = AppGroup.store.loadFollowed() else { return }
        guard let snapshot = try? await Transit.service.snapshot(for: followed.request, favoriteID: nil, title: followed.title, now: now) else { return }
        let network = try? await Transit.service.currentNetwork()
        let journey = snapshot.journeys.first { $0.id == followed.journeyID }
            ?? snapshot.journeys.first { $0.firstRide?.tripID == followed.firstTripID && followed.firstTripID != nil }
        if let journey {
            await JourneyActivityController.update(journey: journey, snapshot: snapshot, network: network, now: now)
            let preferences = AppGroup.store.loadPreferences()
            await JourneyAlerts.scheduleLeave(for: journey, snapshot: snapshot, id: "followed", preferences: preferences, network: network, now: now)
            await JourneyAlerts.notifyDisruptions(in: journey, snapshot: snapshot, preferences: preferences, now: now)
        } else if followed.startedAt.timeIntervalSince(now) < -3 * 3600 {
            await JourneyActivityController.endAll()
        }
    }

    /// Tâche de fond : favoris avec rappel, itinéraire suivi, widgets.
    static func refreshAll(now: Date = Date()) async {
        let preferences = AppGroup.store.loadPreferences()
        let network = try? await Transit.service.currentNetwork()
        for favorite in preferences.favoriteTrips {
            guard let snapshot = try? await refresh(favorite: favorite, now: now) else { continue }
            if favorite.leaveAlerts, preferences.leaveNowAlerts, favorite.arrivalDeadline(at: now) != nil, let journey = snapshot.next(at: now) {
                await JourneyAlerts.scheduleLeave(for: journey, snapshot: snapshot, id: favorite.id.uuidString, preferences: preferences, network: network, now: now)
                await JourneyAlerts.notifyDisruptions(in: journey, snapshot: snapshot, preferences: preferences, now: now)
            }
        }
        await refreshFollowed(now: now)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func signature(_ snapshot: TripSnapshot) -> String {
        let journeys = snapshot.journeys.prefix(4).map { "\($0.id)|\(Int($0.departure.timeIntervalSince1970 / 60))|\(Int($0.arrival.timeIntervalSince1970 / 60))|\($0.quality.rawValue)|\($0.isCancelled)" }
        return ([snapshot.status.kind.rawValue, snapshot.closestBeforeID ?? ""] + journeys).joined(separator: "#")
    }
}

/// Dernière position connue (pour les favoris partant de « Ma position » en arrière-plan).
enum LocationMemory {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: AppGroup.identifier) }

    static var last: Coordinate? {
        guard let values = defaults?.array(forKey: "busio.last-location") as? [Double], values.count == 2 else { return nil }
        return Coordinate(latitude: values[0], longitude: values[1])
    }

    static func store(_ coordinate: Coordinate) {
        defaults?.set([coordinate.latitude, coordinate.longitude], forKey: "busio.last-location")
    }
}
