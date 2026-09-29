import Foundation
@testable import BusioKit

enum TestData {
    static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let fixtures = testsDirectory.appendingPathComponent("Fixtures")
    /// Données embarquées dans l'app (Busio/Resources/Seed).
    static let seed = testsDirectory
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Busio/Resources/Seed")

    static let network: Network = {
        let data = try! Data(contentsOf: seed.appendingPathComponent("zenbus-static.bin"))
        return ZenbusMapper.network(from: try! ZenbusClient.decodeStatic(data))
    }()

    static let schedule: GTFSSchedule = try! GTFSSchedule(zipURL: seed.appendingPathComponent("gtfs.zip"))

    static func live(_ name: String) throws -> ZenbusRealtime_LiveMessage {
        try ZenbusClient.decodeLive(Data(contentsOf: fixtures.appendingPathComponent(name)))
    }

    /// Date locale Europe/Paris.
    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        TransitClock.calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    static func area(_ name: String) -> StopArea {
        guard let area = network.searchAreas(name).first else { fatalError("arrêt introuvable : \(name)") }
        return area
    }

    static let line10 = network.lines.first { $0.code == "10" }!
}
