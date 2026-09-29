import BackgroundTasks
import Foundation
import Observation
import SwiftUI
import BusioKit

@Observable
@MainActor
final class AppModel {
    enum Tab: String, Hashable {
        case commute, map, lines, search
    }

    var selectedTab: Tab = .commute
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
        // Captures d'écran automatiques (CI) : `-demo` configure un trajet, `-tab map` ouvre un onglet.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-demo") {
            preferences.commute.home = PlaceRef(areaID: "839690006", name: "Gares Castres", coordinate: Coordinate(latitude: 43.5984, longitude: 2.2303))
            preferences.commute.work = PlaceRef(areaID: "843740007", name: "Gares Mazamet", coordinate: Coordinate(latitude: 43.4982, longitude: 2.3740))
            preferences.favorites = [PlaceRef(areaID: "836670001", name: "Gare SNCF", coordinate: Coordinate(latitude: 43.6003, longitude: 2.2352))]
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

    func handle(_ url: URL) {
        guard url.scheme == "busio" else { return }
        switch url.host() {
        case "setup": showOnboarding = true
        case "map": selectedTab = .map
        default: selectedTab = .commute
        }
    }
}

/// Rafraîchissement en arrière-plan (au bon vouloir d'iOS) autour des heures de trajet.
enum BackgroundRefresh {
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "busio") + ".refresh" }

    static func schedule(preferences: UserPreferences, now: Date = Date()) {
        guard preferences.commute.isConfigured else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = nextRun(settings: preferences.commute, now: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Toutes les 10 min pendant les créneaux de trajet, sinon 45 min avant le prochain.
    static func nextRun(settings: CommuteSettings, now: Date) -> Date {
        for offset in 0..<8 {
            guard let day = TransitClock.calendar.date(byAdding: .day, value: offset, to: now), settings.isWorkday(day) else { continue }
            let windows = [
                (CommuteSettings.date(minute: settings.arriveByMinute, on: day).addingTimeInterval(-100 * 60),
                 CommuteSettings.date(minute: settings.arriveByMinute, on: day)),
                (CommuteSettings.date(minute: settings.leaveWorkMinute, on: day).addingTimeInterval(-45 * 60),
                 CommuteSettings.date(minute: settings.leaveWorkMinute, on: day).addingTimeInterval(90 * 60)),
            ]
            for (start, end) in windows where end > now {
                return start > now ? start : now.addingTimeInterval(10 * 60)
            }
        }
        return now.addingTimeInterval(6 * 3600)
    }

    static func run() async {
        _ = try? await CommuteRefresher.refresh(options: .all)
        schedule(preferences: AppGroup.store.loadPreferences())
    }
}
