import Foundation

/// Point de départ ou d'arrivée d'un itinéraire : position, adresse, lieu ou arrêt.
public struct Place: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case currentLocation
        case stop
        case address
        case pointOfInterest
    }

    public let id: String
    public var name: String
    public var subtitle: String?
    public var coordinate: Coordinate
    public var kind: Kind
    /// Arrêt correspondant (lieux de type `.stop`).
    public var stopAreaID: String?

    public init(id: String? = nil, name: String, subtitle: String? = nil, coordinate: Coordinate, kind: Kind, stopAreaID: String? = nil) {
        self.id = id ?? Place.makeID(kind: kind, coordinate: coordinate, stopAreaID: stopAreaID)
        self.name = name
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.kind = kind
        self.stopAreaID = stopAreaID
    }

    public init(stop area: StopArea) {
        self.init(name: area.name, subtitle: "Arrêt de bus", coordinate: area.coordinate, kind: .stop, stopAreaID: area.id)
    }

    public static func currentLocation(_ coordinate: Coordinate) -> Place {
        Place(id: "here", name: "Ma position", coordinate: coordinate, kind: .currentLocation)
    }

    private static func makeID(kind: Kind, coordinate: Coordinate, stopAreaID: String?) -> String {
        if let stopAreaID { return "stop:\(stopAreaID)" }
        return "\(kind.rawValue):\(String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude))"
    }

    /// Arrêt désigné par ce lieu, retrouvé même si Zenbus renumérote ses quais.
    public func stopArea(in network: Network) -> StopArea? {
        guard kind == .stop, let stopAreaID else { return nil }
        return PlaceRef(areaID: stopAreaID, name: name, coordinate: coordinate).resolve(in: network)
    }
}

/// Arrêt mémorisé (favori, domicile, travail). Garde nom et position pour
/// retrouver l'arrêt si Zenbus renumérote ses quais.
public struct PlaceRef: Codable, Hashable, Sendable, Identifiable {
    public let areaID: String
    public let name: String
    public let coordinate: Coordinate

    public var id: String { areaID }

    public init(areaID: String, name: String, coordinate: Coordinate) {
        self.areaID = areaID
        self.name = name
        self.coordinate = coordinate
    }

    public init(_ area: StopArea) {
        self.init(areaID: area.id, name: area.name, coordinate: area.coordinate)
    }

    public func resolve(in network: Network) -> StopArea? {
        if let area = network.area(areaID) { return area }
        let key = TextFormatting.searchKey(name)
        return network.areas
            .filter { TextFormatting.searchKey($0.name) == key }
            .min { $0.coordinate.distance(to: coordinate) < $1.coordinate.distance(to: coordinate) }
            .flatMap { $0.coordinate.distance(to: coordinate) < 600 ? $0 : nil }
    }
}

/// Contrainte horaire d'une recherche.
public enum TimeConstraint: Codable, Hashable, Sendable {
    case now
    case departAt(Date)
    case arriveBy(Date)
}

/// Préférences de calcul.
public struct RoutingOptions: Codable, Hashable, Sendable {
    public enum Preference: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Arrivée la plus tôt.
        case fastest
        /// Le moins de correspondances.
        case fewestTransfers
        /// Le moins d'attente aux correspondances.
        case leastWaiting

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .fastest: "Le plus rapide"
            case .fewestTransfers: "Moins de correspondances"
            case .leastWaiting: "Moins d'attente"
            }
        }
    }

    public var preference: Preference
    /// Distance à vol d'oiseau maximale jusqu'à un arrêt (départ, arrivée, correspondance).
    public var maxWalkDistance: Double
    /// Vitesse de marche (m/s).
    public var walkSpeed: Double
    /// Marge minimale pour changer de bus.
    public var minTransferTime: TimeInterval
    public var maxTransfers: Int

    public init(preference: Preference = .fastest, maxWalkDistance: Double = 1_000, walkSpeed: Double = 1.25, minTransferTime: TimeInterval = 120, maxTransfers: Int = 3) {
        self.preference = preference
        self.maxWalkDistance = maxWalkDistance
        self.walkSpeed = walkSpeed
        self.minTransferTime = minTransferTime
        self.maxTransfers = maxTransfers
    }

    /// Les rues ne sont pas des lignes droites : distance × 1,3.
    public static let detourFactor = 1.3

    public func walkTime(_ meters: Double) -> TimeInterval {
        (meters * Self.detourFactor / walkSpeed).rounded()
    }
}

/// Une recherche d'itinéraire.
public struct JourneyRequest: Codable, Hashable, Sendable {
    public var from: Place
    public var to: Place
    public var time: TimeConstraint
    public var options: RoutingOptions

    public init(from: Place, to: Place, time: TimeConstraint = .now, options: RoutingOptions = RoutingOptions()) {
        self.from = from
        self.to = to
        self.time = time
        self.options = options
    }
}
