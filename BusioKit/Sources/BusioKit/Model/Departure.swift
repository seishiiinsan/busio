import Foundation

/// Un départ à un arrêt.
public struct Departure: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let tripID: String
    public let lineID: String
    public let itineraryID: String?
    public let headsign: String
    public let call: StopCall
    public let state: TripState
    public let quality: TimingQuality
    public let source: DataSource
    public let vehicle: VehicleSnapshot?
    /// Nombre de quais restants avant l'arrêt (si le bus roule).
    public let stopsAway: Int?

    public init(trip: TripInstance, call: StopCall) {
        id = "\(trip.id)@\(call.index)"
        tripID = trip.id
        lineID = trip.lineID
        itineraryID = trip.itineraryID
        headsign = trip.headsign
        self.call = call
        state = trip.state
        quality = call.expected == nil && trip.quality < .planned ? .planned : trip.quality
        source = trip.source
        vehicle = trip.vehicle
        if trip.state == .running, let previous = trip.vehicle?.previousStopIndex {
            stopsAway = max(0, call.index - previous)
        } else {
            stopsAway = nil
        }
    }

    /// Heure de départ la plus probable.
    public var time: Date { call.departure ?? .distantFuture }
    public var scheduledTime: Date? { call.scheduled }
    public var isCancelled: Bool { state == .cancelled }

    /// Retard (positif) ou avance (négatif) en secondes, si connu.
    public var delay: TimeInterval? {
        guard let expected = call.expected, let scheduled = call.scheduled else { return nil }
        return expected.timeIntervalSince(scheduled)
    }
}

/// État global des sources pour un résultat.
public struct FeedStatus: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Temps réel Zenbus à jour.
        case live
        /// Temps réel partiel : certaines lignes en horaires théoriques.
        case partial
        /// Horaires théoriques uniquement (Zenbus muet ou grille du jour absente).
        case theoretical
        /// Aucune donnée.
        case unavailable
    }

    public let kind: Kind
    public let detail: String?
    public let lastLiveUpdate: Date?

    public init(kind: Kind, detail: String?, lastLiveUpdate: Date?) {
        self.kind = kind
        self.detail = detail
        self.lastLiveUpdate = lastLiveUpdate
    }
}

public struct StopBoard: Sendable {
    public struct Group: Identifiable, Sendable {
        public let id: String
        public let lineID: String
        public let headsign: String
        public let departures: [Departure]
    }

    public let area: StopArea
    public let departures: [Departure]
    public let alerts: [ServiceAlert]
    public let status: FeedStatus
    public let generatedAt: Date

    public init(area: StopArea, departures: [Departure], alerts: [ServiceAlert], status: FeedStatus, generatedAt: Date) {
        self.area = area
        self.departures = departures
        self.alerts = alerts
        self.status = status
        self.generatedAt = generatedAt
    }

    /// Départs regroupés par ligne et direction, dans l'ordre du réseau.
    public func groups(in network: Network) -> [Group] {
        let lineOrder = Dictionary(uniqueKeysWithValues: network.lines.enumerated().map { ($1.id, $0) })
        return Dictionary(grouping: departures) { "\($0.lineID)|\($0.headsign)" }
            .map { key, values in
                Group(id: key, lineID: values[0].lineID, headsign: values[0].headsign, departures: values.sorted { $0.time < $1.time })
            }
            .sorted {
                let l0 = lineOrder[$0.lineID] ?? .max, l1 = lineOrder[$1.lineID] ?? .max
                return l0 != l1 ? l0 < l1 : $0.headsign < $1.headsign
            }
    }
}
