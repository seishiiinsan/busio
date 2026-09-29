import Foundation

/// Problème détecté sur un itinéraire en cours, au vu des horaires actuels.
public struct JourneyIssue: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Correspondance encore possible mais très juste.
        case tightTransfer
        /// Correspondance impossible avec les horaires actuels.
        case missedTransfer
        /// Un des bus est supprimé.
        case cancelled
    }

    public let kind: Kind
    /// Index dans `rides` du bus menacé (celui de la correspondance) ou supprimé.
    public let rideIndex: Int
    /// Arrivée du bus précédent à l'arrêt de correspondance.
    public let arrival: Date?
    /// Départ du bus de correspondance.
    public let departure: Date?
    /// Marge restante une fois la marche faite (négative : ratée).
    public let slack: TimeInterval?

    public init(kind: Kind, rideIndex: Int, arrival: Date? = nil, departure: Date? = nil, slack: TimeInterval? = nil) {
        self.kind = kind
        self.rideIndex = rideIndex
        self.arrival = arrival
        self.departure = departure
        self.slack = slack
    }

    /// Identifie l'alerte pour ne pas la répéter.
    public var key: String { "\(kind.rawValue)-\(rideIndex)" }

    public var isBlocking: Bool { kind != .tightTransfer }
}

extension PlannedJourney {
    /// Marche prévue entre la descente du bus `index` et la montée du suivant.
    public func transferWalk(after index: Int) -> TimeInterval {
        var rideCount = 0
        var total: TimeInterval = 0
        for leg in legs {
            switch leg {
            case .ride:
                if rideCount == index + 1 { return total }
                rideCount += 1
            case .walk(let walk):
                if rideCount == index + 1 { total += walk.duration }
            }
        }
        return total
    }

    /// Suppressions et correspondances menacées encore à venir, dans l'ordre du trajet.
    /// Une correspondance est « juste » sous `tightBelow` secondes de marge.
    public func issues(now: Date, tightBelow: TimeInterval = 60) -> [JourneyIssue] {
        let rides = rides
        var issues: [JourneyIssue] = []
        for (index, ride) in rides.enumerated() {
            // Bus déjà pris (ou passé) : plus rien à surveiller.
            guard ride.departure > now.addingTimeInterval(-60) || ride.isCancelled else { continue }
            guard ride.arrival > now else { continue }
            if ride.isCancelled {
                issues.append(JourneyIssue(kind: .cancelled, rideIndex: index, departure: ride.departure))
                continue
            }
            guard index > 0 else { continue }
            let previous = rides[index - 1]
            guard !previous.isCancelled else { continue }
            let slack = ride.departure.timeIntervalSince(previous.arrival) - transferWalk(after: index - 1)
            if slack < 0 {
                issues.append(JourneyIssue(kind: .missedTransfer, rideIndex: index, arrival: previous.arrival, departure: ride.departure, slack: slack))
            } else if slack < tightBelow {
                issues.append(JourneyIssue(kind: .tightTransfer, rideIndex: index, arrival: previous.arrival, departure: ride.departure, slack: slack))
            }
        }
        return issues
    }

    /// Mêmes bus, horaires tirés de `trips` (retards, suppressions, positions). Les marches suivent.
    public func updated(with trips: [TripInstance]) -> PlannedJourney {
        let oldRides = rides
        guard !oldRides.isEmpty else { return self }
        let newRides = oldRides.map { $0.matching(in: trips) ?? $0 }
        var result: [JourneyLeg] = []
        var rideIndex = 0
        for leg in legs {
            switch leg {
            case .ride:
                result.append(.ride(newRides[rideIndex]))
                rideIndex += 1
            case .walk(let walk):
                let start: Date
                if rideIndex == 0 {
                    // Marche d'approche : même avance sur le bus qu'au départ.
                    let lead = oldRides[0].departure.timeIntervalSince(walk.end)
                    start = newRides[0].departure.addingTimeInterval(-lead - walk.duration)
                } else {
                    start = newRides[rideIndex - 1].arrival
                }
                result.append(.walk(WalkLeg(fromName: walk.fromName, toName: walk.toName, from: walk.from, to: walk.to,
                                            start: start, end: start.addingTimeInterval(walk.duration), distance: walk.distance)))
            }
        }
        return PlannedJourney(legs: result)
    }

    /// Mêmes bus aux mêmes arrêts (les identifiants changent entre GTFS et Zenbus).
    public func usesSameBuses(as other: PlannedJourney) -> Bool {
        let a = rides, b = other.rides
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { $0.isSameRide(as: $1) }
    }

    /// Étapes jusqu'au bus `rideIndex` exclu (ce qui est fait ou en cours avant le plan B).
    func legs(before rideIndex: Int) -> [JourneyLeg] {
        var result: [JourneyLeg] = []
        var seen = 0
        for leg in legs {
            if case .ride = leg {
                if seen == rideIndex { break }
                seen += 1
            }
            result.append(leg)
        }
        // La marche de correspondance vers le bus raté n'a plus lieu d'être.
        while case .walk = result.last { result.removeLast() }
        return result
    }
}

extension RideLeg {
    /// Heure théorique au quai de montée (identique entre GTFS et Zenbus).
    var boardKey: Date? { board.scheduled }

    func isSameRide(as other: RideLeg) -> Bool {
        if tripID == other.tripID { return board.stopID == other.board.stopID && alight.stopID == other.alight.stopID }
        guard lineID == other.lineID, board.stopID == other.board.stopID, alight.stopID == other.alight.stopID,
              let a = boardKey, let b = other.boardKey else { return false }
        return abs(a.timeIntervalSince(b)) <= 90
    }

    /// La même course dans `trips`, découpée de la montée à la descente.
    func matching(in trips: [TripInstance]) -> RideLeg? {
        let candidates = trips
            .filter { $0.id == tripID || $0.lineID == lineID }
            .sorted { ($0.id == tripID ? 0 : 1, $0.source == .zenbus ? 0 : 1) < ($1.id == tripID ? 0 : 1, $1.source == .zenbus ? 0 : 1) }
        for trip in candidates {
            let sameID = trip.id == tripID
            guard let b = trip.calls.firstIndex(where: { call in
                guard call.stopID == board.stopID else { return false }
                if sameID && call.index == board.index { return true }
                guard let scheduled = call.scheduled, let key = boardKey else { return false }
                return abs(scheduled.timeIntervalSince(key)) <= 90
            }) else { continue }
            guard b + 1 < trip.calls.count,
                  let a = trip.calls[(b + 1)...].firstIndex(where: { $0.stopID == alight.stopID }) else { continue }
            return RideLeg(tripID: trip.id, lineID: trip.lineID, itineraryID: trip.itineraryID ?? itineraryID,
                           headsign: trip.headsign, calls: Array(trip.calls[b...a]), state: trip.state,
                           quality: trip.quality, source: trip.source, vehicle: trip.vehicle)
        }
        return nil
    }
}
