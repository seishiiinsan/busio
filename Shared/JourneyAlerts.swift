import Foundation
import UserNotifications
import BusioKit

/// Notifications locales : « pars maintenant », retards, suppressions.
enum JourneyAlerts {
    private static let delayMemoryKey = "busio.notified-delays"

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private static func authorized() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
    }

    /// Programme (ou recale) le rappel de départ d'un itinéraire. `id` distingue favoris et suivi.
    static func scheduleLeave(for journey: PlannedJourney, snapshot: TripSnapshot, id: String, preferences: UserPreferences, network: Network?, now: Date = Date()) async {
        guard preferences.leaveNowAlerts, await authorized() else { return }
        let center = UNUserNotificationCenter.current()
        let leaveID = "busio.leave.\(id)", soonID = "busio.soon.\(id)"
        center.removePendingNotificationRequests(withIdentifiers: [leaveID, soonID])
        guard !journey.isCancelled, let ride = journey.firstRide else { return }

        let startsWithWalk: Bool
        if case .walk = journey.legs.first { startsWithWalk = true } else { startsWithWalk = false }
        // À pied : prévenir à l'heure de départ ; déjà à l'arrêt : 3 min avant le bus.
        let fireAt = startsWithWalk ? journey.departure : ride.departure.addingTimeInterval(-3 * 60)
        guard fireAt > now, fireAt.timeIntervalSince(now) < 14 * 3600 else { return }

        let badge = snapshot.style(for: ride.lineID)?.badge ?? ""
        let stop = network?.stop(ride.board.stopID)?.name ?? "l'arrêt"
        let content = UNMutableNotificationContent()
        content.title = startsWithWalk ? "Pars maintenant" : "Ton bus arrive"
        content.body = "Bus \(badge) à \(TimeText.clock(ride.departure)) depuis \(stop) · arrivée \(TimeText.clock(journey.arrival))."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "trip"
        content.relevanceScore = 1
        add(content, id: leaveID, at: fireAt, now: now)

        let soon = fireAt.addingTimeInterval(-5 * 60)
        if soon > now.addingTimeInterval(30) {
            let heads = UNMutableNotificationContent()
            heads.title = "Départ dans 5 min"
            heads.body = "\(snapshot.title) : bus \(badge) à \(TimeText.clock(ride.departure)) (\(ride.quality.label.lowercased()))."
            heads.threadIdentifier = "trip"
            add(heads, id: soonID, at: soon, now: now)
        }
    }

    private static func add(_ content: UNMutableNotificationContent, id: String, at date: Date, now: Date) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSince(now)), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Alerte immédiate quand un bus de l'itinéraire prend du retard ou est supprimé (une fois par palier).
    static func notifyDisruptions(in journey: PlannedJourney, snapshot: TripSnapshot, preferences: UserPreferences, now: Date = Date()) async {
        guard preferences.delayAlerts, await authorized() else { return }
        let defaults = UserDefaults(suiteName: AppGroup.identifier)
        var memory = defaults?.dictionary(forKey: delayMemoryKey) as? [String: Int] ?? [:]
        for ride in journey.rides where ride.departure > now && ride.departure.timeIntervalSince(now) < 60 * 60 {
            let badge = snapshot.style(for: ride.lineID)?.badge ?? ""
            let scheduled = ride.board.scheduled.map(TimeText.clock) ?? TimeText.clock(ride.departure)
            let content = UNMutableNotificationContent()
            content.threadIdentifier = "trip"
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            if ride.isCancelled {
                guard memory[ride.tripID] != -1 else { continue }
                memory[ride.tripID] = -1
                content.title = "Bus \(badge) de \(scheduled) supprimé"
                content.body = "Ouvre Busio pour un autre itinéraire vers \(snapshot.destinationName)."
            } else if let delay = ride.delay, ride.quality <= .estimated {
                let minutes = Int((delay / 60).rounded())
                let already = memory[ride.tripID] ?? 0
                guard minutes >= preferences.delayThresholdMinutes, already == 0 || minutes >= already + preferences.delayThresholdMinutes else { continue }
                memory[ride.tripID] = minutes
                content.title = "Bus \(badge) de \(scheduled) : +\(minutes) min"
                content.body = "Départ estimé \(TimeText.clock(ride.departure)), arrivée \(TimeText.clock(journey.arrival))."
            } else {
                continue
            }
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "busio.delay.\(ride.tripID)", content: content, trigger: nil))
        }
        if memory.count > 50 { memory = [:] }
        defaults?.set(memory, forKey: delayMemoryKey)
    }
}
