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
}
