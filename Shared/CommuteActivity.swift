import ActivityKit
import Foundation
import BusioKit

/// Live Activity « mon bus » (écran verrouillé + Dynamic Island).
struct CommuteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var departure: Date
        var scheduledDeparture: Date?
        var arrival: Date
        var leaveAt: Date?
        var isLive: Bool
        var isCancelled: Bool
        var stopsAway: Int?
        var delayMinutes: Int?
        var updatedAt: Date
    }

    var tripID: String
    var lineBadge: String
    var lineColorHex: String
    var lineTextColorHex: String
    var originName: String
    var destinationName: String
    var headsign: String
}

extension CommuteActivityAttributes {
    init(journey: Journey, snapshot: CommuteSnapshot) {
        let style = snapshot.style(for: journey.lineID)
        self.init(
            tripID: journey.tripID,
            lineBadge: style?.badge ?? "Bus",
            lineColorHex: style?.color.hex ?? RGBColor.neutral.hex,
            lineTextColorHex: style?.textColor.hex ?? RGBColor.white.hex,
            originName: snapshot.originName,
            destinationName: snapshot.destinationName,
            headsign: journey.headsign
        )
    }
}

extension CommuteActivityAttributes.ContentState {
    init(journey: Journey, snapshot: CommuteSnapshot, now: Date = Date()) {
        let advice = LeaveAdvice(journey: journey, walk: snapshot.walk, buffer: snapshot.buffer)
        self.init(
            departure: journey.departureTime,
            scheduledDeparture: journey.scheduledDeparture,
            arrival: journey.arrivalTime,
            leaveAt: advice.leaveAt > now ? advice.leaveAt : nil,
            isLive: journey.quality == .live,
            isCancelled: journey.isCancelled,
            stopsAway: journey.stopsAway,
            delayMinutes: journey.delay.map { Int(($0 / 60).rounded()) },
            updatedAt: now
        )
    }
}

/// Démarrage / mise à jour / fin des Live Activities (sans serveur push : mises à jour locales).
enum CommuteActivityController {
    static var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    static var current: Activity<CommuteActivityAttributes>? {
        Activity<CommuteActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    /// Suit `journey`, en remplaçant une éventuelle activité sur une autre course.
    @discardableResult
    static func start(journey: Journey, snapshot: CommuteSnapshot) async throws -> Activity<CommuteActivityAttributes> {
        if let current, current.attributes.tripID == journey.tripID {
            await update(current, journey: journey, snapshot: snapshot)
            return current
        }
        await endAll()
        let state = CommuteActivityAttributes.ContentState(journey: journey, snapshot: snapshot)
        let content = ActivityContent(state: state, staleDate: journey.arrivalTime.addingTimeInterval(120), relevanceScore: 100)
        return try Activity.request(attributes: CommuteActivityAttributes(journey: journey, snapshot: snapshot), content: content, pushType: nil)
    }

    /// Met à jour l'activité en cours à partir d'un nouvel état du trajet.
    static func refresh(with snapshot: CommuteSnapshot, now: Date = Date()) async {
        guard let activity = current else { return }
        if let journey = snapshot.journeys.first(where: { $0.tripID == activity.attributes.tripID }) {
            await update(activity, journey: journey, snapshot: snapshot, now: now)
        } else if activity.content.state.departure < now.addingTimeInterval(-60) {
            // Le bus est parti (plus dans la liste) : on laisse l'info visible un court instant.
            await activity.end(nil, dismissalPolicy: .after(now.addingTimeInterval(5 * 60)))
        }
    }

    static func update(_ activity: Activity<CommuteActivityAttributes>, journey: Journey, snapshot: CommuteSnapshot, now: Date = Date()) async {
        let state = CommuteActivityAttributes.ContentState(journey: journey, snapshot: snapshot, now: now)
        let content = ActivityContent(state: state, staleDate: journey.arrivalTime.addingTimeInterval(120), relevanceScore: 100)
        if journey.arrivalTime < now {
            await activity.end(content, dismissalPolicy: .after(now.addingTimeInterval(5 * 60)))
        } else {
            await activity.update(content)
        }
    }

    static func endAll() async {
        for activity in Activity<CommuteActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
