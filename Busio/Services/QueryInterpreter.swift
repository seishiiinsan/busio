import Foundation
import BusioKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// « demain 9h au boulot » → départ, arrivée, heure, préférence.
/// Analyse française déterministe d'abord ; Apple Intelligence (sur l'appareil) quand elle ne suffit pas.
@MainActor
struct QueryInterpreter {
    struct Outcome {
        /// `nil` : ma position.
        var origin: Place?
        var destination: Place?
        var time: TimeConstraint?
        var preference: RoutingOptions.Preference?
        var usedModel = false
        /// Ce qui n'a pas pu être compris ou trouvé.
        var problem: String?
    }

    let app: AppModel

    func interpret(_ text: String, now: Date = Date()) async -> Outcome {
        var query = QueryParser.parse(text, now: now)
        var usedModel = false
        if !query.isConfident, let smart = await SmartQueryParser.parse(text, now: now), smart.destination != nil {
            query = ParsedQuery(
                origin: query.origin ?? smart.origin,
                destination: query.destination.flatMap { query.leftover.isEmpty ? $0 : nil } ?? smart.destination,
                time: query.time ?? smart.time,
                isTimeApproximate: query.time == nil ? smart.isTimeApproximate : query.isTimeApproximate,
                preference: query.preference ?? smart.preference
            )
            usedModel = true
        }

        var outcome = Outcome(time: query.time, preference: query.preference, usedModel: usedModel)
        guard let destinationTerm = query.destination else {
            outcome.problem = "Destination non comprise. Exemple : « demain 9h à la gare de Mazamet »."
            return outcome
        }
        switch await resolve(destinationTerm) {
        case .success(let place): outcome.destination = place
        case .failure(let problem):
            outcome.problem = problem.message
            return outcome
        }
        if let originTerm = query.origin {
            switch await resolve(originTerm) {
            case .success(let place): outcome.origin = place?.kind == .currentLocation ? nil : place
            case .failure(let problem):
                outcome.problem = problem.message
                return outcome
            }
        }
        if outcome.destination?.kind == .currentLocation {
            outcome.destination = nil
            outcome.problem = "« Ma position » ne peut pas être l'arrivée."
            return outcome
        }
        // « demain au boulot » : l'heure d'arrivée du trajet favori correspondant, s'il y en a une.
        if query.isTimeApproximate, case .departAt(let date)? = query.time, let destination = outcome.destination,
           let favorite = app.preferences.favoriteTrips.first(where: { $0.arriveByMinute != nil && $0.to.coordinate.distance(to: destination.coordinate) < 300 }),
           let minute = favorite.arriveByMinute {
            outcome.time = .arriveBy(FavoriteTrip.date(minute: minute, on: date))
        }
        return outcome
    }

    struct Problem: Error { let message: String }

    /// `.success(nil)` : ma position.
    private func resolve(_ term: ParsedQuery.PlaceTerm) async -> Result<Place?, Problem> {
        switch term {
        case .currentLocation:
            return .success(nil)
        case .home:
            guard let home = app.preferences.home else { return .failure(Problem(message: "Indique d'abord « Maison » dans Réglages › Lieux.")) }
            return .success(home)
        case .work:
            guard let work = app.preferences.work else { return .failure(Problem(message: "Indique d'abord « Travail » dans Réglages › Lieux.")) }
            return .success(work)
        case .named(let name):
            if let place = await find(name) { return .success(place) }
            return .failure(Problem(message: "Lieu introuvable : « \(name) »."))
        }
    }

    /// Lieux récents et favoris, puis arrêts, puis Plans.
    private func find(_ name: String) async -> Place? {
        let key = TextFormatting.searchKey(name)
        guard !key.isEmpty else { return nil }
        var known = app.preferences.recentPlaces
        known += app.preferences.favoriteTrips.flatMap { [$0.from, $0.to] }.filter { $0.kind != .currentLocation }
        known += [app.preferences.home, app.preferences.work].compactMap { $0 }
        if let place = known.first(where: { TextFormatting.searchKey($0.name) == key }) { return place }

        if let network = app.network {
            let stopWords: Set<Substring> = ["de", "du", "des", "la", "le", "les", "l", "d", "a", "au", "aux", "arret", "station"]
            let words = key.split(separator: " ").filter { !stopWords.contains($0) }
            if !words.isEmpty {
                let areas = network.searchAreas(words.joined(separator: " "))
                if let area = areas.first(where: { TextFormatting.searchKey($0.name) == words.joined(separator: " ") }) ?? areas.first {
                    return Place(stop: area)
                }
            }
        }
        return await PlaceSearchService.search(name)
    }
}

/// Analyse par le modèle d'Apple Intelligence (sur l'appareil, hors ligne), si disponible.
enum SmartQueryParser {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static func parse(_ text: String, now: Date) async -> ParsedQuery? {
        #if canImport(FoundationModels)
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            Tu analyses des demandes d'itinéraire en bus dans l'agglomération de Castres-Mazamet.
            Recopie les lieux tels qu'écrits, sans les inventer ni les corriger. « maison », « chez moi » : maison ; « boulot », « travail », « bureau » : travail.
            Si l'utilisateur veut être quelque part à une heure (« pour 9h », « avant 9h », « 9h au boulot »), c'est une arrivée.
            """)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = TransitClock.timeZone
        formatter.dateFormat = "EEEE d MMMM, HH:mm"
        let prompt = "Nous sommes \(formatter.string(from: now)). Demande : « \(text) »"
        do {
            let draft = try await session.respond(to: prompt, generating: JourneyDraft.self).content
            return draft.query(now: now)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@Generable
enum JourneyTimeKind {
    case now, depart, arrive
}

@Generable
struct JourneyDraft {
    @Guide(description: "Lieu de départ tel qu'écrit, « ici » pour la position actuelle, chaîne vide s'il n'est pas précisé")
    var origin: String
    @Guide(description: "Lieu d'arrivée tel qu'écrit : arrêt, adresse, lieu, « maison » ou « travail »")
    var destination: String
    @Guide(description: "now : partir maintenant ou pas d'heure ; depart : partir à une heure ; arrive : arriver avant une heure")
    var timeKind: JourneyTimeKind
    @Guide(description: "Nombre de jours après aujourd'hui : 0 aujourd'hui, 1 demain, 2 après-demain…")
    var dayOffset: Int
    @Guide(description: "Heure de 0 à 23, ou -1 si aucune heure n'est donnée")
    var hour: Int
    @Guide(description: "Minutes de 0 à 59")
    var minute: Int

    func query(now: Date) -> ParsedQuery {
        let calendar = TransitClock.calendar
        let day = calendar.date(byAdding: .day, value: max(0, min(dayOffset, 14)), to: calendar.startOfDay(for: now)) ?? now
        var time: TimeConstraint?
        var approximate = false
        if (0...23).contains(hour), let date = calendar.date(bySettingHour: hour, minute: max(0, min(minute, 59)), second: 0, of: day) {
            time = timeKind == .depart ? .departAt(date) : .arriveBy(date)
        } else if dayOffset > 0, let date = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: day) {
            time = .departAt(date)
            approximate = true
        } else if timeKind == .now {
            time = .now
        }
        let origin = self.origin.trimmingCharacters(in: .whitespaces)
        let destination = self.destination.trimmingCharacters(in: .whitespaces)
        return ParsedQuery(
            origin: origin.isEmpty ? nil : QueryParser.placeTerm(origin),
            destination: destination.isEmpty ? nil : QueryParser.placeTerm(destination),
            time: time,
            isTimeApproximate: approximate
        )
    }
}
#endif
