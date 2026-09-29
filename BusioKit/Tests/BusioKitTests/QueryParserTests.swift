import XCTest
@testable import BusioKit

final class QueryParserTests: XCTestCase {
    /// Mardi 29/09/2026, 17:47.
    private let now = TestData.date(2026, 9, 29, 17, 47)

    private func parse(_ text: String) -> ParsedQuery { QueryParser.parse(text, now: now) }

    func testArriveTomorrowAtWork() {
        let q = parse("Demain 9h au boulot")
        XCTAssertEqual(q.destination, .work)
        XCTAssertNil(q.origin)
        XCTAssertEqual(q.time, .arriveBy(TestData.date(2026, 9, 30, 9)))
        XCTAssertTrue(q.isConfident)
    }

    func testPastHourMeansTomorrow() {
        let q = parse("Gare de Mazamet avant 8h30")
        XCTAssertEqual(q.destination, .named("gare de mazamet"))
        XCTAssertEqual(q.time, .arriveBy(TestData.date(2026, 9, 30, 8, 30)))
    }

    func testOriginDestinationAndHour() {
        let q = parse("de l'Archipel à la gare SNCF à 18h30")
        XCTAssertEqual(q.origin, .named("archipel"))
        XCTAssertEqual(q.destination, .named("gare sncf"))
        XCTAssertEqual(q.time, .arriveBy(TestData.date(2026, 9, 29, 18, 30)))
    }

    func testDepartureWords() {
        XCTAssertEqual(parse("le bus de 19h pour Mazamet").time, .departAt(TestData.date(2026, 9, 29, 19)))
        XCTAssertEqual(parse("le bus de 19h pour Mazamet").destination, .named("mazamet"))
        XCTAssertEqual(parse("au boulot en partant à 7h45 demain").time, .departAt(TestData.date(2026, 9, 30, 7, 45)))
        XCTAssertEqual(parse("au boulot en partant à 7h45 demain").destination, .work)
        XCTAssertEqual(parse("Mazamet après 18 h").time, .departAt(TestData.date(2026, 9, 29, 18)))
        XCTAssertEqual(parse("pour 9:15 au lycée").time, .arriveBy(TestData.date(2026, 9, 30, 9, 15)))
    }

    func testRelativeTime() {
        let q = parse("dans 20 min de la gare au lycée")
        XCTAssertEqual(q.time, .departAt(now.addingTimeInterval(1_200)))
        XCTAssertEqual(q.origin, .named("gare"))
        XCTAssertEqual(q.destination, .named("lycee"))
    }

    func testEveningAndHome() {
        let q = parse("ce soir 8h à la maison")
        XCTAssertEqual(q.destination, .home)
        XCTAssertEqual(q.time, .arriveBy(TestData.date(2026, 9, 29, 20)))
        XCTAssertEqual(parse("rentrer chez moi maintenant").destination, .home)
        XCTAssertEqual(parse("rentrer chez moi maintenant").time, .now)
    }

    func testWeekdayAndPreference() {
        let q = parse("lundi 8h au travail sans correspondance")
        XCTAssertEqual(q.destination, .work)
        XCTAssertEqual(q.time, .arriveBy(TestData.date(2026, 10, 5, 8)))
        XCTAssertEqual(q.preference, .fewestTransfers)
        XCTAssertEqual(parse("au lycée à midi, le plus rapide").preference, .fastest)
        XCTAssertEqual(parse("au lycée à midi, le plus rapide").time, .arriveBy(TestData.date(2026, 9, 30, 12)))
        XCTAssertEqual(parse("gare sncf avec le moins d'attente").preference, .leastWaiting)
    }

    func testArrowAndApproximateMoment() {
        let arrow = parse("Archipel → Gares Mazamet")
        XCTAssertEqual(arrow.origin, .named("archipel"))
        XCTAssertEqual(arrow.destination, .named("gares mazamet"))
        XCTAssertNil(arrow.time)

        let vague = parse("demain matin à Mazamet depuis l'Archipel")
        XCTAssertEqual(vague.origin, .named("archipel"))
        XCTAssertEqual(vague.destination, .named("mazamet"))
        XCTAssertEqual(vague.time, .departAt(TestData.date(2026, 9, 30, 7)))
        XCTAssertTrue(vague.isTimeApproximate)
    }

    func testPlainPlaces() {
        XCTAssertEqual(parse("maison").destination, .home)
        XCTAssertEqual(parse("Je veux aller jusqu'à la place Jean-Jaurès").destination, .named("place jean jaures"))
        XCTAssertEqual(parse("prochain bus pour Castres stp").destination, .named("castres"))
        XCTAssertEqual(parse("9h30 à la place Jean Jaurès").time, .arriveBy(TestData.date(2026, 9, 30, 9, 30)))
        XCTAssertEqual(parse("d'ici à Mazamet").origin, .currentLocation)
        XCTAssertNil(parse("   ").destination)
        XCTAssertEqual(parse("lundi 8h au travail").origin, nil)
    }
}
