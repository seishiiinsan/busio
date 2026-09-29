import XCTest
@testable import BusioKit

/// Itinéraire suivi : correspondance menacée, plan B, détection GPS dans le bus.
final class JourneyTrackingTests: XCTestCase {
    private func service() -> TransitService {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("busio-track-\(UUID().uuidString)")
        return TransitService(configuration: .init(
            cacheDirectory: cache, seedDirectory: TestData.seed,
            client: ZenbusClient(baseURL: URL(string: "http://127.0.0.1:9")!),
            gtfsURL: URL(string: "http://127.0.0.1:9/g.zip")!
        ))
    }

    private func request(_ from: String, _ to: String, _ hour: Int, _ minute: Int = 0) -> JourneyRequest {
        JourneyRequest(from: Place(stop: TestData.area(from)), to: Place(stop: TestData.area(to)), time: .departAt(TestData.date(2026, 9, 29, hour, minute)))
    }

    /// Itinéraire avec une correspondance (Archipel → Gares Mazamet).
    private func transferJourney(_ service: TransitService) async throws -> (JourneyRequest, PlannedJourney) {
        let request = request("archipel", "gares mazamet", 7)
        let result = try await service.planJourney(request, now: TestData.date(2026, 9, 29, 6, 0))
        let journey = try XCTUnwrap(result.journeys.first { $0.transfers == 1 })
        return (request, journey)
    }

    /// La course du bus `ride` avec `delay` secondes de retard (comme le ferait Zenbus).
    private func delayedTrip(_ ride: RideLeg, by delay: TimeInterval) -> TripInstance {
        let calls = ride.calls.map { call in
            StopCall(stopID: call.stopID, index: call.index, scheduledArrival: call.scheduledArrival, scheduledDeparture: call.scheduledDeparture,
                     expectedArrival: call.scheduledArrival?.addingTimeInterval(delay), expectedDeparture: call.scheduledDeparture?.addingTimeInterval(delay), passed: false)
        }
        return TripInstance(id: "z:\(ride.tripID)", lineID: ride.lineID, itineraryID: ride.itineraryID, headsign: ride.headsign,
                            serviceDay: ServiceDay(containing: ride.departure), calls: calls, state: .running, quality: .live, source: .zenbus, vehicle: nil)
    }

    // MARK: Correspondance menacée

    func testRefreshKeepsTheSameBuses() async throws {
        let service = service()
        let (_, journey) = try await transferJourney(service)
        let refreshed = try await service.refresh(journey, now: TestData.date(2026, 9, 29, 6, 50))
        XCTAssertTrue(refreshed.journey.usesSameBuses(as: journey))
        XCTAssertEqual(refreshed.journey.departure, journey.departure)
        XCTAssertEqual(refreshed.journey.arrival, journey.arrival)
        XCTAssertTrue(journey.issues(now: TestData.date(2026, 9, 29, 6, 50)).isEmpty, "itinéraire calculé = correspondance tenable")
    }

    func testDelayMakesTransferMissedThenPlanB() async throws {
        let service = service()
        let (request, journey) = try await transferJourney(service)
        let first = journey.rides[0], second = journey.rides[1]
        let margin = second.departure.timeIntervalSince(first.arrival) - journey.transferWalk(after: 0)
        let now = first.departure.addingTimeInterval(-600)

        // Retard absorbé par la marge : rien. Retard qui laisse moins d'une minute : juste. Au-delà : ratée.
        XCTAssertTrue(journey.updated(with: [delayedTrip(first, by: margin - 90)]).issues(now: now).isEmpty)
        let tight = journey.updated(with: [delayedTrip(first, by: margin - 30)]).issues(now: now)
        XCTAssertEqual(tight.map(\.kind), [.tightTransfer])
        let delayed = journey.updated(with: [delayedTrip(first, by: margin + 120)])
        XCTAssertTrue(delayed.usesSameBuses(as: journey))
        XCTAssertEqual(delayed.rides[0].arrival, first.arrival.addingTimeInterval(margin + 120))
        let issue = try XCTUnwrap(delayed.issues(now: now).first)
        XCTAssertEqual(issue.kind, .missedTransfer)
        XCTAssertEqual(issue.rideIndex, 1)
        XCTAssertLessThan(try XCTUnwrap(issue.slack), 0)

        // Plan B : même premier bus, puis une autre correspondance au plus tôt.
        let found = try await service.alternative(for: delayed, issue: issue, request: request, now: now)
        let planB = try XCTUnwrap(found)
        XCTAssertTrue(planB.rides[0].isSameRide(as: first))
        XCTAssertEqual(planB.rides[0].arrival, delayed.rides[0].arrival)
        XCTAssertFalse(planB.rides.dropFirst().contains { $0.isSameRide(as: second) })
        XCTAssertGreaterThanOrEqual(planB.rides[1].departure, delayed.rides[0].arrival.addingTimeInterval(60))
        XCTAssertGreaterThan(planB.arrival, journey.arrival)
        XCTAssertLessThan(planB.arrival.timeIntervalSince(journey.arrival), 3 * 3600)
        XCTAssertTrue(planB.issues(now: now).isEmpty)
    }

    func testCancelledBusIsReported() async throws {
        let (_, journey) = try await transferJourney(service())
        let second = journey.rides[1]
        var cancelled = delayedTrip(second, by: 0)
        cancelled = TripInstance(id: cancelled.id, lineID: cancelled.lineID, itineraryID: cancelled.itineraryID, headsign: cancelled.headsign,
                                 serviceDay: cancelled.serviceDay, calls: cancelled.calls, state: .cancelled, quality: .live, source: .zenbus, vehicle: nil)
        let issues = journey.updated(with: [cancelled]).issues(now: journey.departure.addingTimeInterval(-600))
        XCTAssertEqual(issues.first?.kind, .cancelled)
        XCTAssertEqual(issues.first?.rideIndex, 1)
    }

    // MARK: Dans le bus

    func testRideShapeFollowsTheRoad() async throws {
        let result = try await service().planJourney(request("gares castres", "gares mazamet", 7, 30), now: TestData.date(2026, 9, 29, 6, 0))
        let ride = try XCTUnwrap(result.journeys.first?.rides.first)
        let shape = RideShape(ride: ride, network: TestData.network)
        let straight = zip(shape.stopCoordinates, shape.stopCoordinates.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        XCTAssertGreaterThan(shape.length, straight * 0.98, "le tracé suit la route")
        XCTAssertLessThan(shape.length, straight * 2)
        XCTAssertGreaterThan(shape.points.count, ride.calls.count * 3, "tracé Zenbus, pas une ligne droite")
        XCTAssertEqual(shape.stopOffsets.count, ride.calls.count)
        XCTAssertEqual(shape.stopOffsets, shape.stopOffsets.sorted())
        for stop in shape.stopCoordinates { XCTAssertLessThan(shape.project(stop).distance, 150) }
    }

    /// Roule le long du bus à ~30 km/h, puis s'arrête à la descente.
    private func ride(_ tracker: inout JourneyTracker, shape: RideShape, from start: Date) -> [JourneyTracker.Event] {
        var events: [JourneyTracker.Event] = []
        var time = start
        var offset = 0.0
        while offset < shape.length {
            offset += 18
            // Léger bruit GPS perpendiculaire.
            let point = shape.coordinate(at: min(offset, shape.length))
            let noisy = Coordinate(latitude: point.latitude + (offset.truncatingRemainder(dividingBy: 36) == 0 ? 0.0001 : -0.0001), longitude: point.longitude)
            events += tracker.update(location: noisy, accuracy: 10, speed: 9, at: time)
            time.addTimeInterval(2)
        }
        for _ in 0..<3 {
            events += tracker.update(location: shape.stopCoordinates[shape.stopCoordinates.count - 1], accuracy: 8, speed: 0, at: time)
            time.addTimeInterval(5)
        }
        return events
    }

    func testTrackerFollowsATransferJourney() async throws {
        let (_, journey) = try await transferJourney(service())
        let network = TestData.network
        let shapes = journey.rides.map { RideShape(ride: $0, network: network) }
        var tracker = JourneyTracker(journey: journey, network: network, now: journey.departure)
        XCTAssertEqual(tracker.progress.stage, .toStop(ride: 0))

        // À l'arrêt, puis à pied le long de la route : pas « dans le bus ».
        let boardStop = shapes[0].stopCoordinates[0]
        for i in 0..<10 {
            let events = tracker.update(location: boardStop, accuracy: 15, speed: 0, at: journey.rides[0].departure.addingTimeInterval(Double(i * 10 - 200)))
            XCTAssertTrue(events.isEmpty)
        }
        for i in 1...40 {
            _ = tracker.update(location: shapes[0].coordinate(at: Double(i) * 3), accuracy: 10, speed: 1.4, at: journey.rides[0].departure.addingTimeInterval(Double(i * 2)))
        }
        XCTAssertEqual(tracker.progress.stage, .toStop(ride: 0))

        var events = ride(&tracker, shape: shapes[0], from: journey.rides[0].departure)
        XCTAssertEqual(events.first, .boarded(ride: 0))
        XCTAssertTrue(events.contains(.approaching(ride: 0, stopsLeft: 1)))
        XCTAssertEqual(events.last, .alighted(ride: 0))
        XCTAssertEqual(tracker.progress.stage, .toStop(ride: 1))

        events = ride(&tracker, shape: shapes[1], from: journey.rides[1].departure)
        XCTAssertEqual(events.first, .boarded(ride: 1))
        let approaching = events.filter { if case .approaching = $0 { true } else { false } }
        XCTAssertEqual(approaching, [.approaching(ride: 1, stopsLeft: 2), .approaching(ride: 1, stopsLeft: 1)])
        XCTAssertEqual(events.last, .alighted(ride: 1))
        XCTAssertEqual(tracker.progress.stage, .arrived)
    }

    func testTrackerCountsStopsLeftOnboard() async throws {
        let result = try await service().planJourney(request("gares castres", "gares mazamet", 7, 30), now: TestData.date(2026, 9, 29, 6, 0))
        let journey = try XCTUnwrap(result.journeys.first)
        let ride = journey.rides[0]
        let shape = RideShape(ride: ride, network: TestData.network)
        var tracker = JourneyTracker(journey: journey, network: TestData.network, now: journey.departure)
        // Déjà dans le bus au lancement du suivi, entre le 2e et le 3e arrêt.
        let middle = (shape.stopOffsets[1] + shape.stopOffsets[2]) / 2
        for i in 0..<3 {
            _ = tracker.update(location: shape.coordinate(at: middle + Double(i) * 20), accuracy: 10, speed: 10, at: ride.departure.addingTimeInterval(120 + Double(i * 2)))
        }
        XCTAssertEqual(tracker.progress.stage, .onboard(ride: 0))
        XCTAssertEqual(tracker.progress.stopsLeft, ride.calls.count - 2)
        XCTAssertEqual(tracker.progress.nextStopID, ride.calls[2].stopID)
    }

    func testTrackerWarnsWhenTheStopIsPassed() async throws {
        let result = try await service().planJourney(request("gares castres", "gares mazamet", 7, 30), now: TestData.date(2026, 9, 29, 6, 0))
        let journey = try XCTUnwrap(result.journeys.first)
        let rideLeg = journey.rides[0]
        // Descente avant le terminus : on fait comme si on restait à bord.
        let shortRide = RideLeg(tripID: rideLeg.tripID, lineID: rideLeg.lineID, itineraryID: rideLeg.itineraryID, headsign: rideLeg.headsign,
                                calls: Array(rideLeg.calls.prefix(rideLeg.calls.count - 2)), state: .planned, quality: .planned, source: .gtfs, vehicle: nil)
        let network = TestData.network
        var tracker = JourneyTracker(journey: PlannedJourney(legs: [.ride(shortRide)]), network: network, now: journey.departure)
        let full = RideShape(ride: rideLeg, network: network)
        var events: [JourneyTracker.Event] = []
        var time = rideLeg.departure
        var offset = 0.0
        while offset < full.length {
            offset += 18
            events += tracker.update(location: full.coordinate(at: offset), accuracy: 10, speed: 12, at: time)
            time.addTimeInterval(2)
        }
        XCTAssertTrue(events.contains(.missedStop(ride: 0)))
        XCTAssertEqual(tracker.progress.stage, .arrived)
    }
}
