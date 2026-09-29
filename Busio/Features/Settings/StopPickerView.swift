import SwiftUI
import BusioKit

/// Choix d'un arrêt (recherche + proximité).
struct StopPickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let title: String
    let selected: PlaceRef?
    let onPick: (StopArea) -> Void

    @State private var query = ""
    @State private var nearby: [NearbyArea] = []

    var body: some View {
        List {
            if let network = app.network {
                if query.isEmpty, !nearby.isEmpty {
                    Section("À proximité") {
                        ForEach(nearby) { item in
                            row(item.area, network: network, trailing: SearchView.distance(item.distance))
                        }
                    }
                }
                Section(query.isEmpty ? "Tous les arrêts" : "Résultats") {
                    ForEach(network.searchAreas(query)) { area in
                        row(area, network: network, trailing: nil)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Rechercher un arrêt")
        .task {
            guard let network = app.network, let here = await app.location.currentCoordinate() else { return }
            nearby = network.nearestAreas(to: here, limit: 5).map { NearbyArea(area: $0.area, distance: $0.distance) }
        }
    }

    private func row(_ area: StopArea, network: Network, trailing: String?) -> some View {
        Button {
            onPick(area)
            dismiss()
        } label: {
            HStack {
                AreaRow(area: area, network: network)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
                if selected?.areaID == area.id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
