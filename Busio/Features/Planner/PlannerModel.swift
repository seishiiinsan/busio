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
    /// Plus de bus avant la fin du service : premiers départs du lendemain.
    private(set) var laterResult: JourneySearchResult?
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    /// Recherche en phrase (« demain 9h au boulot »).
    var phrase = ""
    private(set) var isInterpreting = false
    /// Ce qui a été compris (ou pourquoi ça n'a pas marché).
    private(set) var interpretation: (text: String, isProblem: Bool, usedModel: Bool)?

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
        laterResult = nil
        errorMessage = nil
        favoriteID = nil
        timeMode = .now
        interpretation = nil
    }

    /// Remplit le formulaire depuis une phrase ; la recherche part d'elle-même.
    func interpret(app: AppModel, now: Date = Date()) async {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isInterpreting = true
        defer { isInterpreting = false }
        let outcome = await QueryInterpreter(app: app).interpret(text, now: now)
        guard let destination = outcome.destination else {
            interpretation = (outcome.problem ?? "Destination non comprise.", true, outcome.usedModel)
            return
        }
        from = outcome.origin
        to = destination
        favoriteID = nil
        switch outcome.time {
        case .departAt(let date)?:
            timeMode = .departAt
            self.date = date
        case .arriveBy(let date)?:
            timeMode = .arriveBy
            self.date = date
        case .now?, nil:
            timeMode = .now
        }
        if let preference = outcome.preference { self.preference = preference }
        interpretation = (summary(), false, outcome.usedModel)
        phrase = ""
    }

    /// « Ma position → Gares Mazamet · arrivée avant 9:00 demain »
    private func summary(now: Date = Date()) -> String {
        var text = "\(from?.name ?? "Ma position") → \(to?.name ?? "…")"
        let label = TimeText.dayLabel(date, now: now)
        let day = label == "aujourd'hui" ? "" : " " + label
        switch timeMode {
        case .now: text += " · maintenant"
        case .departAt: text += " · départ \(TimeText.clock(date))\(day)"
        case .arriveBy: text += " · arrivée avant \(TimeText.clock(date))\(day)"
        }
        if preference != .fastest { text += " · \(preference.title.lowercased())" }
        return text
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
            if found.journeys.isEmpty, let start = Self.nextServiceStart(after: request.time) {
                var later = request
                later.time = .departAt(start)
                laterResult = try? await app.service.planJourney(later)
            } else {
                laterResult = nil
            }
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

    /// Reprise du service (4 h 30) après une recherche sans résultat ; rien pour « arriver avant ».
    static func nextServiceStart(after time: TimeConstraint, now: Date = Date()) -> Date? {
        let base: Date
        switch time {
        case .now: base = now
        case .departAt(let date): base = date
        case .arriveBy: return nil
        }
        let calendar = TransitClock.calendar
        let sameDay = calendar.date(bySettingHour: 4, minute: 30, second: 0, of: base) ?? base
        return sameDay > base ? sameDay : calendar.date(byAdding: .day, value: 1, to: sameDay)
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
