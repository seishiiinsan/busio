#if DEBUG
import Foundation
import BusioKit

/// Données d'exemple pour les previews Xcode.
enum PreviewData {
    static let line10 = Line(id: "830780013", code: "10", name: "Ligne 10", color: RGBColor(hex: "#D3007B")!, textColor: .white, sortOrder: 0)

    static func journey(inMinutes minutes: Double, live: Bool = true, delay: TimeInterval = 120, now: Date = Date()) -> Journey {
        let departure = now.addingTimeInterval(minutes * 60)
        let arrival = departure.addingTimeInterval(59 * 60)
        let origin = StopCall(
            stopID: "839690006", index: 0,
            scheduledArrival: departure.addingTimeInterval(-delay), scheduledDeparture: departure.addingTimeInterval(-delay),
            expectedArrival: live ? departure : nil, expectedDeparture: live ? departure : nil,
            passed: false
        )
        let destination = StopCall(
            stopID: "843740007", index: 24,
            scheduledArrival: arrival.addingTimeInterval(-delay), scheduledDeparture: arrival.addingTimeInterval(-delay),
            expectedArrival: live ? arrival : nil, expectedDeparture: live ? arrival : nil,
            passed: false
        )
        let trip = TripInstance(
            id: "preview-\(Int(minutes))", lineID: line10.id, itineraryID: nil, headsign: "Gares Mazamet",
            serviceDay: ServiceDay(containing: now), calls: [origin, destination],
            state: live ? .running : .planned, quality: live ? .live : .planned, source: .zenbus, vehicle: nil
        )
        return Journey(trip: trip, origin: origin, destination: destination)
    }

    static var snapshot: CommuteSnapshot {
        let now = Date()
        let journeys = [journey(inMinutes: 9, now: now), journey(inMinutes: 32, live: false, delay: 0, now: now), journey(inMinutes: 62, live: false, delay: 0, now: now)]
        return CommuteSnapshot(
            generatedAt: now, direction: .toWork,
            originName: "Gares Castres", destinationName: "Gares Mazamet",
            journeys: journeys, recommendedID: journeys[0].id,
            status: FeedStatus(kind: .live, detail: nil, lastLiveUpdate: now),
            lines: [CommuteSnapshot.LineStyle(line10)],
            walk: 5 * 60, buffer: 2 * 60
        )
    }

    static var activityAttributes: CommuteActivityAttributes {
        let snapshot = snapshot
        return CommuteActivityAttributes(journey: snapshot.journeys[0], snapshot: snapshot)
    }

    static var activityState: CommuteActivityAttributes.ContentState {
        let snapshot = snapshot
        return CommuteActivityAttributes.ContentState(journey: snapshot.journeys[0], snapshot: snapshot)
    }
}
#endif
