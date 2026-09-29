import XCTest
@testable import BusioKit

final class JourneyPlannerTests: XCTestCase {
    private func service() -> TransitService {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("busio-plan-\(UUID().uuidString)")
        return TransitService(configuration: .init(
            cacheDirectory: cache, seedDirectory: TestData.seed,
            client: ZenbusClient(baseURL: URL(string: "http://127.0.0.1:9")!),
            gtfsURL: URL(string: "http://127.0.0.1:9/g.zip")!
        ))
    }

    private func stop(_ name: String) -> Place { Place(stop: TestData.area(name)) }

    /// Invariants communs à tout itinéraire.
    private func assertCoherent(_ journey: PlannedJourney, options: RoutingOptions = RoutingOptions(), file: StaticString = #filePath, line: UInt = #line) {
        var previousEnd: Date?
        var previousRideArrival: Date?
        for leg in journey.legs {
            XCTAssertLessThanOrEqual(leg.start, leg.end, file: file, line: line)
            if let previousEnd { XCTAssertGreaterThanOrEqual(leg.start.addingTimeInterval(1), previousEnd, "étapes dans l'ordre", file: file, line: line) }
            if case .ride(let ride) = leg {
                XCTAssertLessThan(ride.board.index, ride.alight.index, file: file, line: line)
                XCTAssertFalse(ride.board.passed, file: file, line: line)
                if let previousRideArrival {
                    XCTAssertGreaterThanOrEqual(ride.departure.timeIntervalSince(previousRideArrival), options.minTransferTime - 1, "marge de correspondance", file: file, line: line)
                }
                previousRideArrival = ride.arrival
            }
            previousEnd = leg.end
        }
        for walk in journey.walks { XCTAssertLessThanOrEqual(walk.distance, max(options.maxWalkDistance, 2_500), file: file, line: line) }
    }

    func testDirectJourneyBetweenStops() async throws {
        let result = try await service().planJourney(JourneyRequest(from: stop("gares castres"), to: stop("gares mazamet"), time: .departAt(TestData.date(2026, 9, 29, 7, 30))))
        let first = try XCTUnwrap(result.journeys.first)
        XCTAssertEqual(first.transfers, 0)
        XCTAssertEqual(first.rides.first?.lineID, TestData.line10.id)
        XCTAssertGreaterThanOrEqual(first.departure, TestData.date(2026, 9, 29, 7, 30))
        XCTAssertEqual(result.status.kind, .theoretical)
        result.journeys.forEach { assertCoherent($0) }
    }

    func testJourneyWithTransfer() async throws {
        let result = try await service().planJourney(JourneyRequest(from: stop("archipel"), to: stop("gares mazamet"), time: .departAt(TestData.date(2026, 9, 29, 7, 0))))
        XCTAssertGreaterThanOrEqual(result.journeys.count, 4)
        XCTAssertEqual(result.journeys.first?.transfers, 1)
        XCTAssertTrue(result.journeys.allSatisfy { $0.rides.last?.lineID == TestData.line10.id })
        // Triés par arrivée, sans doublon ni trajet dominé.
        XCTAssertEqual(result.journeys.map(\.arrival), result.journeys.map(\.arrival).sorted())
        XCTAssertEqual(Set(result.journeys.map(\.id)).count, result.journeys.count)
        result.journeys.forEach { assertCoherent($0) }
    }

    func testArriveByProposesClosestBeforeAndAfter() async throws {
        let deadline = TestData.date(2026, 9, 29, 9, 0)
        let result = try await service().planJourney(JourneyRequest(from: stop("archipel"), to: stop("gares mazamet"), time: .arriveBy(deadline)))
        let before = try XCTUnwrap(result.journeys.first { $0.id == result.closestBeforeID })
        let after = try XCTUnwrap(result.journeys.first { $0.id == result.closestAfterID })
        XCTAssertLessThanOrEqual(before.arrival, deadline)
        XCTAssertGreaterThan(after.arrival, deadline)
        XCTAssertFalse(result.journeys.contains { $0.arrival <= deadline && $0.arrival > before.arrival }, "juste avant = le plus proche")
        XCTAssertEqual(result.journeys.first?.id, before.id)
    }

    func testPreferenceFewestTransfers() async throws {
        var options = RoutingOptions()
        options.preference = .fewestTransfers
        let result = try await service().planJourney(JourneyRequest(from: stop("archipel"), to: stop("gares mazamet"), time: .departAt(TestData.date(2026, 9, 29, 7, 0)), options: options))
        XCTAssertEqual(result.journeys.map(\.transfers), result.journeys.map(\.transfers).sorted())
    }

    func testAddressToAddressWalksToAndFromStops() async throws {
        let here = Place(name: "Place Jean Jaurès", coordinate: Coordinate(latitude: 43.6056, longitude: 2.2410), kind: .address)
        let there = Place(name: "Mazamet centre", coordinate: Coordinate(latitude: 43.4925, longitude: 2.3735), kind: .address)
        let result = try await service().planJourney(JourneyRequest(from: here, to: there, time: .departAt(TestData.date(2026, 9, 29, 16, 30))))
        let first = try XCTUnwrap(result.journeys.first)
        guard case .walk = first.legs.first, case .walk = first.legs.last else { return XCTFail("marche au début et à la fin") }
        XCTAssertLessThan(first.duration, 2 * 3600)
        result.journeys.forEach { assertCoherent($0) }
    }

    func testShortDistanceOffersWalking() async throws {
        let a = Place(name: "A", coordinate: Coordinate(latitude: 43.6056, longitude: 2.2410), kind: .address)
        let b = Place(name: "B", coordinate: Coordinate(latitude: 43.6090, longitude: 2.2410), kind: .address)
        let result = try await service().planJourney(JourneyRequest(from: a, to: b, time: .departAt(TestData.date(2026, 9, 29, 10, 0))))
        XCTAssertTrue(result.journeys.contains(where: \.isWalkOnly))
    }

    func testTomorrowIsTheoretical() async throws {
        let result = try await service().planJourney(
            JourneyRequest(from: stop("gares castres"), to: stop("gares mazamet"), time: .departAt(TestData.date(2026, 9, 30, 8, 0))),
            now: TestData.date(2026, 9, 29, 20, 0)
        )
        XCTAssertFalse(result.journeys.isEmpty)
        XCTAssertEqual(result.status.kind, .theoretical)
    }

    func testPlanningIsFast() async throws {
        let service = service()
        _ = try await service.planJourney(JourneyRequest(from: stop("archipel"), to: stop("gares mazamet"), time: .departAt(TestData.date(2026, 9, 29, 7, 0))))
        let start = Date()
        _ = try await service.planJourney(JourneyRequest(from: stop("lameilhe"), to: stop("gares mazamet"), time: .departAt(TestData.date(2026, 9, 29, 7, 0))))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
