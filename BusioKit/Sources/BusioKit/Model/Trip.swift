import Foundation

/// Provenance d'un horaire.
public enum DataSource: String, Codable, Sendable {
    /// API Zenbus (même source que l'app officielle).
    case zenbus
    /// GTFS open data (horaires théoriques publiés sur data.gouv.fr).
    case gtfs
}

/// Fiabilité d'un horaire, du plus sûr au moins sûr.
public enum TimingQuality: Int, Codable, Sendable, Comparable {
    /// Bus en route, suivi GPS en direct.
    case live = 0
    /// Estimation Zenbus, bus pas encore parti.
    case estimated = 1
    /// Horaire planifié du jour (Zenbus).
    case planned = 2
    /// Horaire théorique GTFS (secours).
    case theoretical = 3

    public static func < (lhs: TimingQuality, rhs: TimingQuality) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum TripState: String, Codable, Sendable {
    case planned
    case running
    case finished
    case cancelled
}

/// Passage d'une course à un quai.
public struct StopCall: Hashable, Codable, Sendable {
    public let stopID: String
    /// Position dans la course (0 = départ).
    public let index: Int
    public let scheduledArrival: Date?
    public let scheduledDeparture: Date?
    public let expectedArrival: Date?
    public let expectedDeparture: Date?
    /// Le bus est déjà passé à ce quai.
    public let passed: Bool

    public init(stopID: String, index: Int, scheduledArrival: Date?, scheduledDeparture: Date?, expectedArrival: Date?, expectedDeparture: Date?, passed: Bool) {
        self.stopID = stopID
        self.index = index
        self.scheduledArrival = scheduledArrival
        self.scheduledDeparture = scheduledDeparture
        self.expectedArrival = expectedArrival
        self.expectedDeparture = expectedDeparture
        self.passed = passed
    }

    public var scheduled: Date? { scheduledDeparture ?? scheduledArrival }
    public var expected: Date? { expectedDeparture ?? expectedArrival }
    /// Meilleure estimation de l'heure de départ du quai.
    public var departure: Date? { expectedDeparture ?? expectedArrival ?? scheduled }
    /// Meilleure estimation de l'heure d'arrivée au quai.
    public var arrival: Date? { expectedArrival ?? expectedDeparture ?? scheduledArrival ?? scheduledDeparture }
}

/// Position d'un bus.
public struct VehicleSnapshot: Hashable, Codable, Sendable {
    public let id: String
    public let coordinate: Coordinate
    public let heading: Double?
    public let timestamp: Date?
    /// Distance parcourue depuis le départ (m).
    public let distanceTravelled: Int?
    /// Dernier quai desservi (index dans la course).
    public let previousStopIndex: Int?

    public init(id: String, coordinate: Coordinate, heading: Double?, timestamp: Date?, distanceTravelled: Int?, previousStopIndex: Int?) {
        self.id = id
        self.coordinate = coordinate
        self.heading = heading
        self.timestamp = timestamp
        self.distanceTravelled = distanceTravelled
        self.previousStopIndex = previousStopIndex
    }

    /// Position vieille de plus de `threshold` secondes.
    public func isStale(at now: Date, threshold: TimeInterval = 180) -> Bool {
        guard let timestamp else { return true }
        return now.timeIntervalSince(timestamp) > threshold
    }
}

/// Une course (un bus faisant un sens de ligne à une heure donnée).
public struct TripInstance: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let lineID: String
    public let itineraryID: String?
    public let headsign: String
    public let serviceDay: ServiceDay
    public let calls: [StopCall]
    public let state: TripState
    public let quality: TimingQuality
    public let source: DataSource
    public let vehicle: VehicleSnapshot?

    public init(id: String, lineID: String, itineraryID: String?, headsign: String, serviceDay: ServiceDay, calls: [StopCall], state: TripState, quality: TimingQuality, source: DataSource, vehicle: VehicleSnapshot?) {
        self.id = id
        self.lineID = lineID
        self.itineraryID = itineraryID
        self.headsign = headsign
        self.serviceDay = serviceDay
        self.calls = calls
        self.state = state
        self.quality = quality
        self.source = source
        self.vehicle = vehicle
    }

    public var firstDeparture: Date? { calls.first?.scheduled ?? calls.first?.departure }
    public var lastArrival: Date? { calls.last?.arrival }
}
