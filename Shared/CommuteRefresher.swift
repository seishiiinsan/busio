import Foundation
import WidgetKit
import BusioKit

/// Recalcule le trajet et propage le résultat (widgets, Live Activity, notifications).
/// Utilisé par l'app, la tâche de fond et les intents.
enum CommuteRefresher {
    struct Options: OptionSet, Sendable {
        let rawValue: Int
        static let reloadWidgets = Options(rawValue: 1 << 0)
        static let updateAlerts = Options(rawValue: 1 << 1)
        static let updateActivity = Options(rawValue: 1 << 2)
        /// Démarre la Live Activity si un bus approche (app au premier plan uniquement).
        static let autoStartActivity = Options(rawValue: 1 << 3)
        static let all: Options = [.reloadWidgets, .updateAlerts, .updateActivity]
    }

    @discardableResult
    static func refresh(direction: CommuteDirection? = nil, walk: TimeInterval? = nil, options: Options = .all, now: Date = Date()) async throws -> CommuteSnapshot {
        let preferences = AppGroup.store.loadPreferences()
        guard preferences.commute.isConfigured else { throw TransitError.noData }
        let direction = direction ?? preferences.commute.direction(at: now)
        let walk = walk ?? WalkMemory.walk(for: direction) ?? preferences.commute.fallbackWalk(for: direction)
        let snapshot = try await Transit.service.commuteSnapshot(settings: preferences.commute, direction: direction, walk: walk, now: now)
        AppGroup.store.save(snapshot)

        if options.contains(.updateActivity) {
            await CommuteActivityController.refresh(with: snapshot, now: now)
        }
        if options.contains(.autoStartActivity), preferences.autoLiveActivity, preferences.commute.isWorkday(now),
           CommuteActivityController.isEnabled, CommuteActivityController.current == nil,
           let journey = nextJourney(in: snapshot, now: now),
           journey.departureTime.timeIntervalSince(now) < 25 * 60 {
            try? await CommuteActivityController.start(journey: journey, snapshot: snapshot)
        }
        if options.contains(.updateAlerts) {
            await CommuteAlerts.update(with: snapshot, preferences: preferences, now: now)
        }
        if options.contains(.reloadWidgets) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        return snapshot
    }

    /// Bus conseillé s'il est encore attrapable, sinon le prochain.
    static func nextJourney(in snapshot: CommuteSnapshot, now: Date) -> Journey? {
        let upcoming = snapshot.upcoming(at: now).filter { !$0.isCancelled }
        let reachable = upcoming.filter { LeaveAdvice(journey: $0, walk: snapshot.walk, buffer: snapshot.buffer).isReachable(from: now) }
        return reachable.first { $0.id == snapshot.recommendedID } ?? reachable.first ?? upcoming.first
    }
}

/// Dernier temps de marche calculé par sens (partagé avec les widgets).
enum WalkMemory {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: AppGroup.identifier) }

    static func walk(for direction: CommuteDirection, maxAge: TimeInterval = 6 * 3600) -> TimeInterval? {
        guard let entry = defaults?.dictionary(forKey: "busio.walk.\(direction.rawValue)"),
              let value = entry["value"] as? Double, let date = entry["date"] as? Double,
              Date().timeIntervalSince1970 - date < maxAge else { return nil }
        return value
    }

    static func store(_ walk: TimeInterval, for direction: CommuteDirection) {
        defaults?.set(["value": walk, "date": Date().timeIntervalSince1970], forKey: "busio.walk.\(direction.rawValue)")
    }
}
