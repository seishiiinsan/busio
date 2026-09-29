import XCTest
@testable import BusioKit

final class TransitServiceTests: XCTestCase {
    private func offlineService() throws -> TransitService {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("busio-tests-\(UUID().uuidString)")
        // Port fermé : simule l'absence de réseau.
        let client = ZenbusClient(baseURL: URL(string: "http://127.0.0.1:9")!)
        return TransitService(configuration: .init(
            cacheDirectory: cache,
            seedDirectory: TestData.seed,
            client: client,
            gtfsURL: URL(string: "http://127.0.0.1:9/gtfs.zip")!
        ))
    }

    func testOfflineBoardFallsBackToTheoreticalSchedule() async throws {
        let service = try offlineService()
        let network = try await service.currentNetwork()
        XCTAssertEqual(network.lines.count, 12)

        let area = network.searchAreas("gares mazamet").first!
        let board = try await service.board(for: area, now: TestData.date(2026, 9, 29, 8, 0))
        XCTAssertFalse(board.departures.isEmpty)
        XCTAssertEqual(board.status.kind, .theoretical)
        XCTAssertNotNil(board.status.detail)
        XCTAssertTrue(board.departures.allSatisfy { $0.source == .gtfs })
        XCTAssertFalse(board.groups(in: network).isEmpty)

        let diagnostics = await service.diagnostics()
        XCTAssertNotNil(diagnostics.lastLiveError)
        XCTAssertGreaterThan(diagnostics.gtfsTripCount, 0)
    }

    func testOfflineCommutePlan() async throws {
        let service = try offlineService()
        let network = try await service.currentNetwork()
        let home = network.searchAreas("gares castres").first!, work = network.searchAreas("gares mazamet").first!
        let morning = try await service.plan(from: home, to: work, now: TestData.date(2026, 9, 29, 7, 45))
        XCTAssertFalse(morning.journeys.isEmpty)
        let evening = try await service.plan(from: work, to: home, now: TestData.date(2026, 9, 29, 16, 30))
        XCTAssertFalse(evening.journeys.isEmpty)
        XCTAssertTrue(evening.journeys.allSatisfy { $0.departureTime >= TestData.date(2026, 9, 29, 16, 29) })
    }
}
