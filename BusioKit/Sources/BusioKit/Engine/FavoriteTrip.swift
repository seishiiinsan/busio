import Foundation

/// Trajet enregistré (« Archipel → Gares Mazamet »), avec une heure d'arrivée
/// habituelle facultative pour préremplir la recherche.
public struct FavoriteTrip: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Nom personnalisé (vide : « départ → arrivée »).
    public var name: String
    public var from: Place
    public var to: Place
    /// Heure d'arrivée souhaitée (minutes depuis minuit), les jours `days`.
    public var arriveByMinute: Int?
    /// Jours où l'heure d'arrivée s'applique (1 = dimanche … 7 = samedi).
    public var days: Set<Int>
    /// Rappel « pars maintenant » ces jours-là.
    public var leaveAlerts: Bool

    public init(id: UUID = UUID(), name: String = "", from: Place, to: Place, arriveByMinute: Int? = nil, days: Set<Int> = [2, 3, 4, 5, 6], leaveAlerts: Bool = false) {
        self.id = id
        self.name = name
        self.from = from
        self.to = to
        self.arriveByMinute = arriveByMinute
        self.days = days
        self.leaveAlerts = leaveAlerts
    }

    public var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "\(from.name) → \(to.name)" : name
    }

    /// Trajet inverse (pour enregistrer le retour en un geste).
    public var reversed: FavoriteTrip {
        FavoriteTrip(from: to, to: from, arriveByMinute: nil, days: days, leaveAlerts: false)
    }

    public func appliesArrivalTime(on date: Date) -> Bool {
        arriveByMinute != nil && days.contains(TransitClock.calendar.component(.weekday, from: date))
    }

    /// Heure d'arrivée visée aujourd'hui, si elle est définie et pas encore passée.
    public func arrivalDeadline(at now: Date) -> Date? {
        guard let arriveByMinute, appliesArrivalTime(on: now) else { return nil }
        let deadline = Self.date(minute: arriveByMinute, on: now)
        return deadline > now ? deadline : nil
    }

    /// Prochaine heure d'arrivée visée : aujourd'hui si elle n'est pas passée, sinon l'un des jours suivants.
    public func nextArrivalDeadline(after now: Date) -> Date? {
        guard let arriveByMinute else { return nil }
        for offset in 0..<8 {
            guard let day = TransitClock.calendar.date(byAdding: .day, value: offset, to: now), appliesArrivalTime(on: day) else { continue }
            let deadline = Self.date(minute: arriveByMinute, on: day)
            if deadline > now { return deadline }
        }
        return nil
    }

    /// Recherche de repli quand plus aucun bus ne circule : prochaine heure d'arrivée visée, sinon reprise du service.
    public func laterRequest(than request: JourneyRequest, now: Date) -> JourneyRequest? {
        var later = request
        if let deadline = nextArrivalDeadline(after: now) {
            later.time = .arriveBy(deadline)
        } else if let start = request.time.nextServiceStart(now: now) {
            later.time = .departAt(start)
        } else {
            return nil
        }
        return later
    }

    /// Recherche correspondant au favori à cet instant.
    public func request(options: RoutingOptions, at now: Date, currentLocation: Coordinate? = nil) -> JourneyRequest {
        var from = self.from
        if from.kind == .currentLocation, let currentLocation { from = .currentLocation(currentLocation) }
        let time: TimeConstraint = arrivalDeadline(at: now).map { .arriveBy($0) } ?? .now
        return JourneyRequest(from: from, to: to, time: time, options: options)
    }

    public static func date(minute: Int, on day: Date) -> Date {
        let start = TransitClock.calendar.startOfDay(for: day)
        return TransitClock.calendar.date(byAdding: .minute, value: minute, to: start) ?? start
    }

    /// Favori le plus pertinent maintenant : celui dont l'heure d'arrivée approche
    /// (dans les 3 h), sinon le premier.
    public static func automatic(in favorites: [FavoriteTrip], at now: Date) -> FavoriteTrip? {
        let upcoming = favorites.compactMap { favorite -> (FavoriteTrip, Date)? in
            guard let deadline = favorite.arrivalDeadline(at: now), deadline.timeIntervalSince(now) <= 3 * 3600 else { return nil }
            return (favorite, deadline)
        }
        return upcoming.min { $0.1 < $1.1 }?.0 ?? favorites.first
    }
}
