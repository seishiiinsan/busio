import Foundation
import UserNotifications
import BusioKit

/// Notifications locales : « pars maintenant », retards, suppressions, correspondances, descente.
enum JourneyAlerts {
    private static let delayMemoryKey = "busio.notified-delays"

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private static func authorized() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
    }

    /// Programme (ou recale) le rappel de départ d'un itinéraire. `id` distingue favoris et suivi.
    static func scheduleLeave(for journey: PlannedJourney, context: JourneyContext, id: String, preferences: UserPreferences, now: Date = Date()) async {
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

        let badge = context.badge(ride.lineID)
        let stop = context.stopName(ride.board.stopID)
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
            heads.body = "\(context.title) : bus \(badge) à \(TimeText.clock(ride.departure)) (\(ride.quality.label.lowercased()))."
            heads.threadIdentifier = "trip"
            add(heads, id: soonID, at: soon, now: now)
        }
    }

    private static func add(_ content: UNMutableNotificationContent, id: String, at date: Date, now: Date) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSince(now)), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Alerte immédiate quand un bus de l'itinéraire prend du retard ou est supprimé (une fois par palier).
    static func notifyDisruptions(in journey: PlannedJourney, context: JourneyContext, preferences: UserPreferences, now: Date = Date()) async {
        guard preferences.delayAlerts, await authorized() else { return }
        let defaults = UserDefaults(suiteName: AppGroup.identifier)
        var memory = defaults?.dictionary(forKey: delayMemoryKey) as? [String: Int] ?? [:]
        for ride in journey.rides where ride.departure > now && ride.departure.timeIntervalSince(now) < 60 * 60 {
            let badge = context.badge(ride.lineID)
            let scheduled = ride.board.scheduled.map(TimeText.clock) ?? TimeText.clock(ride.departure)
            let content = UNMutableNotificationContent()
            content.threadIdentifier = "trip"
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            if ride.isCancelled {
                guard memory[ride.tripID] != -1 else { continue }
                memory[ride.tripID] = -1
                content.title = "Bus \(badge) de \(scheduled) supprimé"
                content.body = "Ouvre Busio pour un autre itinéraire vers \(context.destinationName)."
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

    // MARK: Itinéraire suivi

    /// Correspondance menacée ou bus supprimé, avec le plan B.
    static func notifyIssue(_ issue: JourneyIssue, journey: PlannedJourney, planB: PlannedJourney?, context: JourneyContext) async {
        guard await authorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = context.issueTitle(issue, journey: journey)
        content.body = context.issueMessage(issue, journey: journey, planB: planB)
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "followed"
        content.relevanceScore = 1
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "busio.issue", content: content, trigger: nil))
    }

    private static func alightID(_ ride: Int) -> String { "busio.alight.\(ride)" }

    /// Sans GPS : rappel de descente programmé au départ de l'avant-dernier arrêt.
    /// Avec le GPS, `notifyAlight` remplace ce rappel (même identifiant) au bon moment.
    static func scheduleAlight(for journey: PlannedJourney, context: JourneyContext, preferences: UserPreferences, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: (0..<6).map(alightID))
        guard preferences.alightAlerts, await authorized() else { return }
        for (index, ride) in journey.rides.enumerated() where ride.arrival > now && !ride.isCancelled {
            let before = ride.calls[ride.calls.count - 2]
            let fireAt = ride.calls.count > 2 ? (before.departure ?? ride.departure) : ride.departure.addingTimeInterval(30)
            guard fireAt > now.addingTimeInterval(5) else { continue }
            add(alightContent(ride: ride, stopsLeft: 1, context: context), id: alightID(index), at: fireAt, now: now)
        }
    }

    /// GPS : la descente approche (dès maintenant).
    static func notifyAlight(ride index: Int, of journey: PlannedJourney, stopsLeft: Int, context: JourneyContext) async {
        guard journey.rides.indices.contains(index), await authorized() else { return }
        let content = alightContent(ride: journey.rides[index], stopsLeft: stopsLeft, context: context)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alightID(index), content: content, trigger: nil))
    }

    /// GPS : l'arrêt de descente est passé.
    static func notifyMissedStop(ride index: Int, of journey: PlannedJourney, context: JourneyContext) async {
        guard journey.rides.indices.contains(index), await authorized() else { return }
        let ride = journey.rides[index]
        let content = UNMutableNotificationContent()
        content.title = "Arrêt dépassé"
        content.body = "Tu as passé \(context.stopName(ride.alight.stopID)). Descends au prochain arrêt et ouvre Busio pour repartir."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "followed"
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alightID(index), content: content, trigger: nil))
    }

    static func cancelFollowedAlerts() {
        let ids = (0..<6).map(alightID) + ["busio.leave.followed", "busio.soon.followed", "busio.issue"]
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    private static func alightContent(ride: RideLeg, stopsLeft: Int, context: JourneyContext) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let stop = context.stopName(ride.alight.stopID)
        content.title = stopsLeft <= 1 ? "Descends au prochain arrêt" : "Descente dans \(stopsLeft) arrêts"
        content.body = "\(stop) · bus \(context.badge(ride.lineID)), arrivée \(TimeText.clock(ride.arrival))."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "followed"
        content.relevanceScore = 1
        return content
    }
}
