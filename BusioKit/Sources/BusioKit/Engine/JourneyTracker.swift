import Foundation

/// Suit un itinéraire avec le GPS : montée détectée quand on avance sur le tracé du bus,
/// arrêts restants, alerte avant la descente, descente, correspondance suivante.
public struct JourneyTracker: Sendable {
    public enum Stage: Hashable, Codable, Sendable {
        /// En route vers le bus `ride` (marche ou attente).
        case toStop(ride: Int)
        /// Dans le bus `ride`.
        case onboard(ride: Int)
        case arrived

        public var rideIndex: Int? {
            switch self {
            case .toStop(let ride), .onboard(let ride): ride
            case .arrived: nil
            }
        }
    }

    public enum Event: Hashable, Sendable {
        case boarded(ride: Int)
        /// `stopsLeft` = 1 : la descente est le prochain arrêt.
        case approaching(ride: Int, stopsLeft: Int)
        case alighted(ride: Int)
        /// Le bus a dépassé l'arrêt de descente avec nous à bord.
        case missedStop(ride: Int)
    }

    /// État exposé à l'interface et à la Live Activity.
    public struct Progress: Hashable, Codable, Sendable {
        public var stage: Stage
        /// Arrêts restants jusqu'à la descente, descente comprise (dans le bus).
        public var stopsLeft: Int?
        /// Prochain arrêt desservi (dans le bus).
        public var nextStopID: String?
        public var updatedAt: Date

        public var isOnboard: Bool {
            if case .onboard = stage { true } else { false }
        }
    }

    public private(set) var progress: Progress
    private let rides: [RideLeg]
    private let shapes: [RideShape]
    private var offset: Double = 0
    private var boardingHits = 0
    private var stillAtAlight = 0
    private var offRoute = 0
    private var reachedAlight = false
    private var announced: Set<String> = []

    public init(journey: PlannedJourney, network: Network, now: Date = Date()) {
        rides = journey.rides
        shapes = rides.map { RideShape(ride: $0, network: network) }
        let first = rides.firstIndex { $0.arrival > now } ?? rides.count
        progress = Progress(stage: first < rides.count ? .toStop(ride: first) : .arrived, updatedAt: now)
    }

    /// Nouvelle position. `speed` en m/s (négatif ou nil si inconnue), `accuracy` en m.
    public mutating func update(location: Coordinate, accuracy: Double, speed: Double?, at time: Date) -> [Event] {
        progress.updatedAt = time
        let tolerance = min(120, max(35, accuracy * 1.5 + 20))
        let speed = speed.flatMap { $0 >= 0 ? $0 : nil }
        var events: [Event] = []

        if case .toStop(let current) = progress.stage {
            // Montée : sur le tracé d'un des bus restants, au-delà de son arrêt, et en mouvement.
            var boarded: (ride: Int, offset: Double)?
            for index in current..<rides.count {
                let shape = shapes[index]
                let p = shape.project(location)
                guard p.distance <= tolerance, p.offset > 60, p.offset < shape.length + 50 else { continue }
                guard time >= rides[index].departure.addingTimeInterval(-300) else { continue }
                if (speed ?? 0) >= 2.5 || boardingHits > 0 {
                    boarded = (index, p.offset)
                    break
                }
            }
            if let boarded {
                boardingHits += 1
                if boardingHits >= 2 {
                    boardingHits = 0
                    enter(.onboard(ride: boarded.ride), offset: boarded.offset)
                    events.append(.boarded(ride: boarded.ride))
                }
            } else {
                boardingHits = 0
            }
        }

        if case .onboard(let ride) = progress.stage {
            events += onboard(ride: ride, location: location, tolerance: tolerance, speed: speed)
        }
        return events
    }

    private mutating func onboard(ride: Int, location: Coordinate, tolerance: Double, speed: Double?) -> [Event] {
        let shape = shapes[ride]
        let alight = shape.stopCoordinates[shape.stopCoordinates.count - 1]
        let alightOffset = shape.stopOffsets[shape.stopOffsets.count - 1]
        let p = shape.project(location, after: offset - 150)
        let toAlight = location.distance(to: alight)
        var events: [Event] = []

        offRoute = p.distance > max(tolerance, 150) ? offRoute + 1 : 0
        if p.distance <= max(tolerance, 150) { offset = max(offset, p.offset) }
        if toAlight <= max(80, tolerance) { reachedAlight = true }

        // Arrêts restants (descente comprise).
        let remaining = shape.stopOffsets.indices.dropFirst().filter { shape.stopOffsets[$0] > offset + 25 }
        progress.stopsLeft = remaining.count
        progress.nextStopID = remaining.first.map { rides[ride].calls[$0].stopID }
        for count in [2, 1] where remaining.count == count && announced.insert("\(ride)-\(count)").inserted {
            events.append(.approaching(ride: ride, stopsLeft: count))
        }

        // Descente : immobile à l'arrêt, ou à pied hors du tracé tout près de l'arrêt.
        let speed = speed ?? 0
        stillAtAlight = toAlight <= max(60, tolerance) && speed < 2 ? stillAtAlight + 1 : 0
        if stillAtAlight >= 2 || (offRoute >= 2 && speed < 3 && toAlight < 400 && offset >= alightOffset - 400) {
            events.append(.alighted(ride: ride))
            advance(after: ride)
            return events
        }
        // Arrêt dépassé : on s'éloigne de la descente en roulant.
        if reachedAlight, toAlight > 300, speed > 4 {
            events.append(.missedStop(ride: ride))
            advance(after: ride)
            return events
        }
        // Plus sur le tracé, loin de la descente : descendu ailleurs.
        if offRoute >= 3, toAlight >= 400 {
            enter(.toStop(ride: ride), offset: 0)
        }
        return events
    }

    private mutating func advance(after ride: Int) {
        enter(ride + 1 < rides.count ? .toStop(ride: ride + 1) : .arrived, offset: 0)
    }

    private mutating func enter(_ stage: Stage, offset: Double) {
        progress.stage = stage
        progress.stopsLeft = nil
        progress.nextStopID = nil
        self.offset = offset
        stillAtAlight = 0
        offRoute = 0
        reachedAlight = false
    }
}
