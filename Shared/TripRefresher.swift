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

    /// Actualise l'itinéraire suivi (mêmes bus, horaires à jour), détecte les correspondances menacées,
    /// cherche un plan B, puis met à jour Live Activity et rappels.
    @discardableResult
    static func refreshFollowed(now: Date = Date()) async -> FollowedJourney? {
        guard var followed = AppGroup.store.loadFollowed() else { return nil }
        if followed.isOver(at: now) {
            await JourneyActivityController.endAll()
            JourneyAlerts.cancelFollowedAlerts()
            return nil
        }
        let network = try? await Transit.service.currentNetwork()
        let preferences = AppGroup.store.loadPreferences()

        if let journey = followed.journey {
            if let refreshed = try? await Transit.service.refresh(journey, now: now) { followed.replace(with: refreshed.journey) }
        } else if let snapshot = try? await Transit.service.snapshot(for: followed.request, favoriteID: nil, title: followed.title, now: now),
                  let match = snapshot.journeys.first(where: { $0.id == followed.journeyID })
                    ?? snapshot.journeys.first(where: { $0.firstRide?.tripID == followed.firstTripID && followed.firstTripID != nil }) {
            // Suivi enregistré par une version précédente : on retrouve l'itinéraire.
            followed.replace(with: match)
        }
        guard let journey = followed.journey else { return followed }
        let context = JourneyContext(followed: followed, network: network)

        // Correspondance menacée : plan B, une alerte par problème.
        if let issue = journey.issues(now: now).first {
            if followed.issue?.key != issue.key || followed.planB == nil {
                followed.planB = try? await Transit.service.alternative(for: journey, issue: issue, request: followed.request, now: now)
            }
            followed.issue = issue
            var alerted = followed.alerted ?? []
            if preferences.transferAlerts, alerted.insert("issue-\(issue.key)").inserted {
                await JourneyAlerts.notifyIssue(issue, journey: journey, planB: followed.planB, context: context)
            }
            followed.alerted = alerted
        } else {
            followed.issue = nil
            followed.planB = nil
        }

        AppGroup.store.save(followed: followed)
        await JourneyActivityController.update(followed: followed, network: network, now: now)
        await JourneyAlerts.scheduleLeave(for: journey, context: context, id: "followed", preferences: preferences, now: now)
        await JourneyAlerts.notifyDisruptions(in: journey, context: context, preferences: preferences, now: now)
        // Rappel de descente à l'heure prévue, sauf si le GPS suit déjà le trajet.
        if followed.progress.map({ now.timeIntervalSince($0.updatedAt) > 5 * 60 }) ?? true {
            await JourneyAlerts.scheduleAlight(for: journey, context: context, preferences: preferences, now: now)
        }
        return followed
    }

    /// Passe l'itinéraire suivi sur son plan B.
    static func switchToPlanB(now: Date = Date()) async -> FollowedJourney? {
        guard var followed = AppGroup.store.loadFollowed(), let planB = followed.planB else { return nil }
        followed.replace(with: planB)
        followed.issue = nil
        followed.planB = nil
        followed.alerted = nil
        AppGroup.store.save(followed: followed)
        return await refreshFollowed(now: now)
    }

    /// Tâche de fond : favoris avec rappel, itinéraire suivi, widgets.
    static func refreshAll(now: Date = Date()) async {
        let preferences = AppGroup.store.loadPreferences()
        let network = try? await Transit.service.currentNetwork()
        for favorite in preferences.favoriteTrips {
            guard let snapshot = try? await refresh(favorite: favorite, now: now) else { continue }
            if favorite.leaveAlerts, preferences.leaveNowAlerts, favorite.arrivalDeadline(at: now) != nil, let journey = snapshot.next(at: now) {
                let context = JourneyContext(snapshot: snapshot, network: network)
                await JourneyAlerts.scheduleLeave(for: journey, context: context, id: favorite.id.uuidString, preferences: preferences, now: now)
                await JourneyAlerts.notifyDisruptions(in: journey, context: context, preferences: preferences, now: now)
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
