#if DEBUG
import Foundation
import BusioKit

/// Données d'exemple pour les previews Xcode.
enum PreviewData {
    static let line3 = Line(id: "843700008", code: "3", name: "Ligne 3", color: RGBColor(hex: "#EB6909")!, textColor: .black, sortOrder: 0)
    static let line10 = Line(id: "830780013", code: "10", name: "Ligne 10", color: RGBColor(hex: "#D3007B")!, textColor: .white, sortOrder: 0)

    private static func ride(line: Line, from: String, to: String, departure: Date, minutes: Double, live: Bool) -> RideLeg {
        let arrival = departure.addingTimeInterval(minutes * 60)
        let calls = [
            StopCall(stopID: from, index: 0, scheduledArrival: departure, scheduledDeparture: departure, expectedArrival: live ? departure : nil, expectedDeparture: live ? departure : nil, passed: false),
            StopCall(stopID: to, index: 8, scheduledArrival: arrival, scheduledDeparture: arrival, expectedArrival: live ? arrival : nil, expectedDeparture: live ? arrival : nil, passed: false),
        ]
        return RideLeg(tripID: "preview-\(line.code)-\(Int(departure.timeIntervalSince1970))", lineID: line.id, itineraryID: nil, headsign: "Gares Mazamet",
                       calls: calls, state: live ? .running : .planned, quality: live ? .live : .planned, source: .zenbus, vehicle: nil)
    }

    static func journey(inMinutes minutes: Double, now: Date = Date()) -> PlannedJourney {
        let board = now.addingTimeInterval(minutes * 60)
        let walk = WalkLeg(fromName: "Ma position", toName: "Archipel",
                           from: Coordinate(latitude: 43.61, longitude: 2.25), to: Coordinate(latitude: 43.612, longitude: 2.252),
                           start: board.addingTimeInterval(-7 * 60), end: board.addingTimeInterval(-60), distance: 420)
        let first = ride(line: line3, from: "849280014", to: "843740007", departure: board, minutes: 13, live: true)
        let second = ride(line: line10, from: "843740007", to: "843740008", departure: board.addingTimeInterval(21 * 60), minutes: 42, live: false)
        return PlannedJourney(legs: [.walk(walk), .ride(first), .ride(second)])
    }

    static var snapshot: TripSnapshot {
        let now = Date()
        let journeys = [journey(inMinutes: 9, now: now), journey(inMinutes: 39, now: now)]
        let request = JourneyRequest(
            from: Place(name: "Archipel", coordinate: Coordinate(latitude: 43.61, longitude: 2.25), kind: .stop, stopAreaID: "849280014"),
            to: Place(name: "Gares Mazamet", coordinate: Coordinate(latitude: 43.498, longitude: 2.374), kind: .stop, stopAreaID: "843740007")
        )
        let result = JourneySearchResult(request: request, journeys: journeys, closestBeforeID: nil, closestAfterID: nil,
                                         origin: request.from, destination: request.to, alerts: [],
                                         status: FeedStatus(kind: .live, detail: nil, lastLiveUpdate: now), generatedAt: now)
        let network = Network(lines: [line3, line10], itineraries: [], stops: [], version: 0, publishedDay: nil)
        return TripSnapshot(favoriteID: nil, title: "Archipel → Gares Mazamet", result: result, network: network)
    }

    static var activityAttributes: JourneyActivityAttributes {
        JourneyActivityAttributes(title: "Archipel → Gares Mazamet", destinationName: "Gares Mazamet")
    }

    static var activityState: JourneyActivityAttributes.ContentState {
        let snapshot = snapshot
        return JourneyActivityAttributes.ContentState(journey: snapshot.journeys[0], styles: snapshot.lines, stopName: { _ in "Archipel" })
    }

    static var activityWarningState: JourneyActivityAttributes.ContentState {
        var state = activityState
        state.warning = "Correspondance ratée · plan B 10 à 18:55"
        return state
    }
}
#endif
