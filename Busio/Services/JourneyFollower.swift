@preconcurrency import CoreLocation
import Observation
import UserNotifications
import BusioKit

/// Itinéraire en cours : temps réel toutes les 45 s (correspondances, plan B),
/// GPS pour savoir si l'on est dans le bus et prévenir avant la descente.
/// Le GPS tourne en arrière-plan (indicateur bleu) jusqu'à l'arrivée.
@Observable
@MainActor
final class JourneyFollower {
    private(set) var followed: FollowedJourney?
    private(set) var isTrackingLocation = false

    @ObservationIgnored private var tracker: JourneyTracker?
    @ObservationIgnored private var trackedJourney: PlannedJourney?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var locationTask: Task<Void, Never>?
    @ObservationIgnored private var session: CLBackgroundActivitySession?
    @ObservationIgnored private var lastSaved = Date.distantPast

    init() {
        let stored = AppGroup.store.loadFollowed()
        followed = stored?.isOver(at: Date()) == false ? stored : nil
    }

    var journey: PlannedJourney? { followed?.journey }

    /// L'itinéraire affiché est-il celui qu'on suit ?
    func isFollowing(_ journey: PlannedJourney) -> Bool {
        self.journey?.usesSameBuses(as: journey) ?? false
    }

    func start(journey: PlannedJourney, request: JourneyRequest, title: String, network: Network?, locationAuthorized: Bool) async throws {
        stopTasks()
        // Suivi enregistré avant la Live Activity : il continue même si elle est refusée.
        defer { resume(network: network, locationAuthorized: locationAuthorized) }
        followed = try await JourneyActivityController.start(journey: journey, request: request, title: title, network: network)
    }

    /// Lancement de l'app, retour au premier plan, suivi démarré par Siri ou un raccourci.
    func resume(network: Network?, locationAuthorized: Bool) {
        let stored = AppGroup.store.loadFollowed()
        guard let stored, !stored.isOver(at: Date()) else {
            followed = nil
            stopTasks()
            return
        }
        followed = stored
        if refreshTask == nil {
            refreshTask = Task { [weak self] in await self?.refreshLoop() }
        }
        // Le suivi GPS en arrière-plan ne peut démarrer qu'app ouverte.
        if locationAuthorized, locationTask == nil, let network {
            startLocation(network: network)
        }
    }

    func stop() async {
        stopTasks()
        followed = nil
        await JourneyActivityController.endAll()
        JourneyAlerts.cancelFollowedAlerts()
    }

    func switchToPlanB() async {
        followed = await TripRefresher.switchToPlanB()
        tracker = nil
    }

    func refreshNow() async {
        followed = await TripRefresher.refreshFollowed()
        if followed == nil { stopTasks() }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refreshNow()
            guard followed != nil else { break }
            try? await Task.sleep(for: .seconds(45))
        }
        refreshTask = nil
    }

    private func stopTasks() {
        refreshTask?.cancel()
        refreshTask = nil
        locationTask?.cancel()
        locationTask = nil
        session?.invalidate()
        session = nil
        tracker = nil
        trackedJourney = nil
        isTrackingLocation = false
    }

    #if DEBUG
    /// Captures d'écran : premier bus en retard, correspondance ratée, plan B.
    func simulateMissedTransfer() async {
        // Laisser finir l'actualisation en cours, sinon elle écraserait la simulation.
        let running = refreshTask
        stopTasks()
        await running?.value
        guard var followed = AppGroup.store.loadFollowed(), let journey = followed.journey, journey.rides.count > 1 else { return }
        let first = journey.rides[0]
        let delay = journey.rides[1].departure.timeIntervalSince(first.arrival) + 180
        let calls = first.calls.map { call in
            StopCall(stopID: call.stopID, index: call.index, scheduledArrival: call.scheduledArrival, scheduledDeparture: call.scheduledDeparture,
                     expectedArrival: call.scheduledArrival?.addingTimeInterval(delay), expectedDeparture: call.scheduledDeparture?.addingTimeInterval(delay), passed: false)
        }
        let trip = TripInstance(id: first.tripID, lineID: first.lineID, itineraryID: first.itineraryID, headsign: first.headsign,
                                serviceDay: ServiceDay(containing: first.departure), calls: calls, state: .running, quality: .live, source: .zenbus, vehicle: nil)
        let delayed = journey.updated(with: [trip])
        guard let issue = delayed.issues(now: Date()).first else { return }
        followed.replace(with: delayed)
        followed.issue = issue
        followed.planB = try? await Transit.service.alternative(for: delayed, issue: issue, request: followed.request)
        AppGroup.store.save(followed: followed)
        self.followed = followed
        await JourneyActivityController.update(followed: followed, network: try? await Transit.service.currentNetwork())
    }
    #endif

    // MARK: GPS

    private func startLocation(network: Network) {
        session = CLBackgroundActivitySession()
        isTrackingLocation = true
        // Le GPS prend le relais des rappels de descente programmés à l'heure.
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: (0..<6).map { "busio.alight.\($0)" })
        locationTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard let self, !Task.isCancelled else { break }
                    if let location = update.location { await self.handle(location, network: network) }
                    if self.followed == nil { break }
                }
            } catch {}
            self?.locationTask = nil
            self?.isTrackingLocation = false
            self?.session?.invalidate()
            self?.session = nil
        }
    }

    private func handle(_ location: CLLocation, network: Network) async {
        guard let current = followed, let journey = current.journey else { return }
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 150 else { return }
        let coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        let now = location.timestamp

        // Nouvel itinéraire (plan B) : on repart de zéro ; simple actualisation : on garde l'état.
        if tracker == nil || !(trackedJourney?.usesSameBuses(as: journey) ?? false) {
            tracker = JourneyTracker(journey: journey, network: network, now: now)
        }
        trackedJourney = journey
        guard var tracker else { return }
        let events = tracker.update(location: coordinate, accuracy: location.horizontalAccuracy, speed: location.speed, at: now)
        self.tracker = tracker
        let progress = tracker.progress

        let changed = progress.stage != current.progress?.stage || progress.stopsLeft != current.progress?.stopsLeft
        guard changed || !events.isEmpty || now.timeIntervalSince(lastSaved) > 60 else { return }
        // Repartir du fichier : l'actualisation temps réel a pu changer l'itinéraire ou le plan B entre-temps.
        var stored = AppGroup.store.loadFollowed() ?? current
        stored.progress = progress
        AppGroup.store.save(followed: stored)
        followed = stored
        lastSaved = now
        LocationMemory.store(coordinate)
        if changed || !events.isEmpty {
            await JourneyActivityController.update(followed: stored, network: network, now: now)
        }

        let preferences = AppGroup.store.loadPreferences()
        let context = JourneyContext(followed: stored, network: network)
        for event in events {
            switch event {
            case .approaching(let ride, let stopsLeft) where stopsLeft == 1 && preferences.alightAlerts:
                await JourneyAlerts.notifyAlight(ride: ride, of: journey, stopsLeft: stopsLeft, context: context)
            case .missedStop(let ride) where preferences.alightAlerts:
                await JourneyAlerts.notifyMissedStop(ride: ride, of: journey, context: context)
            default:
                break
            }
        }
        if progress.stage == .arrived {
            locationTask?.cancel()
        }
    }
}

/// Affiche les notifications app ouverte et ouvre le trajet suivi quand on en touche une.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationPresenter()
    @MainActor static var onOpen: (@MainActor (String) -> Void)?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        Task { @MainActor in NotificationPresenter.onOpen?(identifier) }
        completionHandler()
    }
}
