import AppIntents
import ActivityKit
import Foundation
import BusioKit

/// Trajet favori exposé à Siri, Raccourcis et aux widgets.
struct FavoriteTripEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Trajet favori"
    static let defaultQuery = FavoriteTripQuery()

    let id: UUID
    let name: String

    init(_ trip: FavoriteTrip) {
        id = trip.id
        name = trip.displayName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct FavoriteTripQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [FavoriteTripEntity] {
        AppGroup.store.loadPreferences().favoriteTrips.filter { identifiers.contains($0.id) }.map(FavoriteTripEntity.init)
    }

    func suggestedEntities() async throws -> [FavoriteTripEntity] {
        AppGroup.store.loadPreferences().favoriteTrips.map(FavoriteTripEntity.init)
    }
}

extension FavoriteTrip {
    /// Favori choisi, ou le plus pertinent à cette heure.
    static func resolve(_ entity: FavoriteTripEntity?, at now: Date) -> FavoriteTrip? {
        let favorites = AppGroup.store.loadPreferences().favoriteTrips
        if let entity, let match = favorites.first(where: { $0.id == entity.id }) { return match }
        return FavoriteTrip.automatic(in: favorites, at: now)
    }
}

/// Résumés lisibles (Siri, notifications).
enum JourneyText {
    static func summary(_ journey: PlannedJourney, snapshot: TripSnapshot, network: Network?, now: Date) -> String {
        guard !journey.isWalkOnly else {
            return "À pied : \(TimeText.duration(journey.duration)), arrivée \(TimeText.clock(journey.arrival))."
        }
        var parts: [String] = []
        if case .walk = journey.legs.first, journey.departure > now {
            parts.append("pars à \(TimeText.clock(journey.departure))")
        }
        for (index, ride) in journey.rides.enumerated() {
            let badge = snapshot.style(for: ride.lineID)?.badge ?? ""
            let stop = network?.stop(ride.board.stopID)?.name ?? "l'arrêt"
            parts.append("\(index == 0 ? "prends" : "puis") le \(badge) à \(stop) à \(TimeText.clock(ride.departure))")
        }
        let quality: String
        switch journey.quality {
        case .live: quality = "suivi en direct"
        case .estimated: quality = "estimation"
        case .planned: quality = "horaires prévus"
        case .theoretical: quality = "horaires théoriques"
        }
        return parts.joined(separator: ", ").capitalizedFirst + ". Arrivée \(TimeText.clock(journey.arrival)) (\(quality))."
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Démarre la Live Activity d'un trajet favori. Idéal dans une automatisation
/// Raccourcis (« du lundi au vendredi à 8 h 30 »).
struct StartTripActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Suivre mon trajet"
    static let description = IntentDescription("Affiche le compte à rebours de ton trajet favori sur l'écran verrouillé et dans la Dynamic Island.")
    static let openAppWhenRun = false

    @Parameter(title: "Trajet")
    var trip: FavoriteTripEntity?

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = Date()
        guard let favorite = FavoriteTrip.resolve(trip, at: now) else {
            return .result(dialog: "Ajoute d'abord un trajet favori dans Busio.")
        }
        let snapshot = try await TripRefresher.refresh(favorite: favorite, now: now, reloadWidgets: true)
        guard let journey = snapshot.next(at: now) else {
            return .result(dialog: "Aucun itinéraire pour \(favorite.displayName) dans les prochaines heures.")
        }
        let network = try? await Transit.service.currentNetwork()
        try await JourneyActivityController.start(journey: journey, snapshot: snapshot, network: network)
        await JourneyAlerts.scheduleLeave(for: journey, snapshot: snapshot, id: "followed", preferences: AppGroup.store.loadPreferences(), network: network, now: now)
        return .result(dialog: IntentDialog(stringLiteral: JourneyText.summary(journey, snapshot: snapshot, network: network, now: now)))
    }
}

/// Bouton « actualiser » de la Live Activity.
struct RefreshTripActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Actualiser mon trajet"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await TripRefresher.refreshFollowed()
        return .result()
    }
}

struct StopTripActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Arrêter le suivi du trajet"
    static let description = IntentDescription("Retire la Live Activity du trajet.")

    init() {}

    func perform() async throws -> some IntentResult {
        await JourneyActivityController.endAll()
        return .result()
    }
}
