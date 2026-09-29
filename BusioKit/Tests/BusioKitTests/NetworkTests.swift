import XCTest
@testable import BusioKit

final class NetworkTests: XCTestCase {
    func testStaticDataMapping() {
        let network = TestData.network
        XCTAssertEqual(network.lines.count, 12)
        XCTAssertEqual(network.itineraries.count, 36)
        XCTAssertEqual(network.stops.count, 428)
        XCTAssertEqual(network.lines.prefix(10).map(\.code), (1...10).map(String.init))

        let line10 = TestData.line10
        XCTAssertEqual(line10.color.hex, "#D3007B")
        XCTAssertEqual(line10.displayName, "Ligne 10")
        XCTAssertEqual(line10.badge, "10")

        let navettes = network.lines.filter { !$0.isNumbered }
        XCTAssertEqual(navettes.map(\.displayName).sorted(), ["Navette Centre", "Navette Siala"])
    }

    func testItinerariesHaveOrderedStopsDistancesAndPaths() {
        for itinerary in TestData.network.itineraries {
            XCTAssertFalse(itinerary.stopIDs.isEmpty, itinerary.rawName)
            XCTAssertNotNil(TestData.network.line(itinerary.lineID), itinerary.rawName)
            for stopID in itinerary.stopIDs { XCTAssertNotNil(TestData.network.stop(stopID), "\(itinerary.rawName) \(stopID)") }
            if let distances = itinerary.distances {
                XCTAssertEqual(distances, distances.sorted(), itinerary.rawName)
            }
        }
        let l10 = TestData.network.itineraries.first { $0.rawName == "GUYNEMER > GARES MAZAMET" }!
        XCTAssertEqual(l10.headsign, "Gares Mazamet")
        XCTAssertEqual(l10.origin, "Guynemer")
        XCTAssertFalse(l10.paths.isEmpty)
        XCTAssertGreaterThan(l10.paths[0].count, 50)
        XCTAssertLessThanOrEqual(l10.paths.count, 6)
    }

    func testStopAreasGroupPlatformsButKeepHomonymsApart() {
        let network = TestData.network
        let garesMazamet = TestData.area("gares mazamet")
        XCTAssertEqual(garesMazamet.name, "Gares Mazamet")
        XCTAssertTrue(garesMazamet.lineIDs.contains(TestData.line10.id))

        for area in network.areas {
            let coords = area.stopIDs.compactMap { network.stop($0)?.coordinate }
            for a in coords { for b in coords { XCTAssertLessThan(a.distance(to: b), 1_000, area.name) } }
        }
        // Chaque quai appartient à exactement un arrêt.
        XCTAssertEqual(network.areas.flatMap(\.stopIDs).count, network.stops.count)
        XCTAssertEqual(Set(network.areas.map(\.id)).count, network.areas.count)
    }

    func testSearchIsAccentAndCaseInsensitive() {
        let network = TestData.network
        XCTAssertEqual(network.searchAreas("GARES maz").first?.name, "Gares Mazamet")
        XCTAssertEqual(network.searchAreas("college thomas").first?.name, "Collège Thomas Pesquet")
        XCTAssertEqual(network.searchAreas("collège").isEmpty, false)
        XCTAssertTrue(network.searchAreas("zzzz").isEmpty)
    }

    func testNearestAreas() {
        let network = TestData.network
        let gare = TestData.area("gares castres")
        let nearest = network.nearestAreas(to: gare.coordinate, limit: 3)
        XCTAssertEqual(nearest.first?.area.id, gare.id)
        XCTAssertLessThan(nearest.first!.distance, 1)
    }

    func testPrettyNames() {
        XCTAssertEqual(TextFormatting.prettyStopName("GARES MAZAMET"), "Gares Mazamet")
        XCTAssertEqual(TextFormatting.prettyStopName("PLAN D'EAU"), "Plan d'Eau")
        XCTAssertEqual(TextFormatting.prettyStopName("COLLEGE JEAN-JAURES"), "Collège Jean-Jaures")
        XCTAssertEqual(TextFormatting.prettyStopName("MAIRIE PONT DE LARN"), "Mairie Pont de Larn")
        XCTAssertEqual(TextFormatting.prettyStopName("1ER MAI"), "1er Mai")
        XCTAssertEqual(TextFormatting.prettyStopName("GARE SNCF"), "Gare SNCF")
        XCTAssertEqual(TextFormatting.searchKey("  Écoles-Bisséous "), "ecoles bisseous")
    }

    func testServiceDayAcrossDSTChange() {
        // Passage à l'heure d'hiver le dimanche 25 octobre 2026.
        let day = ServiceDay(yyyymmdd: 20261025)!
        let eight = day.date(seconds: 8 * 3600)
        XCTAssertEqual(TransitClock.calendar.component(.hour, from: eight), 8)
        XCTAssertEqual(day.weekday, 1)
        XCTAssertEqual(day.next.yyyymmdd, 20261026)
        XCTAssertEqual(ServiceDay(yyyymmdd: 20260301)!.previous.yyyymmdd, 20260228)
        XCTAssertEqual(ServiceDay(containing: TestData.date(2026, 9, 29, 0, 30)).yyyymmdd, 20260929)
        XCTAssertNil(ServiceDay(yyyymmdd: 0))
    }
}
