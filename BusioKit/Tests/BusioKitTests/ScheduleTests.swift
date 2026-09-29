import XCTest
@testable import BusioKit

final class ScheduleTests: XCTestCase {
    func testLiveSnapshotFromFixtures() throws {
        let network = TestData.network
        for name in ["poll-l10-castres-mazamet.bin", "poll-l10-mazamet-castres.bin", "poll-l1-chartreuse-gare.bin"] {
            let snapshot = ZenbusMapper.snapshot(from: try TestData.live(name), network: network)
            XCTAssertFalse(snapshot.trips.isEmpty, name)
            XCTAssertEqual(snapshot.serviceDays.count, 1, name)
            for trip in snapshot.trips {
                XCTAssertEqual(trip.source, .zenbus)
                XCTAssertEqual(trip.calls.map(\.index), trip.calls.map(\.index).sorted(), name)
                let departures = trip.calls.compactMap(\.scheduled)
                XCTAssertEqual(departures, departures.sorted(), "\(name) \(trip.id)")
                XCTAssertEqual(trip.calls.first?.stopID, network.itinerary(trip.itineraryID!)!.stopIDs[trip.calls.first!.index])
            }
            XCTAssertEqual(Set(snapshot.trips.map(\.id)).count, snapshot.trips.count, "identifiants uniques")
        }
    }

    func testGTFSLoadsAndMapsToZenbusIdentifiers() {
        let schedule = TestData.schedule
        let network = TestData.network
        XCTAssertGreaterThan(schedule.tripCount, 500)
        XCTAssertEqual(schedule.info.endDay?.yyyymmdd, 20261231)
        let stopIDs = Set(schedule.trips.flatMap { $0.calls.map(\.stopID) })
        let known = stopIDs.filter { network.stop($0) != nil }
        XCTAssertGreaterThan(Double(known.count) / Double(stopIDs.count), 0.95, "quais GTFS reconnus dans Zenbus")
        let lines = Set(schedule.trips.map(\.lineID))
        XCTAssertTrue(lines.isSubset(of: Set(network.lines.map(\.id))))
    }

    func testGTFSServiceCalendar() {
        let schedule = TestData.schedule
        let network = TestData.network
        let tuesday = ServiceDay(yyyymmdd: 20260929)!
        let sunday = ServiceDay(yyyymmdd: 20260927)!
        let christmas = ServiceDay(yyyymmdd: 20261225)!
        let tuesdayTrips = schedule.trips(ofLine: TestData.line10.id, on: tuesday, network: network)
        XCTAssertGreaterThan(tuesdayTrips.count, 10)
        XCTAssertLessThan(schedule.trips(ofLine: TestData.line10.id, on: sunday, network: network).count, tuesdayTrips.count)
        XCTAssertLessThan(schedule.trips(ofLine: TestData.line10.id, on: christmas, network: network).count, tuesdayTrips.count)
        XCTAssertGreaterThan(tuesdayTrips.filter { $0.itineraryID != nil }.count, tuesdayTrips.count * 9 / 10, "courses rattachées à un sens Zenbus")
    }

    /// Le GTFS publié correspond-il encore à la grille réellement exploitée par Zenbus ?
    func testGTFSMatchesZenbusPlannedTimetable() throws {
        let network = TestData.network
        let schedule = TestData.schedule
        var matched = 0, total = 0
        for name in ["poll-l10-castres-mazamet.bin", "poll-l10-mazamet-castres.bin", "poll-l1-chartreuse-gare.bin"] {
            let snapshot = ZenbusMapper.snapshot(from: try TestData.live(name), network: network)
            guard let day = snapshot.serviceDays.values.first else { continue }
            for trip in snapshot.trips {
                guard let first = trip.calls.first, let time = first.scheduled else { continue }
                total += 1
                let gtfs = schedule.trips(servingAny: [first.stopID], from: time.addingTimeInterval(-60), to: time.addingTimeInterval(60), network: network)
                if gtfs.contains(where: { $0.serviceDay == day && $0.lineID == trip.lineID }) { matched += 1 }
            }
        }
        let ratio = Double(matched) / Double(max(total, 1))
        print("Concordance GTFS/Zenbus : \(matched)/\(total) = \(Int(ratio * 100)) %")
        XCTAssertGreaterThan(total, 10)
        XCTAssertGreaterThan(ratio, 0.8)
    }

    func testMergePrefersZenbusOnlyForPublishedDays() throws {
        let network = TestData.network
        let message = try TestData.live("poll-l10-castres-mazamet.bin")
        let snapshot = ZenbusMapper.snapshot(from: message, network: network)
        let (itineraryID, zenbusDay) = snapshot.serviceDays.first!
        let itinerary = network.itinerary(itineraryID)!
        let coverage: Set<String> = [TripPlanner.coverageKey(lineID: itinerary.lineID, itineraryID: itineraryID, day: zenbusDay)]

        // Jour publié par Zenbus : le GTFS de ce sens est écarté.
        let sameDay = TestData.schedule.trips(ofLine: itinerary.lineID, on: zenbusDay, network: network)
        let mergedSame = TripPlanner.merge(zenbus: snapshot.trips, coverage: coverage, gtfs: sameDay)
        XCTAssertFalse(mergedSame.contains { $0.source == .gtfs && $0.itineraryID == itineraryID })

        // Lendemain non publié : le GTFS prend le relais.
        let nextDay = TestData.schedule.trips(ofLine: itinerary.lineID, on: zenbusDay.next, network: network)
        let mergedNext = TripPlanner.merge(zenbus: snapshot.trips, coverage: coverage, gtfs: nextDay)
        XCTAssertTrue(mergedNext.contains { $0.source == .gtfs && $0.itineraryID == itineraryID } || nextDay.isEmpty)
    }

    func testDeparturesSkipTerminusAndPastTimes() {
        let network = TestData.network
        let gares = TestData.area("gares mazamet")
        let now = TestData.date(2026, 9, 29, 8, 0)
        let trips = TestData.schedule.trips(servingAny: Set(gares.stopIDs), from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(7200), network: network)
        let departures = TripPlanner.departures(from: trips, at: Set(gares.stopIDs), now: now, horizon: 7200)
        XCTAssertFalse(departures.isEmpty)
        XCTAssertEqual(departures.map(\.time), departures.map(\.time).sorted())
        for departure in departures {
            XCTAssertGreaterThanOrEqual(departure.time, now.addingTimeInterval(-60))
            let trip = trips.first { $0.id == departure.tripID }!
            XCTAssertNotEqual(departure.call.index, trip.calls.last!.index, "pas de départ au terminus")
        }
    }

    static func hhmm(_ date: Date) -> String {
        let c = TransitClock.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }
}
