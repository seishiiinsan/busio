import BackgroundTasks
import Foundation
import Observation
import SwiftUI
import BusioKit

@Observable
@MainActor
final class AppModel {
    enum Tab: String, Hashable {
        case planner, map, lines, search
    }

    var selectedTab: Tab = .planner
    /// Trajet favori à ouvrir dans l'onglet Itinéraire (lien, widget).
    var pendingFavoriteID: UUID?
    /// Écran à ouvrir au lancement (captures automatiques, DEBUG).
    var demoScreen: String?
    var showOnboarding: Bool
    var showSettings = false

    var preferences: UserPreferences {
        didSet {
            guard preferences != oldValue else { return }
            AppGroup.store.save(preferences)
            BackgroundRefresh.schedule(preferences: preferences)
        }
    }

    private(set) var network: Network?
    private(set) var loadError: String?

    let location = LocationService()
    let walking = WalkingTimeService()
    let service = Transit.service

    init() {
        var preferences = AppGroup.store.loadPreferences()
        #if DEBUG
        // Captures d'écran automatiques (CI) : `-demo` crée des favoris, `-tab map` ouvre un onglet.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-demo") {
            let archipel = Place(name: "Archipel", subtitle: "Arrêt de bus", coordinate: Coordinate(latitude: 43.622528, longitude: 2.259509), kind: .stop, stopAreaID: "810270004")
            let mazamet = Place(name: "Gares Mazamet", subtitle: "Arrêt de bus", coordinate: Coordinate(latitude: 43.4982, longitude: 2.3740), kind: .stop, stopAreaID: "843740007")
            let morning = FavoriteTrip(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, from: archipel, to: mazamet, arriveByMinute: 9 * 60)
            var evening = morning.reversed
            evening.id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            evening.arriveByMinute = 17 * 60 + 30
            preferences.favoriteTrips = [morning, evening]
            preferences.favorites = [PlaceRef(areaID: "826710003", name: "Gare SNCF", coordinate: Coordinate(latitude: 43.5991, longitude: 2.2319))]
            preferences.hasCompletedOnboarding = true
            AppGroup.store.save(preferences)
        }
        #endif
        self.preferences = preferences
        showOnboarding = !preferences.hasCompletedOnboarding
        #if DEBUG
        if let index = arguments.firstIndex(of: "-tab"), arguments.indices.contains(index + 1),
           let tab = Tab(rawValue: arguments[index + 1]) {
            selectedTab = tab
        }
        if let index = arguments.firstIndex(of: "-screen"), arguments.indices.contains(index + 1) {
            demoScreen = arguments[index + 1]
            if demoScreen == "results" || demoScreen == "detail" { pendingFavoriteID = preferences.favoriteTrips.first?.id }
        }
        #endif
    }

    func start() async {
        await loadNetwork()
        BackgroundRefresh.schedule(preferences: preferences)
        await service.preload()
        await service.refreshStaticData()
        await loadNetwork()
    }

    func loadNetwork() async {
        do {
            network = try await service.currentNetwork()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func forceRefreshData() async {
        await service.refreshStaticData(force: true)
        await loadNetwork()
    }

    // MARK: Favoris

    func isFavorite(_ area: StopArea) -> Bool {
        preferences.favorites.contains { $0.areaID == area.id }
    }

    func toggleFavorite(_ area: StopArea) {
        if let index = preferences.favorites.firstIndex(where: { $0.areaID == area.id }) {
            preferences.favorites.remove(at: index)
        } else {
            preferences.favorites.append(PlaceRef(area))
        }
    }

    func favoriteAreas() -> [StopArea] {
        guard let network else { return [] }
        return preferences.favorites.compactMap { $0.resolve(in: network) }
    }

    // MARK: Marche

    /// Temps de marche de la position actuelle jusqu'à l'arrêt, s'il est à moins de 3 km.
    func walkingTime(to area: StopArea) async -> TimeInterval? {
        guard let here = await location.currentCoordinate() else { return nil }
        guard here.distance(to: area.coordinate) < 3_000 else { return nil }
        return await walking.walkingTime(from: here, to: area.coordinate)
    }

    // MARK: Liens

    /// busio://planner, busio://map, busio://trip/<uuid>
    func handle(_ url: URL) {
        guard url.scheme == "busio" else { return }
        switch url.host() {
        case "map": selectedTab = .map
        case "trip":
            selectedTab = .planner
            pendingFavoriteID = UUID(uuidString: url.lastPathComponent)
        default: selectedTab = .planner
        }
    }
}

/// Rafraîchissement en arrière-plan (au bon vouloir d'iOS) avant les heures d'arrivée des favoris.
enum BackgroundRefresh {
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "busio") + ".refresh" }

    static func schedule(preferences: UserPreferences, now: Date = Date()) {
        guard !preferences.favoriteTrips.isEmpty || AppGroup.store.loadFollowed() != nil else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = nextRun(favorites: preferences.favoriteTrips, now: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Toutes les 10 min dans les 2 h précédant une heure d'arrivée, sinon juste avant la prochaine fenêtre.
    static func nextRun(favorites: [FavoriteTrip], now: Date) -> Date {
        var windows: [(start: Date, end: Date)] = []
        for offset in 0..<8 {
            guard let day = TransitClock.calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            for favorite in favorites where favorite.appliesArrivalTime(on: day) {
                let deadline = FavoriteTrip.date(minute: favorite.arriveByMinute ?? 0, on: day)
                windows.append((deadline.addingTimeInterval(-2 * 3600), deadline))
            }
        }
        let upcoming = windows.filter { $0.end > now }.sorted { $0.start < $1.start }
        guard let next = upcoming.first else { return now.addingTimeInterval(3 * 3600) }
        return next.start > now ? next.start : now.addingTimeInterval(10 * 60)
    }

    static func run() async {
        await TripRefresher.refreshAll()
        schedule(preferences: AppGroup.store.loadPreferences())
    }
}
