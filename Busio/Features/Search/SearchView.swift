import SwiftUI
import BusioKit

/// Recherche d'arrêts + arrêts à proximité.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var nearby: [NearbyArea] = []
    @State private var locating = true
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let network = app.network {
                    if query.isEmpty {
                        nearbySection
                        if !app.favoriteAreas().isEmpty {
                            Section("Favoris") {
                                ForEach(app.favoriteAreas()) { area in
                                    NavigationLink(value: area) { AreaRow(area: area, network: network) }
                                }
                            }
                        }
                        Section("Tous les arrêts") {
                            ForEach(network.areas) { area in
                                NavigationLink(value: area) { AreaRow(area: area, network: network) }
                            }
                        }
                    } else {
                        let results = network.searchAreas(query)
                        if results.isEmpty {
                            ContentUnavailableView.search(text: query)
                        }
                        ForEach(results) { area in
                            NavigationLink(value: area) { AreaRow(area: area, network: network) }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Arrêts")
            .searchable(text: $query, prompt: "Nom d'arrêt")
            .navigationDestination(for: StopArea.self) { StopBoardView(area: $0) }
            .navigationDestination(for: TripRoute.self) { TripDetailView(route: $0) }
            .task { await loadNearby() }
            .task(id: app.network == nil) {
                if app.demoScreen == "stop", let area = app.network?.searchAreas("gare sncf").first {
                    path.append(area)
                    app.demoScreen = nil
                }
            }
        }
    }

    @ViewBuilder
    private var nearbySection: some View {
        Section("À proximité") {
            if app.location.isAuthorized {
                if locating && nearby.isEmpty {
                    HStack { ProgressView(); Text("Localisation…").foregroundStyle(.secondary) }
                } else if nearby.isEmpty {
                    Text("Aucun arrêt à moins de 1,5 km").foregroundStyle(.secondary)
                }
                ForEach(nearby) { item in
                    NavigationLink(value: item.area) {
                        HStack {
                            AreaRow(area: item.area, network: app.network)
                            Spacer()
                            Text(Self.distance(item.distance)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Button("Activer la localisation", systemImage: "location") {
                    app.location.requestPermission()
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        await loadNearby()
                    }
                }
            }
        }
    }

    private func loadNearby() async {
        // Réessaie tant que le réseau ou la position ne sont pas prêts.
        for _ in 0..<5 {
            if let network = app.network, let here = await app.location.currentCoordinate() {
                nearby = network.nearestAreas(to: here, limit: 6).map { NearbyArea(area: $0.area, distance: $0.distance) }
                break
            }
            try? await Task.sleep(for: .seconds(2))
        }
        locating = false
    }

    static func distance(_ meters: Double) -> String {
        meters < 1_000 ? "\(Int((meters / 10).rounded()) * 10) m" : String(format: "%.1f km", meters / 1_000)
    }
}

struct NearbyArea: Identifiable {
    let area: StopArea
    let distance: Double
    var id: String { area.id }
}

struct AreaRow: View {
    let area: StopArea
    let network: Network?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(area.name)
            HStack(spacing: 4) {
                ForEach(area.lineIDs, id: \.self) { LineBadge(line: network?.line($0), size: .small) }
            }
        }
        .padding(.vertical, 2)
    }
}
