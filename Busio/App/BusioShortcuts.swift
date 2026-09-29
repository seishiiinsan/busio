import AppIntents
import Foundation
import BusioKit

/// « Dis Siri, prochain trajet avec Busio »
struct NextTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Prochain trajet"
    static let description = IntentDescription("Donne le prochain itinéraire d'un trajet favori, correspondances et temps réel compris.")
    static let openAppWhenRun = false

    @Parameter(title: "Trajet")
    var trip: FavoriteTripEntity?

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let now = Date()
        guard let favorite = FavoriteTrip.resolve(trip, at: now) else {
            let message = "Ajoute d'abord un trajet favori dans Busio."
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }
        let snapshot = try await TripRefresher.refresh(favorite: favorite, now: now, reloadWidgets: true)
        guard let journey = snapshot.next(at: now) else {
            let message = "Pas d'itinéraire pour \(favorite.displayName) dans les prochaines heures."
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }
        let network = try? await Transit.service.currentNetwork()
        let message = "\(favorite.displayName) : " + JourneyText.summary(journey, snapshot: snapshot, network: network, now: now)
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct BusioShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextTripIntent(),
            phrases: [
                "Prochain trajet avec \(.applicationName)",
                "Prochain bus avec \(.applicationName)",
                "Quand partir avec \(.applicationName)",
            ],
            shortTitle: "Prochain trajet",
            systemImageName: "bus.fill"
        )
        AppShortcut(
            intent: StartTripActivityIntent(),
            phrases: [
                "Suivre mon trajet avec \(.applicationName)",
                "Suivre mon bus avec \(.applicationName)",
            ],
            shortTitle: "Suivre mon trajet",
            systemImageName: "platter.filled.bottom.iphone"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .pink
}
