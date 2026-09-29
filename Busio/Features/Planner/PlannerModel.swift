import Foundation
import Observation
import BusioKit

@Observable
@MainActor
final class PlannerModel {
    enum TimeMode: String, CaseIterable, Identifiable {
        case now, departAt, arriveBy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .now: "Maintenant"
            case .departAt: "Partir à"
            case .arriveBy: "Arriver avant"
            }
        }
    }

    /// `nil` : ma position.
    var from: Place?
    var to: Place?
    var timeMode: TimeMode = .now
    var date = Date()
    var preference: RoutingOptions.Preference = .fastest
    /// Favori à l'origine de la recherche (pour le titre et les widgets).
    var favoriteID: UUID?

    private(set) var result: JourneySearchResult?
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    var hasQuery: Bool { to != nil }

    var timeConstraint: TimeConstraint {
        switch timeMode {
        case .now: .now
        case .departAt: .departAt(date)
        case .arriveBy: .arriveBy(date)
        }
    }

    var title: String {
        "\(from?.name ?? "Ma position") → \(to?.name ?? "…")"
    }

    func swap() {
        let origin = from
        from = to?.kind == .currentLocation ? nil : to
        to = origin
        favoriteID = nil
    }

    func clear() {
        to = nil
        from = nil
        result = nil
        errorMessage = nil
        favoriteID = nil
        timeMode = .now
    }

    /// Remplit le formulaire depuis un favori (heure d'arrivée comprise si elle s'applique aujourd'hui).
    func apply(_ favorite: FavoriteTrip, now: Date = Date()) {
        from = favorite.from.kind == .currentLocation ? nil : favorite.from
        to = favorite.to
        favoriteID = favorite.id
        if let deadline = favorite.arrivalDeadline(at: now) {
            timeMode = .arriveBy
            date = deadline
        } else {
            timeMode = .now
        }
        result = nil
    }

    func search(app: AppModel, silently: Bool = false) async {
        guard let to else { return }
        if !silently { isSearching = true }
        defer { isSearching = false }

        let origin: Place
        if let from {
            origin = from
        } else if let here = await app.location.currentCoordinate() {
            origin = .currentLocation(here)
        } else {
            errorMessage = app.location.isAuthorized
                ? "Position introuvable pour l'instant. Choisis un point de départ."
                : "Autorise la localisation ou choisis un point de départ."
            result = nil
            return
        }

        var options = app.preferences.routing
        options.preference = preference
        let request = JourneyRequest(from: origin, to: to, time: timeConstraint, options: options)
        do {
            let found = try await app.service.planJourney(request)
            result = found
            errorMessage = nil
            if let network = app.network {
                AppGroup.store.save(TripSnapshot(favoriteID: nil, title: title, result: found, network: network))
            }
            if !silently {
                if let from { app.preferences.remember(from) }
                app.preferences.remember(to)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Instantané de la recherche en cours (Live Activity).
    func snapshot(network: Network?) -> TripSnapshot? {
        guard let result, let network else { return nil }
        return TripSnapshot(favoriteID: favoriteID, title: title, result: result, network: network)
    }

    func journey(id: String) -> PlannedJourney? {
        result?.journeys.first { $0.id == id }
    }
}
