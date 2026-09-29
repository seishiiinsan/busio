import Foundation
import UserNotifications
import BusioKit

/// Notifications locales : « pars maintenant », retards, suppressions.
enum CommuteAlerts {
    private static let leaveID = "busio.leave-now"
    private static let headsUpID = "busio.leave-soon"
    private static let delayMemoryKey = "busio.notified-delays"

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Replanifie les rappels de départ pour le bus conseillé et signale retards/suppressions.
    static func update(with snapshot: CommuteSnapshot, preferences: UserPreferences, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        center.removePendingNotificationRequests(withIdentifiers: [leaveID, headsUpID])
        let upcoming = snapshot.upcoming(at: now)
        let target = upcoming.first { $0.id == snapshot.recommendedID } ?? upcoming.first { !$0.isCancelled }

        if preferences.leaveNowAlerts, preferences.commute.isWorkday(now), let journey = target {
            let advice = LeaveAdvice(journey: journey, walk: snapshot.walk, buffer: snapshot.buffer)
            let line = snapshot.style(for: journey.lineID)?.badge ?? ""
            let walkMinutes = Int((snapshot.walk / 60).rounded())
            // Ne prévient pas plus de 90 min à l'avance (les horaires évoluent).
            if advice.leaveAt > now, advice.leaveAt.timeIntervalSince(now) < 90 * 60 {
                let content = UNMutableNotificationContent()
                content.title = "Pars maintenant"
                content.body = "Bus \(line) à \(TimeText.clock(journey.departureTime)) depuis \(snapshot.originName) · \(walkMinutes) min à pied."
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.threadIdentifier = "commute"
                content.relevanceScore = 1
                schedule(content, id: leaveID, at: advice.leaveAt, now: now)

                let headsUp = advice.leaveAt.addingTimeInterval(-5 * 60)
                if headsUp > now.addingTimeInterval(30) {
                    let soon = UNMutableNotificationContent()
                    soon.title = "Départ dans 5 min"
                    soon.body = "Prépare-toi pour le \(line) de \(TimeText.clock(journey.departureTime)) (\(journey.quality.label.lowercased()))."
                    soon.interruptionLevel = .active
                    soon.threadIdentifier = "commute"
                    schedule(soon, id: headsUpID, at: headsUp, now: now)
                }
            }
        }

        if preferences.delayAlerts {
            await notifyDisruptions(in: upcoming.prefix(3), snapshot: snapshot, threshold: preferences.delayThresholdMinutes, now: now)
        }
    }

    private static func schedule(_ content: UNMutableNotificationContent, id: String, at date: Date, now: Date) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSince(now)), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Alerte immédiate quand un bus proche prend du retard ou est supprimé (une fois par palier).
    private static func notifyDisruptions(in journeys: ArraySlice<Journey>, snapshot: CommuteSnapshot, threshold: Int, now: Date) async {
        var memory = UserDefaults(suiteName: AppGroup.identifier)?.dictionary(forKey: delayMemoryKey) as? [String: Int] ?? [:]
        for journey in journeys where journey.departureTime.timeIntervalSince(now) < 60 * 60 {
            let line = snapshot.style(for: journey.lineID)?.badge ?? ""
            let scheduled = journey.scheduledDeparture.map(TimeText.clock) ?? TimeText.clock(journey.departureTime)
            let content = UNMutableNotificationContent()
            content.threadIdentifier = "commute"
            content.sound = .default
            content.interruptionLevel = .timeSensitive

            if journey.isCancelled {
                guard memory[journey.id] != -1 else { continue }
                memory[journey.id] = -1
                let next = snapshot.journeys.first { !$0.isCancelled && $0.departureTime > journey.departureTime }
                content.title = "Bus \(line) de \(scheduled) supprimé"
                content.body = next.map { "Prochain : \(TimeText.clock($0.departureTime)) (\(TimeText.countdown(to: $0.departureTime, from: now)))." } ?? "Aucun autre bus direct prévu."
            } else if let delay = journey.delay, journey.quality <= .estimated {
                let minutes = Int((delay / 60).rounded())
                let already = memory[journey.id] ?? 0
                guard minutes >= threshold, minutes >= already + threshold || already == 0 else { continue }
                memory[journey.id] = minutes
                content.title = "Bus \(line) de \(scheduled) : +\(minutes) min"
                content.body = "Départ estimé \(TimeText.clock(journey.departureTime)) depuis \(snapshot.originName), arrivée \(TimeText.clock(journey.arrivalTime))."
            } else {
                continue
            }
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "busio.delay.\(journey.id)", content: content, trigger: nil))
        }
        // Oublie les courses passées.
        let live = Set(snapshot.journeys.map(\.id))
        memory = memory.filter { live.contains($0.key) }
        UserDefaults(suiteName: AppGroup.identifier)?.set(memory, forKey: delayMemoryKey)
    }
}
