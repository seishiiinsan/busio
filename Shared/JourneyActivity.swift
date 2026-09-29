import ActivityKit
import Foundation
import BusioKit

/// Live Activity d'un itinéraire (écran verrouillé + Dynamic Island).
/// L'état suit l'étape en cours : aller à l'arrêt, attendre le bus, rouler, correspondance.
struct JourneyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            /// En attente du bus (ou en route vers l'arrêt).
            case boarding
            /// Dans le bus, jusqu'à la descente.
            case riding
            /// Arrivé.
            case arrived
        }

        var phase: Phase
        /// Heure visée par le compte à rebours (montée ou descente).
        var target: Date
        var leaveAt: Date?
        var lineBadge: String
        var lineColorHex: String
        var lineTextColorHex: String
        var headsign: String
        /// Arrêt de montée (phase .boarding) ou de descente (phase .riding).
        var stopName: String
        var nextStep: String?
        var arrival: Date
        var isLive: Bool
        var isCancelled: Bool
        var stopsAway: Int?
        var delayMinutes: Int?
        var updatedAt: Date
    }

    var title: String
    var destinationName: String
}

extension JourneyActivityAttributes.ContentState {
    init(journey: PlannedJourney, styles: [LineStyle], stopName: (String) -> String, now: Date = Date()) {
        let rides = journey.rides
        // Étape en cours : premier bus pas encore arrivé à sa descente.
        let index = rides.firstIndex { $0.arrival > now } ?? max(0, rides.count - 1)
        let ride = rides.isEmpty ? nil : rides[index]
        let style = ride.flatMap { r in styles.first { $0.id == r.lineID } }

        let phase: Phase
        if let ride {
            phase = ride.departure > now ? .boarding : (ride.arrival > now ? .riding : .arrived)
        } else {
            phase = journey.arrival > now ? .boarding : .arrived
        }

        var next: String?
        if let ride, index + 1 < rides.count {
            let following = rides[index + 1]
            let badge = styles.first { $0.id == following.lineID }?.badge ?? ""
            next = "puis \(badge) à \(stopName(following.board.stopID)) \(TimeText.clock(following.departure))"
        } else if let ride {
            next = "descente \(stopName(ride.alight.stopID)) \(TimeText.clock(ride.arrival))"
        }

        self.init(
            phase: phase,
            target: ride.map { phase == .riding ? $0.arrival : $0.departure } ?? journey.arrival,
            leaveAt: index == 0 && journey.departure > now ? journey.departure : nil,
            lineBadge: style?.badge ?? "🚶",
            lineColorHex: style?.color.hex ?? RGBColor.neutral.hex,
            lineTextColorHex: style?.textColor.hex ?? RGBColor.white.hex,
            headsign: ride?.headsign ?? "",
            stopName: ride.map { stopName(phase == .riding ? $0.alight.stopID : $0.board.stopID) } ?? "",
            nextStep: next,
            arrival: journey.arrival,
            isLive: ride?.quality == .live,
            isCancelled: ride?.isCancelled ?? false,
            stopsAway: phase == .boarding ? ride?.stopsAway : nil,
            delayMinutes: ride?.delay.map { Int(($0 / 60).rounded()) },
            updatedAt: now
        )
    }
}

/// Démarrage / mise à jour / fin des Live Activities (mises à jour locales, sans serveur push).
enum JourneyActivityController {
    static var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    static var current: Activity<JourneyActivityAttributes>? {
        Activity<JourneyActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    static func state(for journey: PlannedJourney, snapshot: TripSnapshot, network: Network?, now: Date = Date()) -> JourneyActivityAttributes.ContentState {
        JourneyActivityAttributes.ContentState(journey: journey, styles: snapshot.lines, stopName: { network?.stop($0)?.name ?? "" }, now: now)
    }

    /// Suit `journey` (remplace une éventuelle activité en cours) et mémorise la recherche pour les actualisations.
    static func start(journey: PlannedJourney, snapshot: TripSnapshot, network: Network?) async throws {
        AppGroup.store.save(followed: FollowedJourney(request: snapshot.request, journey: journey, title: snapshot.title))
        let state = state(for: journey, snapshot: snapshot, network: network)
        let content = ActivityContent(state: state, staleDate: journey.arrival.addingTimeInterval(120), relevanceScore: 100)
        if let current {
            await current.update(content)
            return
        }
        let attributes = JourneyActivityAttributes(title: snapshot.title, destinationName: snapshot.destinationName)
        _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    static func update(journey: PlannedJourney, snapshot: TripSnapshot, network: Network?, now: Date = Date()) async {
        guard let activity = current else { return }
        let state = state(for: journey, snapshot: snapshot, network: network, now: now)
        let content = ActivityContent(state: state, staleDate: journey.arrival.addingTimeInterval(120), relevanceScore: 100)
        if journey.arrival < now {
            await activity.end(content, dismissalPolicy: .after(now.addingTimeInterval(5 * 60)))
            AppGroup.store.save(followed: nil)
        } else {
            await activity.update(content)
        }
    }

    static func endAll() async {
        for activity in Activity<JourneyActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        AppGroup.store.save(followed: nil)
    }
}
