import Foundation

/// Logique pure (sans réseau) : fusion des sources, départs, trajets.
public enum TripPlanner {
    /// Fusionne les courses Zenbus et GTFS : pour chaque couple (sens, jour),
    /// Zenbus fait foi s'il a publié la grille de ce jour, sinon le GTFS prend le relais.
    public static func merge(zenbus: [TripInstance], coverage: Set<String>, gtfs: [TripInstance]) -> [TripInstance] {
        let coveredLines = Set(coverage.compactMap { key -> String? in
            let parts = key.split(separator: "|")
            return parts.count == 3 ? "\(parts[0])|\(parts[2])" : nil
        })
        let fallback = gtfs.filter { trip in
            if let itinerary = trip.itineraryID {
                return !coverage.contains(coverageKey(lineID: trip.lineID, itineraryID: itinerary, day: trip.serviceDay))
            }
            return !coveredLines.contains("\(trip.lineID)|\(trip.serviceDay.yyyymmdd)")
        }
        return zenbus + fallback
    }

    public static func coverageKey(lineID: String, itineraryID: String, day: ServiceDay) -> String {
        "\(lineID)|\(itineraryID)|\(day.yyyymmdd)"
    }

    /// Départs aux quais `stopIDs` dans la fenêtre [now - tolérance, now + horizon].
    public static func departures(from trips: [TripInstance], at stopIDs: Set<String>, now: Date, horizon: TimeInterval) -> [Departure] {
        let end = now.addingTimeInterval(horizon)
        var result: [Departure] = []
        for trip in trips where trip.state != .finished {
            for (position, call) in trip.calls.enumerated() where stopIDs.contains(call.stopID) {
                // Au terminus, le bus ne repart pas.
                guard position < trip.calls.count - 1, !call.passed, let time = call.departure else { continue }
                guard time <= end, time >= now.addingTimeInterval(-tolerance(for: trip)) else { continue }
                result.append(Departure(trip: trip, call: call))
            }
        }
        return deduplicated(result).sorted { $0.time < $1.time }
    }

    /// Trajets directs d'un groupe de quais à un autre.
    public static func journeys(from trips: [TripInstance], origin: Set<String>, destination: Set<String>, now: Date, horizon: TimeInterval) -> [Journey] {
        let end = now.addingTimeInterval(horizon)
        var result: [Journey] = []
        for trip in trips where trip.state != .finished {
            var best: (StopCall, StopCall)?
            for (j, arrival) in trip.calls.enumerated() where destination.contains(arrival.stopID) && j > 0 {
                // Montée la plus tardive avant cette descente (trajet le plus court sur les lignes en boucle).
                guard let i = trip.calls[..<j].lastIndex(where: { origin.contains($0.stopID) }) else { continue }
                let departure = trip.calls[i]
                if best == nil || (arrival.index - departure.index) < (best!.1.index - best!.0.index) {
                    best = (departure, arrival)
                }
            }
            guard let (departure, arrival) = best, !departure.passed, let time = departure.departure else { continue }
            guard time <= end, time >= now.addingTimeInterval(-tolerance(for: trip)) else { continue }
            result.append(Journey(trip: trip, origin: departure, destination: arrival))
        }
        return result.sorted { $0.departureTime < $1.departureTime }
    }

    /// Un bus suivi en direct reste affiché tant qu'il n'a pas quitté le quai ;
    /// un horaire sans suivi disparaît une minute après l'heure.
    static func tolerance(for trip: TripInstance) -> TimeInterval {
        trip.state == .running ? 300 : 60
    }

    /// Une même course listée deux fois (deux quais du même arrêt consécutifs) n'apparaît qu'une fois.
    static func deduplicated(_ departures: [Departure]) -> [Departure] {
        var seen: [String: Departure] = [:]
        for departure in departures {
            let key = "\(departure.tripID)|\(Int(departure.time.timeIntervalSince1970 / 180))"
            if let existing = seen[key], existing.call.index > departure.call.index { continue }
            seen[key] = departure
        }
        return Array(seen.values)
    }
}
