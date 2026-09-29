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
        /// Arrêts restants avant la descente, d'après le GPS (dans le bus).
        var stopsLeft: Int? = nil
        /// Correspondance menacée, bus supprimé.
        var warning: String? = nil
    }

    var title: String
    var destinationName: String
}

extension JourneyActivityAttributes.ContentState {
    /// Étape en cours : d'après le GPS s'il suit le trajet, sinon d'après l'heure.
    init(journey: PlannedJourney, styles: [LineStyle], stopName: (String) -> String, progress: JourneyTracker.Progress? = nil, warning: String? = nil, now: Date = Date()) {
        let rides = journey.rides
        let tracked = progress.flatMap { now.timeIntervalSince($0.updatedAt) < 10 * 60 ? $0 : nil }
        var index = rides.firstIndex { $0.arrival > now } ?? max(0, rides.count - 1)
        let phase: Phase
        switch tracked?.stage {
        case .onboard(let ride)? where rides.indices.contains(ride):
            index = ride
            phase = .riding
        case .toStop(let ride)? where rides.indices.contains(ride):
            index = ride
            phase = .boarding
        case .arrived?:
            phase = .arrived
        default:
            if rides.isEmpty {
                phase = journey.arrival > now ? .boarding : .arrived
            } else {
                let ride = rides[index]
                phase = ride.departure > now ? .boarding : (ride.arrival > now ? .riding : .arrived)
            }
        }
        let ride = rides.isEmpty ? nil : rides[index]
        let style = ride.flatMap { r in styles.first { $0.id == r.lineID } }
        let stopsLeft = phase == .riding ? tracked?.stopsLeft : nil

        var next: String?
        if phase == .riding, let stopsLeft, stopsLeft > 0 {
            next = stopsLeft == 1 ? "Descente au prochain arrêt" : "Descente dans \(stopsLeft) arrêts"
        } else if let ride, index + 1 < rides.count {
            let following = rides[index + 1]
            let badge = styles.first { $0.id == following.lineID }?.badge ?? ""
            next = "puis \(badge) à \(stopName(following.board.stopID)) \(TimeText.clock(following.departure))"
        } else if let ride {
            next = "descente \(stopName(ride.alight.stopID)) \(TimeText.clock(ride.arrival))"
        }

        self.init(
            phase: phase,
            target: ride.map { phase == .riding ? $0.arrival : $0.departure } ?? journey.arrival,
            leaveAt: index == 0 && phase == .boarding && journey.departure > now ? journey.departure : nil,
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
            updatedAt: now,
            stopsLeft: stopsLeft,
            warning: warning
        )
    }
}

/// Démarrage / mise à jour / fin des Live Activities (mises à jour locales, sans serveur push).
enum JourneyActivityController {
    static var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    static var current: Activity<JourneyActivityAttributes>? {
        Activity<JourneyActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    static func state(for followed: FollowedJourney, network: Network?, now: Date = Date()) -> JourneyActivityAttributes.ContentState? {
        guard let journey = followed.journey else { return nil }
        let context = JourneyContext(followed: followed, network: network)
        let warning = followed.issue.map { context.issueShort($0, journey: journey, planB: followed.planB) }
        return JourneyActivityAttributes.ContentState(journey: journey, styles: context.styles, stopName: context.stopName,
                                                      progress: followed.progress, warning: warning, now: now)
    }

    /// Suit `journey` (remplace un éventuel suivi en cours) et l'enregistre pour les actualisations.
    @discardableResult
    static func start(journey: PlannedJourney, request: JourneyRequest, title: String, network: Network?) async throws -> FollowedJourney {
        let followed = FollowedJourney(request: request, journey: journey, title: title)
        AppGroup.store.save(followed: followed)
        guard isEnabled, let state = state(for: followed, network: network) else { return followed }
        let content = ActivityContent(state: state, staleDate: journey.arrival.addingTimeInterval(120), relevanceScore: 100)
        if let current {
            await current.update(content)
        } else {
            let attributes = JourneyActivityAttributes(title: title, destinationName: request.to.name)
            _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
        }
        return followed
    }

    static func update(followed: FollowedJourney, network: Network?, now: Date = Date()) async {
        guard let activity = current, let journey = followed.journey, let state = state(for: followed, network: network, now: now) else { return }
        let content = ActivityContent(state: state, staleDate: journey.arrival.addingTimeInterval(120), relevanceScore: 100)
        if state.phase == .arrived || followed.isOver(at: now) {
            await activity.end(content, dismissalPolicy: .after(now.addingTimeInterval(5 * 60)))
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
