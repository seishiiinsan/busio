import AppIntents
import ActivityKit
import Foundation
import BusioKit

enum CommuteDirectionOption: String, AppEnum {
    case automatic
    case toWork
    case toHome

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sens du trajet"
    static let caseDisplayRepresentations: [CommuteDirectionOption: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(title: "Automatique", subtitle: "Aller le matin, retour l'après-midi"),
        .toWork: "Aller au travail",
        .toHome: "Rentrer",
    ]

    var direction: CommuteDirection? {
        switch self {
        case .automatic: nil
        case .toWork: .toWork
        case .toHome: .toHome
        }
    }
}

/// Démarre la Live Activity du prochain bus. Idéal dans une automatisation
/// Raccourcis (« tous les jours de semaine à 8 h 30 »).
struct StartCommuteActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Suivre mon bus"
    static let description = IntentDescription("Affiche le compte à rebours du prochain bus de ton trajet sur l'écran verrouillé et dans la Dynamic Island.")
    static let openAppWhenRun = false

    @Parameter(title: "Sens", default: .automatic)
    var direction: CommuteDirectionOption

    init() {}

    init(direction: CommuteDirectionOption) {
        self.direction = direction
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = Date()
        let snapshot = try await CommuteRefresher.refresh(direction: direction.direction, options: [.updateAlerts, .reloadWidgets], now: now)
        guard let journey = CommuteRefresher.nextJourney(in: snapshot, now: now) else {
            return .result(dialog: "Aucun bus direct de \(snapshot.originName) vers \(snapshot.destinationName) dans les prochaines heures.")
        }
        try await CommuteActivityController.start(journey: journey, snapshot: snapshot)
        let line = snapshot.style(for: journey.lineID)?.badge ?? ""
        return .result(dialog: "Suivi du \(line) de \(TimeText.clock(journey.departureTime)) depuis \(snapshot.originName).")
    }
}

/// Bouton « actualiser » de la Live Activity.
struct RefreshCommuteActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Actualiser mon bus"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        try await CommuteRefresher.refresh(options: [.updateActivity, .reloadWidgets])
        return .result()
    }
}

struct StopCommuteActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Arrêter le suivi du bus"
    static let description = IntentDescription("Retire la Live Activity du bus.")

    init() {}

    func perform() async throws -> some IntentResult {
        await CommuteActivityController.endAll()
        return .result()
    }
}
