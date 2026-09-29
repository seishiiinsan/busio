import AppIntents
import Foundation
import BusioKit

/// « Dis Siri, prochain bus avec Busio »
struct NextBusIntent: AppIntent {
    static let title: LocalizedStringResource = "Prochain bus"
    static let description = IntentDescription("Donne l'heure du prochain bus de ton trajet, en temps réel si disponible.")
    static let openAppWhenRun = false

    @Parameter(title: "Sens", default: .automatic)
    var direction: CommuteDirectionOption

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let now = Date()
        let snapshot: CommuteSnapshot
        do {
            snapshot = try await CommuteRefresher.refresh(direction: direction.direction, options: [.reloadWidgets, .updateActivity], now: now)
        } catch {
            let message = "Configure d'abord ton trajet dans Busio."
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }
        guard let journey = CommuteRefresher.nextJourney(in: snapshot, now: now) else {
            let message = "Plus de bus direct de \(snapshot.originName) vers \(snapshot.destinationName) dans les prochaines heures."
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }
        let line = snapshot.style(for: journey.lineID)?.badge ?? ""
        let minutes = TimeText.minutes(until: journey.departureTime, from: now)
        let quality: String
        switch journey.quality {
        case .live: quality = "suivi en direct"
        case .estimated: quality = "estimation"
        case .planned: quality = "horaire prévu"
        case .theoretical: quality = "horaire théorique"
        }
        var message = "Le \(line) part de \(snapshot.originName) à \(TimeText.clock(journey.departureTime)), dans \(minutes) minute\(minutes > 1 ? "s" : ""), \(quality)."
        if let delay = TimeText.delay(journey.delay) { message += " Écart : \(delay)." }
        let advice = LeaveAdvice(journey: journey, walk: snapshot.walk, buffer: snapshot.buffer)
        if advice.leaveAt > now { message += " Pars à \(TimeText.clock(advice.leaveAt))." }
        message += " Arrivée à \(snapshot.destinationName) vers \(TimeText.clock(journey.arrivalTime))."
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct BusioShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextBusIntent(),
            phrases: [
                "Prochain bus avec \(.applicationName)",
                "Quand passe mon bus \(.applicationName)",
                "\(.applicationName) prochain bus",
            ],
            shortTitle: "Prochain bus",
            systemImageName: "bus.fill"
        )
        AppShortcut(
            intent: StartCommuteActivityIntent(),
            phrases: [
                "Suivre mon bus avec \(.applicationName)",
                "\(.applicationName) suivre mon bus",
            ],
            shortTitle: "Suivre mon bus",
            systemImageName: "platter.filled.bottom.iphone"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .pink
}
