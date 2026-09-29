import XCTest
@testable import BusioKit

final class CommuteTests: XCTestCase {
    private func settings() -> CommuteSettings {
        CommuteSettings(home: PlaceRef(TestData.area("gares castres")), work: PlaceRef(TestData.area("gares mazamet")))
    }

    func testDirectionSwitchesAtNoon() {
        let s = settings()
        XCTAssertEqual(s.direction(at: TestData.date(2026, 9, 29, 7, 50)), .toWork)
        XCTAssertEqual(s.direction(at: TestData.date(2026, 9, 29, 16, 40)), .toHome)
        XCTAssertTrue(s.isWorkday(TestData.date(2026, 9, 29, 8)))
        XCTAssertFalse(s.isWorkday(TestData.date(2026, 9, 27, 8)))
    }

    func testPlaceRefSurvivesRenumbering() {
        let area = TestData.area("gares mazamet")
        let moved = PlaceRef(areaID: "999", name: area.name, coordinate: Coordinate(latitude: area.coordinate.latitude + 0.001, longitude: area.coordinate.longitude))
        XCTAssertEqual(moved.resolve(in: TestData.network)?.id, area.id)
        XCTAssertNil(PlaceRef(areaID: "999", name: "Nulle Part", coordinate: area.coordinate).resolve(in: TestData.network))
    }

    func testSnapshotRecommendsLatestBusArrivingOnTime() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("busio-commute-\(UUID().uuidString)")
        let service = TransitService(configuration: .init(
            cacheDirectory: cache, seedDirectory: TestData.seed,
            client: ZenbusClient(baseURL: URL(string: "http://127.0.0.1:9")!),
            gtfsURL: URL(string: "http://127.0.0.1:9/g.zip")!
        ))
        let now = TestData.date(2026, 9, 29, 7, 30)
        let snapshot = try await service.commuteSnapshot(settings: settings(), direction: .toWork, now: now)
        XCTAssertEqual(snapshot.originName, "Gares Castres")
        XCTAssertFalse(snapshot.journeys.isEmpty)
        let recommended = try XCTUnwrap(snapshot.journeys.first { $0.id == snapshot.recommendedID })
        // Arrivée avant 9h15 moins 5 min de marche.
        XCTAssertLessThanOrEqual(recommended.arrivalTime, TestData.date(2026, 9, 29, 9, 10))
        let later = snapshot.journeys.filter { $0.departureTime > recommended.departureTime }
        XCTAssertTrue(later.allSatisfy { $0.arrivalTime > TestData.date(2026, 9, 29, 9, 10) })

        let store = SharedStore(containerURL: cache)
        store.save(snapshot)
        XCTAssertEqual(store.loadSnapshot(.toWork), snapshot)
        var prefs = UserPreferences()
        prefs.commute = settings()
        store.save(prefs)
        XCTAssertEqual(store.loadPreferences(), prefs)

        let advice = LeaveAdvice(journey: recommended, walk: 300, buffer: 120)
        XCTAssertEqual(advice.leaveAt, recommended.departureTime.addingTimeInterval(-420))
    }
}
