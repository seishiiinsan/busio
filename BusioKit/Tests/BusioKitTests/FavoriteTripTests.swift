import XCTest
@testable import BusioKit

final class FavoriteTripTests: XCTestCase {
    private var archipelToMazamet: FavoriteTrip {
        FavoriteTrip(from: Place(stop: TestData.area("archipel")), to: Place(stop: TestData.area("gares mazamet")), arriveByMinute: 9 * 60)
    }

    func testArrivalTimeAppliesOnSelectedDaysBeforeDeadline() {
        let trip = archipelToMazamet
        XCTAssertEqual(trip.displayName, "Archipel → Gares Mazamet")
        // Mardi 7:00 : arriver avant 9:00.
        let morning = trip.request(options: RoutingOptions(), at: TestData.date(2026, 9, 29, 7, 0))
        XCTAssertEqual(morning.time, .arriveBy(TestData.date(2026, 9, 29, 9, 0)))
        // Mardi 10:00 : heure passée, on part maintenant.
        XCTAssertEqual(trip.request(options: RoutingOptions(), at: TestData.date(2026, 9, 29, 10, 0)).time, .now)
        // Dimanche : pas d'heure d'arrivée.
        XCTAssertEqual(trip.request(options: RoutingOptions(), at: TestData.date(2026, 9, 27, 7, 0)).time, .now)
        XCTAssertEqual(trip.reversed.from, trip.to)
        XCTAssertNil(trip.reversed.arriveByMinute)
    }

    func testAutomaticFavoritePicksUpcomingArrival() {
        let morning = archipelToMazamet
        var evening = morning.reversed
        evening.arriveByMinute = 17 * 60 + 30
        let noTime = FavoriteTrip(from: Place(stop: TestData.area("gare sncf")), to: Place(stop: TestData.area("lameilhe")))
        let favorites = [noTime, morning, evening]
        XCTAssertEqual(FavoriteTrip.automatic(in: favorites, at: TestData.date(2026, 9, 29, 7, 30))?.id, morning.id)
        XCTAssertEqual(FavoriteTrip.automatic(in: favorites, at: TestData.date(2026, 9, 29, 16, 0))?.id, evening.id)
        XCTAssertEqual(FavoriteTrip.automatic(in: favorites, at: TestData.date(2026, 9, 29, 11, 0))?.id, noTime.id)
    }

    func testSnapshotAndPreferencesRoundTrip() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("busio-fav-\(UUID().uuidString)")
        let service = TransitService(configuration: .init(
            cacheDirectory: cache, seedDirectory: TestData.seed,
            client: ZenbusClient(baseURL: URL(string: "http://127.0.0.1:9")!),
            gtfsURL: URL(string: "http://127.0.0.1:9/g.zip")!
        ))
        let favorite = archipelToMazamet
        let now = TestData.date(2026, 9, 29, 7, 0)
        let snapshot = try await service.snapshot(for: favorite.request(options: RoutingOptions(), at: now), favoriteID: favorite.id, title: favorite.displayName, now: now)
        XCTAssertNotNil(snapshot.closestBeforeID)
        XCTAssertEqual(snapshot.next(at: now)?.id, snapshot.closestBeforeID)
        XCTAssertFalse(snapshot.lines.isEmpty)

        let store = SharedStore(containerURL: cache)
        store.save(snapshot)
        XCTAssertEqual(store.loadSnapshot(favoriteID: favorite.id), snapshot)

        var prefs = UserPreferences()
        prefs.favoriteTrips = [favorite]
        prefs.remember(favorite.to)
        prefs.remember(favorite.from)
        prefs.remember(favorite.to)
        XCTAssertEqual(prefs.recentPlaces.map(\.id), [favorite.to.id, favorite.from.id])
        store.save(prefs)
        XCTAssertEqual(store.loadPreferences(), prefs)

        let journey = try XCTUnwrap(snapshot.journeys.first)
        store.save(followed: FollowedJourney(request: snapshot.request, journey: journey, title: favorite.displayName))
        XCTAssertEqual(store.loadFollowed()?.journeyID, journey.id)
        store.save(followed: nil)
        XCTAssertNil(store.loadFollowed())
    }

    func testOldPreferencesFileStillLoads() throws {
        let legacy = #"{"commute":{"switchMinute":720},"favorites":[],"leaveNowAlerts":false,"hasCompletedOnboarding":true}"#
        let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data(legacy.utf8))
        XCTAssertFalse(prefs.leaveNowAlerts)
        XCTAssertTrue(prefs.hasCompletedOnboarding)
        XCTAssertTrue(prefs.favoriteTrips.isEmpty)
    }
}
