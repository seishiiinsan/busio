import Foundation

/// Préférences de l'utilisateur, partagées entre l'app, les widgets et les intents.
public struct UserPreferences: Codable, Hashable, Sendable {
    public var favoriteTrips: [FavoriteTrip]
    /// Arrêts favoris.
    public var favorites: [PlaceRef]
    /// Derniers lieux recherchés (le plus récent d'abord).
    public var recentPlaces: [Place]
    public var routing: RoutingOptions
    public var leaveNowAlerts: Bool
    public var delayAlerts: Bool
    /// Seuil (minutes) déclenchant une alerte retard.
    public var delayThresholdMinutes: Int
    /// Démarre la Live Activity d'un trajet favori quand son bus approche.
    public var autoLiveActivity: Bool
    public var hasCompletedOnboarding: Bool
    /// Lieux nommés (« au boulot », « à la maison » dans la recherche).
    public var home: Place?
    public var work: Place?
    /// Itinéraire suivi : alerte avant la descente (GPS).
    public var alightAlerts: Bool
    /// Itinéraire suivi : correspondance menacée, plan B.
    public var transferAlerts: Bool

    public init(
        favoriteTrips: [FavoriteTrip] = [],
        favorites: [PlaceRef] = [],
        recentPlaces: [Place] = [],
        routing: RoutingOptions = RoutingOptions(),
        leaveNowAlerts: Bool = true,
        delayAlerts: Bool = true,
        delayThresholdMinutes: Int = 3,
        autoLiveActivity: Bool = true,
        hasCompletedOnboarding: Bool = false,
        home: Place? = nil,
        work: Place? = nil,
        alightAlerts: Bool = true,
        transferAlerts: Bool = true
    ) {
        self.favoriteTrips = favoriteTrips
        self.favorites = favorites
        self.recentPlaces = recentPlaces
        self.routing = routing
        self.leaveNowAlerts = leaveNowAlerts
        self.delayAlerts = delayAlerts
        self.delayThresholdMinutes = delayThresholdMinutes
        self.autoLiveActivity = autoLiveActivity
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.home = home
        self.work = work
        self.alightAlerts = alightAlerts
        self.transferAlerts = transferAlerts
    }

    public init(from decoder: Decoder) throws {
        // Tolère les champs ajoutés ou retirés d'une version à l'autre.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UserPreferences()
        favoriteTrips = (try? c.decodeIfPresent([FavoriteTrip].self, forKey: .favoriteTrips)) ?? d.favoriteTrips
        favorites = (try? c.decodeIfPresent([PlaceRef].self, forKey: .favorites)) ?? d.favorites
        recentPlaces = (try? c.decodeIfPresent([Place].self, forKey: .recentPlaces)) ?? d.recentPlaces
        routing = (try? c.decodeIfPresent(RoutingOptions.self, forKey: .routing)) ?? d.routing
        leaveNowAlerts = (try? c.decodeIfPresent(Bool.self, forKey: .leaveNowAlerts)) ?? d.leaveNowAlerts
        delayAlerts = (try? c.decodeIfPresent(Bool.self, forKey: .delayAlerts)) ?? d.delayAlerts
        delayThresholdMinutes = (try? c.decodeIfPresent(Int.self, forKey: .delayThresholdMinutes)) ?? d.delayThresholdMinutes
        autoLiveActivity = (try? c.decodeIfPresent(Bool.self, forKey: .autoLiveActivity)) ?? d.autoLiveActivity
        hasCompletedOnboarding = (try? c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
        home = try? c.decodeIfPresent(Place.self, forKey: .home)
        work = try? c.decodeIfPresent(Place.self, forKey: .work)
        alightAlerts = (try? c.decodeIfPresent(Bool.self, forKey: .alightAlerts)) ?? d.alightAlerts
        transferAlerts = (try? c.decodeIfPresent(Bool.self, forKey: .transferAlerts)) ?? d.transferAlerts
    }

    /// Mémorise un lieu recherché (sans doublon, 8 au plus).
    public mutating func remember(_ place: Place) {
        guard place.kind != .currentLocation else { return }
        recentPlaces.removeAll { $0.id == place.id }
        recentPlaces.insert(place, at: 0)
        recentPlaces = Array(recentPlaces.prefix(8))
    }
}

/// Style d'une ligne, copié dans les instantanés pour les widgets.
public struct LineStyle: Codable, Hashable, Sendable {
    public let id: String
    public let badge: String
    public let color: RGBColor
    public let textColor: RGBColor

    public init(_ line: Line) {
        id = line.id
        badge = line.badge
        color = line.color
        textColor = line.textColor
    }
}

/// Dernier état d'une recherche, lu par les widgets, la Live Activity et les intents.
public struct TripSnapshot: Codable, Hashable, Sendable {
    public let favoriteID: UUID?
    public let request: JourneyRequest
    public let title: String
    public let originName: String
    public let destinationName: String
    public let journeys: [PlannedJourney]
    public let closestBeforeID: String?
    public let closestAfterID: String?
    public let status: FeedStatus
    public let lines: [LineStyle]
    public let generatedAt: Date

    public init(favoriteID: UUID?, title: String, result: JourneySearchResult, network: Network) {
        self.favoriteID = favoriteID
        request = result.request
        self.title = title
        originName = result.origin.name
        destinationName = result.destination.name
        journeys = Array(result.journeys.prefix(6))
        closestBeforeID = result.closestBeforeID
        closestAfterID = result.closestAfterID
        status = result.status
        let lineIDs = Set(journeys.flatMap { $0.rides.map(\.lineID) })
        lines = network.lines.filter { lineIDs.contains($0.id) }.map(LineStyle.init)
        generatedAt = result.generatedAt
    }

    public func style(for lineID: String) -> LineStyle? { lines.first { $0.id == lineID } }

    public var arrivalDeadline: Date? {
        if case .arriveBy(let date) = request.time { return date }
        return nil
    }

    /// Itinéraires encore faisables à `date` (on peut encore partir à l'heure).
    public func upcoming(at date: Date) -> [PlannedJourney] {
        journeys.filter { $0.departure >= date.addingTimeInterval(-60) }
    }

    /// L'itinéraire à mettre en avant : « juste avant » l'heure d'arrivée s'il est encore faisable,
    /// sinon le prochain.
    public func next(at date: Date) -> PlannedJourney? {
        let upcoming = upcoming(at: date).filter { !$0.isCancelled }
        if let before = upcoming.first(where: { $0.id == closestBeforeID }) { return before }
        return upcoming.min { $0.departure < $1.departure }
    }
}

/// Itinéraire suivi (Live Activity, GPS, correspondances), actualisé en continu.
public struct FollowedJourney: Codable, Hashable, Sendable {
    public let request: JourneyRequest
    public private(set) var journeyID: String
    public private(set) var firstTripID: String?
    public let title: String
    public let startedAt: Date
    /// Itinéraire exact suivi (mêmes bus), horaires à jour.
    public var journey: PlannedJourney?
    /// Problème en cours (correspondance menacée, bus supprimé) et plan B proposé.
    public var issue: JourneyIssue?
    public var planB: PlannedJourney?
    /// Clés des alertes déjà envoyées.
    public var alerted: Set<String>?
    /// Où l'on en est d'après le GPS.
    public var progress: JourneyTracker.Progress?

    public init(request: JourneyRequest, journey: PlannedJourney, title: String, startedAt: Date = Date()) {
        self.request = request
        journeyID = journey.id
        firstTripID = journey.firstRide?.tripID
        self.title = title
        self.startedAt = startedAt
        self.journey = journey
    }

    /// Remplace l'itinéraire (actualisation ou passage au plan B).
    public mutating func replace(with journey: PlannedJourney) {
        self.journey = journey
        journeyID = journey.id
        firstTripID = journey.firstRide?.tripID
    }

    /// Fini depuis un moment : on arrête de suivre.
    public func isOver(at now: Date) -> Bool {
        if let journey { return journey.arrival.addingTimeInterval(15 * 60) < now }
        return startedAt.addingTimeInterval(4 * 3600) < now
    }
}

/// Fichiers partagés dans le conteneur App Group.
public struct SharedStore: Sendable {
    public let containerURL: URL

    public init(containerURL: URL) {
        self.containerURL = containerURL
        try? FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
    }

    public var cacheDirectory: URL { containerURL.appendingPathComponent("Transit", isDirectory: true) }
    private var preferencesURL: URL { containerURL.appendingPathComponent("preferences.json") }
    private var followedURL: URL { containerURL.appendingPathComponent("followed.json") }
    private func snapshotURL(_ key: String) -> URL { containerURL.appendingPathComponent("trip-\(key).json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? Self.encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func loadPreferences() -> UserPreferences { read(UserPreferences.self, from: preferencesURL) ?? UserPreferences() }
    public func save(_ preferences: UserPreferences) { write(preferences, to: preferencesURL) }

    /// Instantané d'un trajet favori (`nil` : dernière recherche libre).
    public func loadSnapshot(favoriteID: UUID?) -> TripSnapshot? { read(TripSnapshot.self, from: snapshotURL(favoriteID?.uuidString ?? "last")) }
    public func save(_ snapshot: TripSnapshot) { write(snapshot, to: snapshotURL(snapshot.favoriteID?.uuidString ?? "last")) }

    public func loadFollowed() -> FollowedJourney? { read(FollowedJourney.self, from: followedURL) }
    public func save(followed: FollowedJourney?) {
        if let followed { write(followed, to: followedURL) } else { try? FileManager.default.removeItem(at: followedURL) }
    }
}

extension TransitService {
    /// Recherche + instantané prêt pour les widgets.
    public func snapshot(for request: JourneyRequest, favoriteID: UUID?, title: String, now: Date = Date()) async throws -> TripSnapshot {
        let network = try await currentNetwork()
        let result = try await planJourney(request, now: now)
        return TripSnapshot(favoriteID: favoriteID, title: title, result: result, network: network)
    }
}
