import Foundation
import Observation
import BusioKit

@Observable
@MainActor
final class CommuteModel {
    var direction: CommuteDirection
    /// L'utilisateur a choisi le sens à la main (sinon il suit l'heure).
    var isManualDirection = false
    private(set) var snapshot: CommuteSnapshot?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var walk: TimeInterval?
    private(set) var walkIsMeasured = false

    init(preferences: UserPreferences) {
        direction = preferences.commute.direction(at: Date())
    }

    func select(_ direction: CommuteDirection) {
        guard direction != self.direction else { return }
        self.direction = direction
        isManualDirection = true
        snapshot = AppGroup.store.loadSnapshot(direction)
    }

    /// Resynchronise le sens automatique (ex. au retour au premier plan).
    func syncDirection(with preferences: UserPreferences, now: Date = Date()) {
        guard !isManualDirection else { return }
        let automatic = preferences.commute.direction(at: now)
        if automatic != direction {
            direction = automatic
            snapshot = AppGroup.store.loadSnapshot(automatic)
        }
    }

    func refresh(app: AppModel, now: Date = Date()) async {
        let commute = app.preferences.commute
        guard commute.isConfigured else { return }
        if snapshot == nil { snapshot = AppGroup.store.loadSnapshot(direction) }
        isLoading = true
        defer { isLoading = false }

        // Temps de marche réel jusqu'à l'arrêt de départ (Plans), sinon valeur des réglages.
        if let network = app.network, let origin = commute.origin(for: direction)?.resolve(in: network),
           let measured = await app.walkingTime(to: origin) {
            walk = measured
            walkIsMeasured = true
            WalkMemory.store(measured, for: direction)
        } else {
            walk = WalkMemory.walk(for: direction) ?? commute.fallbackWalk(for: direction)
            walkIsMeasured = false
        }

        do {
            let fresh = try await CommuteRefresher.refresh(
                direction: direction,
                walk: walk,
                options: [.updateActivity, .updateAlerts, .reloadWidgets, .autoStartActivity],
                now: now
            )
            snapshot = fresh
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    var nextJourney: Journey? {
        guard let snapshot else { return nil }
        return CommuteRefresher.nextJourney(in: snapshot, now: Date())
    }

    func followNext() async throws {
        guard let snapshot, let journey = nextJourney else { return }
        try await CommuteActivityController.start(journey: journey, snapshot: snapshot)
    }

    func follow(_ journey: Journey) async throws {
        guard let snapshot else { return }
        try await CommuteActivityController.start(journey: journey, snapshot: snapshot)
    }
}
