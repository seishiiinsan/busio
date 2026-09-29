@preconcurrency import MapKit
import Observation
import BusioKit

/// Recherche d'adresses et de lieux avec Plans, centrée sur l'agglomération.
@Observable
@MainActor
final class PlaceSearchService: NSObject, MKLocalSearchCompleterDelegate {
    struct Suggestion: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let completion: MKLocalSearchCompletion
    }

    private(set) var suggestions: [Suggestion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    /// Castres – Mazamet et alentours.
    static let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 43.55, longitude: 2.30),
        span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.35)
    )

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = Self.region
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 2 {
            suggestions = []
            completer.cancel()
        } else {
            completer.queryFragment = trimmed
        }
    }

    /// Coordonnées d'une suggestion.
    func resolve(_ suggestion: Suggestion) async -> Place? {
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion.completion))
        guard let item = try? await search.start().mapItems.first else { return nil }
        let coordinate = item.location.coordinate
        let isAddress = suggestion.subtitle.isEmpty || item.pointOfInterestCategory == nil
        return Place(
            name: item.name ?? suggestion.title,
            subtitle: suggestion.subtitle.isEmpty ? nil : suggestion.subtitle,
            coordinate: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude),
            kind: isAddress ? .address : .pointOfInterest
        )
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            suggestions = completer.results.prefix(8).map {
                Suggestion(id: "\($0.title)|\($0.subtitle)", title: $0.title, subtitle: $0.subtitle, completion: $0)
            }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated { suggestions = [] }
    }
}
