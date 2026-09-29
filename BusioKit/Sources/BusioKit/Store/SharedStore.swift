import Foundation

/// Préférences de l'utilisateur, partagées entre l'app, les widgets et les intents.
public struct UserPreferences: Codable, Hashable, Sendable {
    public var commute: CommuteSettings
    public var favorites: [PlaceRef]
    public var leaveNowAlerts: Bool
    public var delayAlerts: Bool
    /// Seuil (minutes) déclenchant une alerte retard.
    public var delayThresholdMinutes: Int
    public var autoLiveActivity: Bool
    public var hasCompletedOnboarding: Bool

    public init(
        commute: CommuteSettings = CommuteSettings(),
        favorites: [PlaceRef] = [],
        leaveNowAlerts: Bool = true,
        delayAlerts: Bool = true,
        delayThresholdMinutes: Int = 3,
        autoLiveActivity: Bool = true,
        hasCompletedOnboarding: Bool = false
    ) {
        self.commute = commute
        self.favorites = favorites
        self.leaveNowAlerts = leaveNowAlerts
        self.delayAlerts = delayAlerts
        self.delayThresholdMinutes = delayThresholdMinutes
        self.autoLiveActivity = autoLiveActivity
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    public init(from decoder: Decoder) throws {
        // Tolère les champs ajoutés dans de futures versions.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UserPreferences()
        commute = try c.decodeIfPresent(CommuteSettings.self, forKey: .commute) ?? d.commute
        favorites = try c.decodeIfPresent([PlaceRef].self, forKey: .favorites) ?? d.favorites
        leaveNowAlerts = try c.decodeIfPresent(Bool.self, forKey: .leaveNowAlerts) ?? d.leaveNowAlerts
        delayAlerts = try c.decodeIfPresent(Bool.self, forKey: .delayAlerts) ?? d.delayAlerts
        delayThresholdMinutes = try c.decodeIfPresent(Int.self, forKey: .delayThresholdMinutes) ?? d.delayThresholdMinutes
        autoLiveActivity = try c.decodeIfPresent(Bool.self, forKey: .autoLiveActivity) ?? d.autoLiveActivity
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
    }
}

/// Dernier état du trajet, lu par les widgets et la Live Activity.
public struct CommuteSnapshot: Codable, Hashable, Sendable {
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

    public let generatedAt: Date
    public let direction: CommuteDirection
    public let originName: String
    public let destinationName: String
    public let journeys: [Journey]
    public let recommendedID: String?
    public let status: FeedStatus
    public let lines: [LineStyle]
    public let walk: TimeInterval
    public let buffer: TimeInterval

    public init(generatedAt: Date, direction: CommuteDirection, originName: String, destinationName: String, journeys: [Journey], recommendedID: String?, status: FeedStatus, lines: [LineStyle], walk: TimeInterval, buffer: TimeInterval) {
        self.generatedAt = generatedAt
        self.direction = direction
        self.originName = originName
        self.destinationName = destinationName
        self.journeys = journeys
        self.recommendedID = recommendedID
        self.status = status
        self.lines = lines
        self.walk = walk
        self.buffer = buffer
    }

    public func style(for lineID: String) -> LineStyle? { lines.first { $0.id == lineID } }

    /// Trajets encore attrapables à `date`.
    public func upcoming(at date: Date) -> [Journey] {
        journeys.filter { $0.departureTime >= date.addingTimeInterval(-30) }
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
    private func snapshotURL(_ direction: CommuteDirection) -> URL { containerURL.appendingPathComponent("commute-\(direction.rawValue).json") }

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

    public func loadPreferences() -> UserPreferences {
        guard let data = try? Data(contentsOf: preferencesURL),
              let prefs = try? Self.decoder.decode(UserPreferences.self, from: data) else { return UserPreferences() }
        return prefs
    }

    public func save(_ preferences: UserPreferences) {
        guard let data = try? Self.encoder.encode(preferences) else { return }
        try? data.write(to: preferencesURL, options: .atomic)
    }

    public func loadSnapshot(_ direction: CommuteDirection) -> CommuteSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(direction)) else { return nil }
        return try? Self.decoder.decode(CommuteSnapshot.self, from: data)
    }

    public func save(_ snapshot: CommuteSnapshot) {
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        try? data.write(to: snapshotURL(snapshot.direction), options: .atomic)
    }
}

extension TransitService {
    /// Calcule l'état du trajet quotidien pour un sens (app, widgets, intents).
    public func commuteSnapshot(settings: CommuteSettings, direction: CommuteDirection, walk: TimeInterval? = nil, now: Date = Date()) async throws -> CommuteSnapshot {
        let network = try await currentNetwork()
        guard let originRef = settings.origin(for: direction), let destinationRef = settings.destination(for: direction),
              let origin = originRef.resolve(in: network), let destination = destinationRef.resolve(in: network) else {
            throw TransitError.noData
        }
        let plan = try await self.plan(from: origin, to: destination, now: now, horizon: 5 * 3600)
        let journeys = Array(plan.journeys.prefix(8))
        let recommended = settings.recommended(in: journeys, direction: direction, on: now)
        let lineIDs = Set(journeys.map(\.lineID))
        return CommuteSnapshot(
            generatedAt: now,
            direction: direction,
            originName: origin.name,
            destinationName: destination.name,
            journeys: journeys,
            recommendedID: recommended?.id,
            status: plan.status,
            lines: network.lines.filter { lineIDs.contains($0.id) }.map(CommuteSnapshot.LineStyle.init),
            walk: walk ?? settings.fallbackWalk(for: direction),
            buffer: TimeInterval(settings.bufferMinutes * 60)
        )
    }
}
