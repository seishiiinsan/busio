import XCTest
@testable import BusioKit

/// Cas limites du temps réel, sur des messages Zenbus construits à la main.
final class LiveMappingTests: XCTestCase {
    private let day = ServiceDay(yyyymmdd: 20260929)!
    private var itinerary: Itinerary { TestData.network.itineraries.first { $0.rawName == "GUYNEMER > GARES MAZAMET" }! }

    private func stopTime(_ index: Int, _ seconds: Int) -> ZenbusRealtime_StopTime {
        var t = ZenbusRealtime_StopTime()
        t.stopIndexInItinerary = Int32(index)
        t.arrival = Int32(seconds)
        t.departure = Int32(seconds)
        return t
    }

    /// Course de 4 arrêts partant à 8:00, 2 min entre arrêts.
    private func message(serverTime: Date, previousIndex: Int32, estimatedUpTo: Int, delay: Int = 60, descriptor: ZenbusRealtime_JtfsScheduleRelationshipDescriptor = .scheduledLive) -> ZenbusRealtime_LiveMessage {
        var column = ZenbusRealtime_TripColumn()
        column.aimed = (0..<4).map { stopTime($0, 8 * 3600 + $0 * 120) }
        column.estimactual = (0...estimatedUpTo).map { stopTime($0, 8 * 3600 + $0 * 120 + delay) }
        var pos = ZenbusRealtime_Pos()
        let stop = TestData.network.stop(itinerary.stopIDs[0])!
        pos.latitude = Float(stop.coordinate.latitude)
        pos.longitude = Float(stop.coordinate.longitude)
        pos.secondsAfterMidnight = Int32(day.seconds(of: serverTime))
        column.pos = [pos]
        column.previousIndexInItinerary = previousIndex
        column.itineraryID = Int64(itinerary.id)!
        column.vehicleID = 42
        column.jtfsScheduleRelationshipDescriptor = descriptor
        column.tripStatus = .sure

        var timetable = ZenbusRealtime_Timetable()
        timetable.itineraryID = Int64(itinerary.id)!
        timetable.yyyymmdd = Int32(day.yyyymmdd)
        timetable.midnight = Int64(day.referenceDate.timeIntervalSince1970)
        timetable.column = [column]

        var live = ZenbusRealtime_LiveMessage()
        live.timetable = [timetable]
        live.endProcessing = Int64(serverTime.timeIntervalSince1970 * 1000)
        return live
    }

    func testBusWaitingAtTerminusIsNotPassed() throws {
        let now = day.date(seconds: 7 * 3600 + 58 * 60)
        let snapshot = ZenbusMapper.snapshot(from: message(serverTime: now, previousIndex: 0, estimatedUpTo: 3), network: TestData.network)
        let trip = try XCTUnwrap(snapshot.trips.first)
        XCTAssertEqual(trip.state, .running)
        XCTAssertEqual(trip.quality, .live)
        XCTAssertFalse(trip.calls[0].passed)
        XCTAssertEqual(trip.vehicle?.id, "42")

        let departures = TripPlanner.departures(from: snapshot.trips, at: [itinerary.stopIDs[0]], now: now, horizon: 3600)
        XCTAssertEqual(departures.count, 1)
        XCTAssertEqual(departures[0].delay, 60)
        XCTAssertEqual(departures[0].stopsAway, 0)
    }

    func testBusThatLeftIsPassedAndDelayIsPropagated() throws {
        let now = day.date(seconds: 8 * 3600 + 6 * 60)
        let snapshot = ZenbusMapper.snapshot(from: message(serverTime: now, previousIndex: 1, estimatedUpTo: 1, delay: 180), network: TestData.network)
        let trip = try XCTUnwrap(snapshot.trips.first)
        XCTAssertTrue(trip.calls[0].passed)
        XCTAssertTrue(trip.calls[1].passed)
        XCTAssertFalse(trip.calls[2].passed)
        // Pas d'estimation Zenbus au-delà de l'arrêt 1 : on propage +3 min.
        XCTAssertEqual(trip.calls[3].expectedDeparture, day.date(seconds: 8 * 3600 + 3 * 120 + 180))

        let departures = TripPlanner.departures(from: snapshot.trips, at: [itinerary.stopIDs[0]], now: now, horizon: 3600)
        XCTAssertTrue(departures.isEmpty, "bus déjà parti de l'arrêt")
    }

    func testCancelledTripIsKeptButFlagged() throws {
        let now = day.date(seconds: 7 * 3600 + 50 * 60)
        let snapshot = ZenbusMapper.snapshot(from: message(serverTime: now, previousIndex: -1, estimatedUpTo: 0, descriptor: .canceledLive), network: TestData.network)
        let trip = try XCTUnwrap(snapshot.trips.first)
        XCTAssertEqual(trip.state, .cancelled)
        XCTAssertNil(trip.calls[0].expected)
        let departures = TripPlanner.departures(from: snapshot.trips, at: [itinerary.stopIDs[1]], now: now, horizon: 3600)
        XCTAssertEqual(departures.first?.isCancelled, true)
        XCTAssertEqual(departures.first?.time, day.date(seconds: 8 * 3600 + 120))
    }

    func testTodayCoverageOnlyFromPublishedDay() {
        let now = day.date(seconds: 7 * 3600 + 58 * 60)
        let snapshot = ZenbusMapper.snapshot(from: message(serverTime: now, previousIndex: 0, estimatedUpTo: 3), network: TestData.network)
        XCTAssertEqual(snapshot.serviceDays[itinerary.id], day)
        XCTAssertEqual(snapshot.serverTime, now)
    }
}
