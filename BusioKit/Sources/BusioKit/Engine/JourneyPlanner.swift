import Foundation

/// Calcul d'itinéraires porte à porte avec correspondances (algorithme RAPTOR).
///
/// Chaque « tour » ajoute un bus : le tour 1 trouve les trajets directs, le tour 2
/// ceux avec une correspondance, etc. On obtient ainsi, pour une heure de départ,
/// le meilleur itinéraire pour chaque nombre de correspondances.
public struct JourneyPlanner: Sendable {
    public let network: Network
    public let options: RoutingOptions

    private let trips: [PlannerTrip]
    private let stopIDs: [String]
    private let stopIndex: [String: Int]
    private let coordinates: [Coordinate]
    /// Correspondances à pied entre quais proches.
    private let footpaths: [[Footpath]]

    struct PlannerTrip: Sendable {
        let trip: TripInstance
        /// Position de chaque passage retenu dans `trip.calls`.
        let callIndices: [Int]
        let stops: [Int]
        let departures: [Double]
        let arrivals: [Double]
        let boardable: [Bool]
    }

    struct Footpath: Sendable {
        let to: Int
        let walk: Double
        let distance: Double
    }

    enum Parent: Sendable {
        case none
        case inherited
        case access(walk: Double, distance: Double)
        case ride(trip: Int, board: Int, alight: Int)
        case transfer(from: Int, walk: Double, distance: Double)
    }

    /// Rayon des correspondances à pied entre deux arrêts.
    static let transferRadius = 400.0

    public init(network: Network, trips: [TripInstance], options: RoutingOptions) {
        self.network = network
        self.options = options
        stopIDs = network.stops.map(\.id)
        coordinates = network.stops.map(\.coordinate)
        let index = Dictionary(network.stops.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        stopIndex = index

        self.trips = trips.compactMap { trip -> PlannerTrip? in
            guard trip.state != .finished else { return nil }
            var callIndices: [Int] = [], stops: [Int] = [], departures: [Double] = [], arrivals: [Double] = [], boardable: [Bool] = []
            for (position, call) in trip.calls.enumerated() {
                guard let stop = index[call.stopID], let departure = call.departure, let arrival = call.arrival else { continue }
                callIndices.append(position)
                stops.append(stop)
                departures.append(departure.timeIntervalSinceReferenceDate)
                arrivals.append(arrival.timeIntervalSinceReferenceDate)
                boardable.append(!call.passed && trip.state != .cancelled)
            }
            guard stops.count > 1 else { return nil }
            return PlannerTrip(trip: trip, callIndices: callIndices, stops: stops, departures: departures, arrivals: arrivals, boardable: boardable)
        }

        let radius = min(Self.transferRadius, options.maxWalkDistance)
        var footpaths = [[Footpath]](repeating: [], count: coordinates.count)
        for a in coordinates.indices {
            for b in coordinates.indices where a != b {
                let distance = coordinates[a].distance(to: coordinates[b])
                if distance <= radius {
                    footpaths[a].append(Footpath(to: b, walk: options.walkTime(distance), distance: distance))
                }
            }
        }
        self.footpaths = footpaths
    }

    // MARK: Recherches

    /// Itinéraires partant à partir de `date`, du plus tôt au plus tard.
    public func journeys(from origin: Place, to destination: Place, departingAfter date: Date, limit: Int = 6, horizon: TimeInterval = 4 * 3600) -> [PlannedJourney] {
        let access = accessStops(for: origin), egress = accessStops(for: destination)
        var found: [String: PlannedJourney] = [:]
        if let walk = walkOnly(from: origin, to: destination, at: date) { found[walk.id] = walk }
        guard !access.isEmpty, !egress.isEmpty else { return Array(found.values) }

        var time = date.timeIntervalSinceReferenceDate
        let end = time + horizon
        var iterations = 0
        // Un même bus n'est proposé qu'une fois en premier trajet (sinon on le « rattrape » à l'arrêt suivant).
        var usedFirstTrips: Set<String> = []
        while time <= end, iterations < limit * 3 {
            iterations += 1
            let batch = search(access: access, egress: egress, origin: origin, destination: destination, departure: time, excludedFirstTrips: usedFirstTrips)
            guard !batch.isEmpty else { break }
            for journey in batch {
                found[journey.id] = journey
                if let first = journey.firstRide { usedFirstTrips.insert(first.tripID) }
            }
            // Recherche suivante : juste après le premier bus pris par le départ le plus tôt.
            let next = batch.compactMap { journey -> Double? in
                guard let ride = journey.firstRide else { return nil }
                let walk = journey.legs.first.flatMap { leg -> Double? in
                    if case .walk(let w) = leg { return w.duration }
                    return nil
                } ?? 0
                return ride.departure.timeIntervalSinceReferenceDate - walk + 1
            }.min()
            guard let next, next > time else { break }
            time = next
            if found.values.filter({ !$0.isWalkOnly }).count >= limit * 2 { break }
        }
        return rank(Array(found.values), keepDominated: false)
    }

    /// « Arriver avant » : le meilleur itinéraire arrivant juste avant l'heure et le premier juste après.
    public func journeys(from origin: Place, to destination: Place, arrivingBy deadline: Date, notBefore now: Date? = nil) -> (journeys: [PlannedJourney], before: PlannedJourney?, after: PlannedJourney?) {
        var start = deadline.addingTimeInterval(-3 * 3600)
        if let now, now > start { start = now }
        let all = journeys(from: origin, to: destination, departingAfter: start, limit: 12, horizon: deadline.timeIntervalSince(start) + 90 * 60)
        let valid = all.filter { !$0.isCancelled }

        let arrivingBefore = valid.filter { $0.arrival <= deadline }
        let arrivingAfter = valid.filter { $0.arrival > deadline }
        let before: PlannedJourney?
        switch options.preference {
        case .fastest:
            before = arrivingBefore.max { ($0.arrival, $0.departure, -$0.transfers) < ($1.arrival, $1.departure, -$1.transfers) }
        case .fewestTransfers:
            before = arrivingBefore.min { ($0.transfers, -$0.arrival.timeIntervalSinceReferenceDate) < ($1.transfers, -$1.arrival.timeIntervalSinceReferenceDate) }
        case .leastWaiting:
            before = arrivingBefore.min { ($0.transferWait, -$0.arrival.timeIntervalSinceReferenceDate) < ($1.transferWait, -$1.arrival.timeIntervalSinceReferenceDate) }
        }
        let after = arrivingAfter.min { ($0.arrival, $0.transfers) < ($1.arrival, $1.transfers) }

        // Ordre d'affichage : juste avant, juste après, puis les autres arrivant à l'heure (du plus tard au plus tôt).
        var ordered: [PlannedJourney] = []
        if let before { ordered.append(before) }
        if let after { ordered.append(after) }
        let others = arrivingBefore.filter { $0.id != before?.id }.sorted { $0.arrival > $1.arrival }
        ordered += others.prefix(3)
        return (ordered, before, after)
    }

    /// Classe selon la préférence et retire les itinéraires dominés.
    func rank(_ journeys: [PlannedJourney], keepDominated: Bool) -> [PlannedJourney] {
        var list = journeys
        if !keepDominated {
            list = list.filter { candidate in
                !list.contains { other in
                    other.id != candidate.id && !other.isCancelled
                        && other.departure >= candidate.departure && other.arrival <= candidate.arrival
                        && other.transfers <= candidate.transfers && other.walkDuration <= candidate.walkDuration + 300
                        && (other.departure > candidate.departure || other.arrival < candidate.arrival || other.transfers < candidate.transfers)
                }
            }
        }
        switch options.preference {
        case .fastest:
            return list.sorted { ($0.arrival, $0.transfers, -$0.departure.timeIntervalSinceReferenceDate) < ($1.arrival, $1.transfers, -$1.departure.timeIntervalSinceReferenceDate) }
        case .fewestTransfers:
            return list.sorted { ($0.transfers, $0.arrival) < ($1.transfers, $1.arrival) }
        case .leastWaiting:
            return list.sorted { ($0.transferWait, $0.arrival) < ($1.transferWait, $1.arrival) }
        }
    }

    // MARK: Accès

    struct Access: Sendable {
        let stop: Int
        let walk: Double
        let distance: Double
    }

    /// Quais accessibles à pied depuis un lieu (0 m pour les quais de l'arrêt choisi).
    func accessStops(for place: Place) -> [Access] {
        var result: [Int: Access] = [:]
        if let area = place.stopArea(in: network) {
            for id in area.stopIDs {
                if let stop = stopIndex[id] { result[stop] = Access(stop: stop, walk: 0, distance: 0) }
            }
        }
        for (stop, coordinate) in coordinates.enumerated() where result[stop] == nil {
            let distance = coordinate.distance(to: place.coordinate)
            if distance <= options.maxWalkDistance {
                result[stop] = Access(stop: stop, walk: options.walkTime(distance), distance: distance)
            }
        }
        return Array(result.values)
    }

    private func walkOnly(from origin: Place, to destination: Place, at date: Date) -> PlannedJourney? {
        let distance = origin.coordinate.distance(to: destination.coordinate)
        guard distance <= 2_500 else { return nil }
        let walk = WalkLeg(fromName: origin.name, toName: destination.name, from: origin.coordinate, to: destination.coordinate, start: date, end: date.addingTimeInterval(options.walkTime(distance)), distance: distance)
        return PlannedJourney(legs: [.walk(walk)])
    }

    // MARK: RAPTOR

    private func search(access: [Access], egress: [Access], origin: Place, destination: Place, departure: Double, excludedFirstTrips: Set<String> = []) -> [PlannedJourney] {
        let n = stopIDs.count
        let rounds = options.maxTransfers + 1
        var labels = [[Double]](repeating: [Double](repeating: .infinity, count: n), count: rounds + 1)
        var parents = [[Parent]](repeating: [Parent](repeating: .none, count: n), count: rounds + 1)
        /// Marche nécessaire pour atteindre chaque quai (départage des montées possibles).
        var walked = [[Double]](repeating: [Double](repeating: 0, count: n), count: rounds + 1)
        var best = [Double](repeating: .infinity, count: n)

        for a in access where departure + a.walk < labels[0][a.stop] {
            labels[0][a.stop] = departure + a.walk
            parents[0][a.stop] = .access(walk: a.walk, distance: a.distance)
            walked[0][a.stop] = a.distance
            best[a.stop] = labels[0][a.stop]
        }

        var results: [PlannedJourney] = []
        var bestArrival = Double.infinity

        for k in 1...rounds {
            labels[k] = labels[k - 1]
            walked[k] = walked[k - 1]
            parents[k] = [Parent](repeating: .inherited, count: n)
            var rideImproved: [Int] = []
            let transferMargin = k > 1 ? options.minTransferTime : 0

            for (t, trip) in trips.enumerated() {
                if k == 1, excludedFirstTrips.contains(trip.trip.id) { continue }
                var boardedAt: Int?
                for c in trip.stops.indices {
                    let stop = trip.stops[c]
                    if let boardedAt {
                        let arrival = trip.arrivals[c]
                        if arrival < labels[k][stop], arrival < best[stop] {
                            labels[k][stop] = arrival
                            best[stop] = arrival
                            walked[k][stop] = 0
                            parents[k][stop] = .ride(trip: t, board: boardedAt, alight: c)
                            rideImproved.append(stop)
                        }
                    }
                    // Montée : au premier quai possible, puis on « remonte » plus loin sur la même
                    // course si cela demande moins de marche (même arrivée, moins d'effort).
                    if c < trip.stops.count - 1, trip.boardable[c],
                       labels[k - 1][stop] + transferMargin <= trip.departures[c] {
                        if let current = boardedAt {
                            if walked[k - 1][stop] <= walked[k - 1][trip.stops[current]] { boardedAt = c }
                        } else {
                            boardedAt = c
                        }
                    }
                }
            }
            guard !rideImproved.isEmpty else { break }

            // Correspondances à pied depuis les quais atteints en bus à ce tour.
            for stop in Set(rideImproved) {
                guard case .ride = parents[k][stop] else { continue }
                for path in footpaths[stop] {
                    let arrival = labels[k][stop] + path.walk
                    if arrival < labels[k][path.to], arrival < best[path.to] {
                        labels[k][path.to] = arrival
                        best[path.to] = arrival
                        walked[k][path.to] = path.distance
                        parents[k][path.to] = .transfer(from: stop, walk: path.walk, distance: path.distance)
                    }
                }
            }

            // Meilleure arrivée à destination avec k bus. La marche finale compte 1,5 fois :
            // mieux vaut arriver une minute plus tard que marcher dix minutes de plus.
            var target: (stop: Int, total: Double, cost: Double, egress: Access)?
            for e in egress {
                // Seules les arrivées obtenues à ce tour (en bus ou à pied après un bus) comptent.
                switch parents[k][e.stop] {
                case .ride, .transfer: break
                default: continue
                }
                let total = labels[k][e.stop] + e.walk
                let cost = total + e.walk * 0.5
                if cost < (target?.cost ?? .infinity) { target = (e.stop, total, cost, e) }
            }
            if let target, target.total < bestArrival {
                if let journey = reconstruct(round: k, stop: target.stop, egress: target.egress, labels: labels, parents: parents, origin: origin, destination: destination) {
                    bestArrival = target.total
                    results.append(journey)
                }
            }
        }
        return results
    }

    private func reconstruct(round: Int, stop: Int, egress: Access, labels: [[Double]], parents: [[Parent]], origin: Place, destination: Place) -> PlannedJourney? {
        enum Piece { case ride(trip: Int, board: Int, alight: Int), transfer(from: Int, to: Int, walk: Double, distance: Double) }
        var pieces: [Piece] = []
        var k = round, s = stop
        var accessWalk: (walk: Double, distance: Double, stop: Int)?
        var guardCounter = 0
        loop: while guardCounter < 64 {
            guardCounter += 1
            switch parents[k][s] {
            case .none:
                return nil
            case .inherited:
                k -= 1
                if k < 0 { return nil }
            case .access(let walk, let distance):
                accessWalk = (walk, distance, s)
                break loop
            case .ride(let trip, let board, let alight):
                pieces.insert(.ride(trip: trip, board: board, alight: alight), at: 0)
                s = trips[trip].stops[board]
                k -= 1
                if k < 0 { return nil }
            case .transfer(let from, let walk, let distance):
                pieces.insert(.transfer(from: from, to: s, walk: walk, distance: distance), at: 0)
                s = from
            }
        }
        guard let accessWalk, !pieces.isEmpty else { return nil }

        var legs: [JourneyLeg] = []
        var cursor: Date?
        for piece in pieces {
            switch piece {
            case .ride(let t, let board, let alight):
                let planner = trips[t]
                let calls = rideCalls(planner, board: board, alight: alight)
                let ride = RideLeg(
                    tripID: planner.trip.id, lineID: planner.trip.lineID, itineraryID: planner.trip.itineraryID,
                    headsign: planner.trip.headsign, calls: calls, state: planner.trip.state,
                    quality: planner.trip.quality, source: planner.trip.source, vehicle: planner.trip.vehicle
                )
                if legs.isEmpty, accessWalk.distance >= 30 {
                    // Départ à pied juste à temps, avec une minute de marge à l'arrêt.
                    let end = ride.departure.addingTimeInterval(-60)
                    legs.append(.walk(WalkLeg(
                        fromName: origin.name, toName: stopName(accessWalk.stop),
                        from: origin.coordinate, to: coordinates[accessWalk.stop],
                        start: end.addingTimeInterval(-accessWalk.walk), end: end, distance: accessWalk.distance
                    )))
                }
                legs.append(.ride(ride))
                cursor = ride.arrival
            case .transfer(let from, let to, let walk, let distance):
                let start = cursor ?? Date(timeIntervalSinceReferenceDate: labels[round][from])
                // Les quais d'un même arrêt ne sont pas une « marche ».
                if network.area(containingStop: stopIDs[from])?.id != network.area(containingStop: stopIDs[to])?.id {
                    legs.append(.walk(WalkLeg(
                        fromName: stopName(from), toName: stopName(to),
                        from: coordinates[from], to: coordinates[to],
                        start: start, end: start.addingTimeInterval(walk), distance: distance
                    )))
                }
                cursor = start.addingTimeInterval(walk)
            }
        }
        if egress.distance >= 30, let end = cursor {
            legs.append(.walk(WalkLeg(
                fromName: stopName(egress.stop), toName: destination.name,
                from: coordinates[egress.stop], to: destination.coordinate,
                start: end, end: end.addingTimeInterval(egress.walk), distance: egress.distance
            )))
        }
        return PlannedJourney(legs: legs)
    }

    private func rideCalls(_ planner: PlannerTrip, board: Int, alight: Int) -> [StopCall] {
        Array(planner.trip.calls[planner.callIndices[board]...planner.callIndices[alight]])
    }

    private func stopName(_ index: Int) -> String {
        network.stop(stopIDs[index])?.name ?? stopIDs[index]
    }
}
