import Foundation

/// Trajet à pied.
public struct WalkLeg: Hashable, Codable, Sendable {
    public let fromName: String
    public let toName: String
    public let from: Coordinate
    public let to: Coordinate
    public let start: Date
    public let end: Date
    public let distance: Double

    public init(fromName: String, toName: String, from: Coordinate, to: Coordinate, start: Date, end: Date, distance: Double) {
        self.fromName = fromName
        self.toName = toName
        self.from = from
        self.to = to
        self.start = start
        self.end = end
        self.distance = distance
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Trajet en bus : une course, de la montée à la descente.
public struct RideLeg: Hashable, Codable, Sendable {
    public let tripID: String
    public let lineID: String
    public let itineraryID: String?
    public let headsign: String
    /// Passages de la montée à la descente, inclus.
    public let calls: [StopCall]
    public let state: TripState
    public let quality: TimingQuality
    public let source: DataSource
    public let vehicle: VehicleSnapshot?

    public init(tripID: String, lineID: String, itineraryID: String?, headsign: String, calls: [StopCall], state: TripState, quality: TimingQuality, source: DataSource, vehicle: VehicleSnapshot?) {
        precondition(calls.count >= 2, "une montée et une descente")
        self.tripID = tripID
        self.lineID = lineID
        self.itineraryID = itineraryID
        self.headsign = headsign
        self.calls = calls
        self.state = state
        self.quality = quality
        self.source = source
        self.vehicle = vehicle
    }

    public var board: StopCall { calls[0] }
    public var alight: StopCall { calls[calls.count - 1] }
    public var departure: Date { board.departure ?? .distantFuture }
    public var arrival: Date { alight.arrival ?? .distantFuture }
    public var stopCount: Int { calls.count - 1 }

    public var delay: TimeInterval? {
        guard let expected = board.expected, let scheduled = board.scheduled else { return nil }
        return expected.timeIntervalSince(scheduled)
    }

    /// Arrêts restants avant que le bus n'atteigne la montée (s'il roule).
    public var stopsAway: Int? {
        guard state == .running, let previous = vehicle?.previousStopIndex else { return nil }
        return max(0, board.index - previous)
    }

    public var isCancelled: Bool { state == .cancelled }
}

public enum JourneyLeg: Hashable, Codable, Sendable {
    case walk(WalkLeg)
    case ride(RideLeg)

    public var start: Date {
        switch self {
        case .walk(let walk): walk.start
        case .ride(let ride): ride.departure
        }
    }

    public var end: Date {
        switch self {
        case .walk(let walk): walk.end
        case .ride(let ride): ride.arrival
        }
    }
}

/// Un itinéraire complet, porte à porte.
public struct PlannedJourney: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let legs: [JourneyLeg]

    public init(legs: [JourneyLeg]) {
        self.legs = legs
        let rides = legs.compactMap { leg -> String? in
            if case .ride(let ride) = leg { return "\(ride.tripID)@\(ride.board.index)-\(ride.alight.index)" }
            return nil
        }
        id = rides.isEmpty ? "walk" : rides.joined(separator: "+")
    }

    public var rides: [RideLeg] {
        legs.compactMap { if case .ride(let ride) = $0 { ride } else { nil } }
    }

    public var walks: [WalkLeg] {
        legs.compactMap { if case .walk(let walk) = $0 { walk } else { nil } }
    }

    public var firstRide: RideLeg? { rides.first }
    public var isWalkOnly: Bool { rides.isEmpty }

    /// Heure à laquelle partir du point de départ.
    public var departure: Date { legs.first?.start ?? .distantFuture }
    public var arrival: Date { legs.last?.end ?? .distantFuture }
    public var duration: TimeInterval { arrival.timeIntervalSince(departure) }
    public var transfers: Int { max(0, rides.count - 1) }
    public var walkDuration: TimeInterval { walks.reduce(0) { $0 + $1.duration } }
    public var walkDistance: Double { walks.reduce(0) { $0 + $1.distance } }

    /// Attente cumulée aux correspondances (hors attente au premier arrêt).
    public var transferWait: TimeInterval {
        var total: TimeInterval = 0
        var previousEnd: Date?
        var ridesSeen = 0
        for leg in legs {
            if case .ride(let ride) = leg {
                if ridesSeen > 0, let previousEnd { total += max(0, ride.departure.timeIntervalSince(previousEnd)) }
                ridesSeen += 1
            }
            previousEnd = leg.end
        }
        return total
    }

    /// Fiabilité globale : celle du bus le moins bien suivi.
    public var quality: TimingQuality {
        rides.map(\.quality).max() ?? .planned
    }

    public var isCancelled: Bool { rides.contains(where: \.isCancelled) }
}

/// Résultat d'une recherche.
public struct JourneySearchResult: Sendable {
    public let request: JourneyRequest
    public let journeys: [PlannedJourney]
    /// « Arriver avant » : itinéraire arrivant juste avant l'heure demandée…
    public let closestBeforeID: String?
    /// … et celui arrivant juste après.
    public let closestAfterID: String?
    public let origin: Place
    public let destination: Place
    public let alerts: [ServiceAlert]
    public let status: FeedStatus
    public let generatedAt: Date

    public init(request: JourneyRequest, journeys: [PlannedJourney], closestBeforeID: String?, closestAfterID: String?, origin: Place, destination: Place, alerts: [ServiceAlert], status: FeedStatus, generatedAt: Date) {
        self.request = request
        self.journeys = journeys
        self.closestBeforeID = closestBeforeID
        self.closestAfterID = closestAfterID
        self.origin = origin
        self.destination = destination
        self.alerts = alerts
        self.status = status
        self.generatedAt = generatedAt
    }
}
