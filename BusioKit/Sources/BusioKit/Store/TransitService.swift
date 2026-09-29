import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Point d'entrée des données : topologie, temps réel Zenbus, secours GTFS, caches.
///
/// Stratégie de fiabilité :
/// 1. Zenbus (grille du jour + suivi GPS) fait foi quand il a publié le jour demandé.
/// 2. Sinon, horaires théoriques GTFS, signalés comme tels.
/// 3. Hors ligne : derniers relevés Zenbus du jour (sans suivi), puis GTFS.
public actor TransitService {
    public struct Configuration: Sendable {
        public var cacheDirectory: URL
        /// Dossier contenant `zenbus-static.bin` et `gtfs.zip` embarqués dans l'app.
        public var seedDirectory: URL?
        public var client: ZenbusClient
        public var gtfsURL: URL
        /// Âge maximal d'un relevé temps réel avant nouvelle requête.
        public var liveMaxAge: TimeInterval
        /// Âge au-delà duquel les estimations en cache ne sont plus montrées comme du direct.
        public var liveStaleAge: TimeInterval
        public var staticRefreshInterval: TimeInterval
        public var gtfsRefreshInterval: TimeInterval

        public init(
            cacheDirectory: URL,
            seedDirectory: URL?,
            client: ZenbusClient = ZenbusClient(),
            gtfsURL: URL = URL(string: "https://www.data.gouv.fr/fr/datasets/r/70c9f936-129e-41f4-940a-8e6f272535d1")!,
            liveMaxAge: TimeInterval = 12,
            liveStaleAge: TimeInterval = 120,
            staticRefreshInterval: TimeInterval = 12 * 3600,
            gtfsRefreshInterval: TimeInterval = 3 * 24 * 3600
        ) {
            self.cacheDirectory = cacheDirectory
            self.seedDirectory = seedDirectory
            self.client = client
            self.gtfsURL = gtfsURL
            self.liveMaxAge = liveMaxAge
            self.liveStaleAge = liveStaleAge
            self.staticRefreshInterval = staticRefreshInterval
            self.gtfsRefreshInterval = gtfsRefreshInterval
        }
    }

    struct LiveEntry: Sendable {
        let fetchedAt: Date
        let day: ServiceDay?
        let trips: [TripInstance]
        let alerts: [ServiceAlert]
    }

    public let configuration: Configuration
    private let session: URLSession
    private var network: Network?
    private var gtfs: GTFSSchedule?
    private var gtfsError: String?
    private var live: [String: LiveEntry] = [:]
    private var inflight: [String: Task<[String: LiveEntry], Error>] = [:]
    private var lastLiveSuccess: Date?
    private var lastLiveError: String?
    private var lastLiveDays: [String: ServiceDay] = [:]

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        try? FileManager.default.createDirectory(at: configuration.cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: Fichiers

    private var staticFile: URL { configuration.cacheDirectory.appendingPathComponent("zenbus-static.bin") }
    private var gtfsFile: URL { configuration.cacheDirectory.appendingPathComponent("gtfs.zip") }
    private var liveDirectory: URL { configuration.cacheDirectory.appendingPathComponent("live", isDirectory: true) }

    private func seedFile(_ name: String) -> URL? {
        guard let dir = configuration.seedDirectory else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: Topologie

    /// Réseau : cache → données embarquées → téléchargement.
    public func currentNetwork() async throws -> Network {
        if let network { return network }
        for candidate in [staticFile, seedFile("zenbus-static.bin")].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: candidate), let message = try? ZenbusClient.decodeStatic(data) {
                let network = ZenbusMapper.network(from: message)
                self.network = network
                return network
            }
        }
        let data = try await configuration.client.fetchStaticData()
        let message = try ZenbusClient.decodeStatic(data)
        try? data.write(to: staticFile, options: .atomic)
        let network = ZenbusMapper.network(from: message)
        self.network = network
        return network
    }

    /// Met à jour la topologie et le GTFS si nécessaire. À appeler au lancement et en tâche de fond.
    public func refreshStaticData(force: Bool = false, now: Date = Date()) async {
        let staticAge = Self.modificationDate(staticFile).map { now.timeIntervalSince($0) } ?? .infinity
        let staleDay = network?.publishedDay.map { $0 < ServiceDay(containing: now) } ?? true
        if force || staticAge > configuration.staticRefreshInterval || (staleDay && staticAge > 3600) {
            if let data = try? await configuration.client.fetchStaticData(), let message = try? ZenbusClient.decodeStatic(data) {
                try? data.write(to: staticFile, options: .atomic)
                network = ZenbusMapper.network(from: message)
                live.removeAll()
            }
        }
        let gtfsAge = Self.modificationDate(gtfsFile).map { now.timeIntervalSince($0) } ?? .infinity
        if force || gtfsAge > configuration.gtfsRefreshInterval {
            await downloadGTFS()
        }
    }

    private func downloadGTFS() async {
        do {
            var request = URLRequest(url: configuration.gtfsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.setValue("Busio (iOS)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw TransitError.http(status: http.statusCode, url: configuration.gtfsURL.absoluteString)
            }
            // Valide avant de remplacer le cache.
            let tmp = configuration.cacheDirectory.appendingPathComponent("gtfs-download.zip")
            try data.write(to: tmp, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let schedule = try GTFSSchedule(zipURL: tmp)
            guard schedule.tripCount > 0 else { throw TransitError.noData }
            try data.write(to: gtfsFile, options: .atomic)
            gtfs = schedule
            gtfsError = nil
        } catch {
            gtfsError = error.localizedDescription
        }
    }

    /// Horaires théoriques : cache → données embarquées.
    public func schedule() -> GTFSSchedule? {
        if let gtfs { return gtfs }
        for candidate in [gtfsFile, seedFile("gtfs.zip")].compactMap({ $0 }) where FileManager.default.fileExists(atPath: candidate.path) {
            do {
                let schedule = try GTFSSchedule(zipURL: candidate)
                gtfs = schedule
                return schedule
            } catch {
                gtfsError = error.localizedDescription
            }
        }
        return nil
    }

    // MARK: Temps réel

    /// Relevés Zenbus des sens demandés (cache mémoire, requêtes groupées, repli disque).
    func liveEntries(for itineraryIDs: Set<String>, network: Network, now: Date) async -> [String: LiveEntry] {
        var result: [String: LiveEntry] = [:]
        var missing: Set<String> = []
        for id in itineraryIDs {
            if let entry = live[id], now.timeIntervalSince(entry.fetchedAt) < configuration.liveMaxAge {
                result[id] = entry
            } else {
                missing.insert(id)
            }
        }
        guard !missing.isEmpty else { return result }

        // Au-delà de quelques sens, une seule requête « tout le réseau » est plus efficace.
        let groups: [String?] = missing.count > 6 ? [nil] : missing.sorted().map { Optional($0) }
        await withTaskGroup(of: [String: LiveEntry]?.self) { group in
            for itinerary in groups {
                group.addTask { try? await self.fetchLive(itinerary: itinerary, network: network) }
            }
            for await entries in group {
                guard let entries else { continue }
                for (id, entry) in entries { result[id] = entry }
            }
        }

        // Repli : dernier relevé connu (mémoire puis disque), dégradé s'il est ancien.
        for id in missing where result[id] == nil {
            if let entry = live[id] ?? diskEntry(itinerary: id, network: network) {
                result[id] = degraded(entry, now: now)
            }
        }
        return result
    }

    private func fetchLive(itinerary: String?, network: Network) async throws -> [String: LiveEntry] {
        let key = itinerary ?? "*"
        if let task = inflight[key] { return try await task.value }
        let client = configuration.client
        let directory = liveDirectory
        let task = Task<[String: LiveEntry], Error>.detached {
            let data = try await client.pollData(itinerary: itinerary)
            let message = try ZenbusClient.decodeLive(data)
            let snapshot = ZenbusMapper.snapshot(from: message, network: network)
            let fetchedAt = Date()
            var entries: [String: LiveEntry] = [:]
            let tripsByItinerary = Dictionary(grouping: snapshot.trips) { $0.itineraryID ?? "" }
            var ids = Set(snapshot.serviceDays.keys)
            if let itinerary { ids.insert(itinerary) }
            for id in ids {
                entries[id] = LiveEntry(fetchedAt: fetchedAt, day: snapshot.serviceDays[id], trips: tripsByItinerary[id] ?? [], alerts: snapshot.alerts)
            }
            if let itinerary {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: directory.appendingPathComponent("\(itinerary).bin"), options: .atomic)
            }
            return entries
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        do {
            let entries = try await task.value
            for (id, entry) in entries {
                live[id] = entry
                if let day = entry.day { lastLiveDays[id] = day }
            }
            lastLiveSuccess = Date()
            lastLiveError = nil
            return entries
        } catch {
            lastLiveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    private func diskEntry(itinerary: String, network: Network) -> LiveEntry? {
        let url = liveDirectory.appendingPathComponent("\(itinerary).bin")
        guard let data = try? Data(contentsOf: url), let date = Self.modificationDate(url),
              let message = try? ZenbusClient.decodeLive(data) else { return nil }
        let snapshot = ZenbusMapper.snapshot(from: message, network: network)
        return LiveEntry(fetchedAt: date, day: snapshot.serviceDays[itinerary], trips: snapshot.trips.filter { $0.itineraryID == itinerary }, alerts: snapshot.alerts)
    }

    /// Un relevé trop ancien garde la grille du jour mais perd le suivi en direct.
    private func degraded(_ entry: LiveEntry, now: Date) -> LiveEntry {
        guard now.timeIntervalSince(entry.fetchedAt) > configuration.liveStaleAge else { return entry }
        let trips = entry.trips.map { trip -> TripInstance in
            let calls = trip.calls.map {
                StopCall(stopID: $0.stopID, index: $0.index, scheduledArrival: $0.scheduledArrival, scheduledDeparture: $0.scheduledDeparture, expectedArrival: nil, expectedDeparture: nil, passed: false)
            }
            let state: TripState = trip.state == .cancelled ? .cancelled : .planned
            return TripInstance(id: trip.id, lineID: trip.lineID, itineraryID: trip.itineraryID, headsign: trip.headsign, serviceDay: trip.serviceDay, calls: calls, state: state, quality: .planned, source: .zenbus, vehicle: nil)
        }
        return LiveEntry(fetchedAt: entry.fetchedAt, day: entry.day, trips: trips, alerts: entry.alerts)
    }

    // MARK: Requêtes haut niveau

    struct Resolved: Sendable {
        let trips: [TripInstance]
        let alerts: [ServiceAlert]
        let status: FeedStatus
    }

    /// Courses des sens demandés sur la fenêtre, Zenbus d'abord, GTFS en secours.
    func resolveTrips(itineraries: [Itinerary], stopIDs: Set<String>, network: Network, now: Date, horizon: TimeInterval) async -> Resolved {
        let ids = Set(itineraries.map(\.id))
        let entries = await liveEntries(for: ids, network: network, now: now)
        let days = Set([ServiceDay(containing: now).previous, ServiceDay(containing: now), ServiceDay(containing: now.addingTimeInterval(horizon))])

        var zenbusTrips: [TripInstance] = []
        var coverage: Set<String> = []
        var alerts: [String: ServiceAlert] = [:]
        for itinerary in itineraries {
            guard let entry = entries[itinerary.id] else { continue }
            for alert in entry.alerts where alert.concerns(lineID: itinerary.lineID) && alert.isActive(at: now) { alerts[alert.id] = alert }
            guard let day = entry.day, days.contains(day) else { continue }
            coverage.insert(TripPlanner.coverageKey(lineID: itinerary.lineID, itineraryID: itinerary.id, day: day))
            zenbusTrips += entry.trips
        }

        let todayKeys = Set(itineraries.map { TripPlanner.coverageKey(lineID: $0.lineID, itineraryID: $0.id, day: ServiceDay(containing: now)) })
        let coveredToday = todayKeys.intersection(coverage).count
        let needsFallback = coverage.count < itineraries.count * days.count
        var gtfsTrips: [TripInstance] = []
        if needsFallback, let schedule = schedule() {
            gtfsTrips = schedule.trips(servingAny: stopIDs, from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(horizon), network: network)
        }
        let trips = TripPlanner.merge(zenbus: zenbusTrips, coverage: coverage, gtfs: gtfsTrips)

        let status: FeedStatus
        let fetchedAny = entries.values.contains { now.timeIntervalSince($0.fetchedAt) < configuration.liveStaleAge }
        if coveredToday == todayKeys.count, !todayKeys.isEmpty, fetchedAny {
            status = FeedStatus(kind: .live, detail: nil, lastLiveUpdate: lastLiveSuccess)
        } else if coveredToday > 0 {
            status = FeedStatus(kind: .partial, detail: "Temps réel indisponible sur certaines lignes : horaires théoriques affichés.", lastLiveUpdate: lastLiveSuccess)
        } else if trips.isEmpty && schedule() == nil {
            status = FeedStatus(kind: .unavailable, detail: lastLiveError ?? "Aucune donnée disponible.", lastLiveUpdate: lastLiveSuccess)
        } else if !entries.isEmpty && fetchedAny {
            status = FeedStatus(kind: .theoretical, detail: "Zenbus n'a pas publié la grille d'aujourd'hui : horaires théoriques, sans suivi des bus.", lastLiveUpdate: lastLiveSuccess)
        } else {
            status = FeedStatus(kind: .theoretical, detail: "Zenbus injoignable (\(lastLiveError ?? "hors ligne")) : horaires théoriques.", lastLiveUpdate: lastLiveSuccess)
        }
        return Resolved(trips: trips, alerts: alerts.values.sorted { $0.severity > $1.severity }, status: status)
    }

    /// Prochains départs d'un arrêt.
    public func board(for area: StopArea, now: Date = Date(), horizon: TimeInterval = 3 * 3600) async throws -> StopBoard {
        let network = try await currentNetwork()
        let itineraries = network.itineraries(serving: area)
        let stopIDs = Set(area.stopIDs)
        let resolved = await resolveTrips(itineraries: itineraries, stopIDs: stopIDs, network: network, now: now, horizon: horizon)
        let departures = TripPlanner.departures(from: resolved.trips, at: stopIDs, now: now, horizon: horizon)
        return StopBoard(area: area, departures: departures, alerts: resolved.alerts, status: resolved.status, generatedAt: now)
    }

    /// Trajets directs entre deux arrêts.
    public func plan(from origin: StopArea, to destination: StopArea, now: Date = Date(), horizon: TimeInterval = 4 * 3600) async throws -> JourneyPlan {
        let network = try await currentNetwork()
        let originIDs = Set(origin.stopIDs), destinationIDs = Set(destination.stopIDs)
        let itineraries = network.itineraries.filter { itinerary in
            guard let first = itinerary.stopIDs.firstIndex(where: originIDs.contains) else { return false }
            return itinerary.stopIDs[(first + 1)...].contains(where: destinationIDs.contains)
        }
        let resolved = await resolveTrips(itineraries: itineraries, stopIDs: originIDs, network: network, now: now, horizon: horizon)
        let journeys = TripPlanner.journeys(from: resolved.trips, origin: originIDs, destination: destinationIDs, now: now, horizon: horizon)
        return JourneyPlan(from: origin, to: destination, journeys: journeys, alerts: resolved.alerts, status: resolved.status, generatedAt: now)
    }

    /// Courses du jour d'un sens de ligne (fiche ligne).
    public func trips(of itinerary: Itinerary, now: Date = Date()) async throws -> (trips: [TripInstance], status: FeedStatus) {
        let network = try await currentNetwork()
        let resolved = await resolveTrips(itineraries: [itinerary], stopIDs: Set(itinerary.stopIDs), network: network, now: now, horizon: 3 * 3600)
        let trips = resolved.trips.filter { $0.itineraryID == itinerary.id || ($0.itineraryID == nil && $0.lineID == itinerary.lineID) }
        return (trips, resolved.status)
    }

    /// Bus actuellement suivis sur le réseau (carte).
    public func runningTrips(lineIDs: Set<String>? = nil, now: Date = Date()) async throws -> [TripInstance] {
        let network = try await currentNetwork()
        let itineraries = network.itineraries.filter { lineIDs?.contains($0.lineID) ?? true }
        let entries = await liveEntries(for: Set(itineraries.map(\.id)), network: network, now: now)
        return entries.values.flatMap(\.trips).filter { $0.state == .running && $0.vehicle != nil }
    }

    // MARK: Diagnostic

    public struct Diagnostics: Sendable {
        public let networkVersion: Int64?
        public let networkDay: ServiceDay?
        public let lineCount: Int
        public let stopCount: Int
        public let gtfs: GTFSSchedule.FeedInfo?
        public let gtfsTripCount: Int
        public let gtfsError: String?
        public let gtfsFileDate: Date?
        public let staticFileDate: Date?
        public let lastLiveSuccess: Date?
        public let lastLiveError: String?
        /// Jours publiés par Zenbus lors des derniers relevés.
        public let zenbusDays: [ServiceDay]
    }

    public func diagnostics() -> Diagnostics {
        let schedule = schedule()
        return Diagnostics(
            networkVersion: network?.version,
            networkDay: network?.publishedDay,
            lineCount: network?.lines.count ?? 0,
            stopCount: network?.areas.count ?? 0,
            gtfs: schedule?.info,
            gtfsTripCount: schedule?.tripCount ?? 0,
            gtfsError: gtfsError,
            gtfsFileDate: Self.modificationDate(gtfsFile) ?? seedFile("gtfs.zip").flatMap(Self.modificationDate),
            staticFileDate: Self.modificationDate(staticFile) ?? seedFile("zenbus-static.bin").flatMap(Self.modificationDate),
            lastLiveSuccess: lastLiveSuccess,
            lastLiveError: lastLiveError,
            zenbusDays: Array(Set(lastLiveDays.values)).sorted()
        )
    }
}
