import SwiftUI
import BusioKit

/// Choix d'un départ ou d'une arrivée.
struct PlaceSearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// Proposer « Ma position ».
    var allowsCurrentLocation = true
    let onPick: (Place?) -> Void

    @State private var query = ""
    @State private var searching = true
    @State private var search = PlaceSearchService()
    @State private var resolving: String?

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    suggestionsWhenEmpty
                } else {
                    results
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always), prompt: "Adresse, lieu ou arrêt")
            .onChange(of: query) { _, value in search.update(query: value) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }

    // MARK: Sans saisie

    @ViewBuilder
    private var suggestionsWhenEmpty: some View {
        if allowsCurrentLocation {
            Section {
                Button {
                    pick(nil)
                } label: {
                    Label("Ma position", systemImage: "location.fill")
                }
            }
        }
        let favoritePlaces = uniquePlaces(app.preferences.favoriteTrips.flatMap { [$0.from, $0.to] }.filter { $0.kind != .currentLocation })
        if !favoritePlaces.isEmpty {
            Section("Trajets favoris") {
                ForEach(favoritePlaces) { place in placeRow(place, icon: "star.fill") }
            }
        }
        if !app.preferences.recentPlaces.isEmpty {
            Section("Récents") {
                ForEach(app.preferences.recentPlaces) { place in placeRow(place, icon: "clock.arrow.circlepath") }
            }
        }
        if !app.favoriteAreas().isEmpty {
            Section("Arrêts favoris") {
                ForEach(app.favoriteAreas()) { area in placeRow(Place(stop: area), icon: "bus.fill") }
            }
        }
    }

    // MARK: Résultats

    @ViewBuilder
    private var results: some View {
        let stops = Array((app.network?.searchAreas(query) ?? []).prefix(5))
        if !stops.isEmpty {
            Section("Arrêts") {
                ForEach(stops) { area in
                    Button {
                        pick(Place(stop: area))
                    } label: {
                        HStack {
                            AreaRow(area: area, network: app.network)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !search.suggestions.isEmpty {
            Section("Adresses et lieux") {
                ForEach(search.suggestions) { suggestion in
                    Button {
                        Task {
                            resolving = suggestion.id
                            if let place = await search.resolve(suggestion) { pick(place) }
                            resolving = nil
                        }
                    } label: {
                        HStack {
                            Image(systemName: "mappin.circle.fill").foregroundStyle(.red).font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title).foregroundStyle(.primary)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if resolving == suggestion.id { ProgressView() }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if stops.isEmpty && search.suggestions.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private func placeRow(_ place: Place, icon: String) -> some View {
        Button {
            pick(place)
        } label: {
            HStack {
                Image(systemName: place.kind == .stop ? "bus.fill" : icon)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).foregroundStyle(.primary)
                    if let subtitle = place.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func uniquePlaces(_ places: [Place]) -> [Place] {
        var seen = Set<String>()
        return places.filter { seen.insert($0.id).inserted }
    }

    private func pick(_ place: Place?) {
        onPick(place)
        dismiss()
    }
}
