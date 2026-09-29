import MapKit
import SwiftUI
import BusioKit

/// Prochains départs d'un arrêt, regroupés par ligne et direction.
struct StopBoardView: View {
    @Environment(AppModel.self) private var app
    let area: StopArea

    @State private var board: StopBoard?
    @State private var error: String?
    @State private var walk: TimeInterval?

    var body: some View {
        List {
            Section {
                StopHeader(area: area, walk: walk)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if let board {
                if board.status.kind != .live {
                    Section { FeedStatusBanner(status: board.status).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                }
                if !board.alerts.isEmpty {
                    Section("Infos trafic") { AlertsList(alerts: board.alerts, network: app.network) }
                }
                if let network = app.network {
                    let groups = board.groups(in: network)
                    if groups.isEmpty {
                        ContentUnavailableView("Aucun départ", systemImage: "moon.zzz", description: Text("Pas de bus dans les 3 prochaines heures."))
                    }
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.departures.prefix(4)) { departure in
                                DepartureRow(departure: departure)
                            }
                        } header: {
                            HStack(spacing: 8) {
                                LineBadge(line: network.line(group.lineID))
                                Text("→ \(group.headsign)").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    .textCase(nil)
                            }
                        }
                    }
                }
            } else if let error {
                ContentUnavailableView("Horaires indisponibles", systemImage: "wifi.exclamationmark", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(area.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    app.toggleFavorite(area)
                } label: {
                    Image(systemName: app.isFavorite(area) ? "star.fill" : "star")
                }
                .accessibilityLabel(app.isFavorite(area) ? "Retirer des favoris" : "Ajouter aux favoris")
                .sensoryFeedback(.selection, trigger: app.isFavorite(area))
            }
        }
        .refreshable { await load() }
        .task(id: area.id) {
            walk = await app.walkingTime(to: area)
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func load() async {
        do {
            board = try await app.service.board(for: area)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct StopHeader: View {
    @Environment(AppModel.self) private var app
    let area: StopArea
    let walk: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Map(initialPosition: .region(MKCoordinateRegion(center: area.coordinate.clCoordinate, latitudinalMeters: 450, longitudinalMeters: 450))) {
                ForEach(area.stopIDs, id: \.self) { stopID in
                    if let stop = app.network?.stop(stopID) {
                        Marker(stop.name, systemImage: "bus.fill", coordinate: stop.coordinate.clCoordinate)
                            .tint(.accentColor)
                    }
                }
                UserAnnotation()
            }
            .mapControlVisibility(.hidden)
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .allowsHitTesting(false)

            HStack(spacing: 6) {
                ForEach(area.lineIDs, id: \.self) { LineBadge(line: app.network?.line($0), size: .small) }
                Spacer()
                if let walk {
                    Label(TimeText.duration(walk), systemImage: "figure.walk").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct DepartureRow: View {
    let departure: Departure

    var body: some View {
        let row = HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    QualityTag(quality: departure.quality)
                    DelayTag(delay: departure.delay)
                }
                if departure.isCancelled {
                    Text("Supprimé").font(.caption.weight(.semibold)).foregroundStyle(.red)
                } else if let stops = departure.stopsAway {
                    Text(stops == 0 ? "À l'arrêt" : "À \(stops) arrêt\(stops > 1 ? "s" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            DepartureClock(date: departure.time, scheduled: departure.scheduledTime, cancelled: departure.isCancelled)
        }
        .padding(.vertical, 2)

        if let itinerary = departure.itineraryID {
            NavigationLink(value: TripRoute(itineraryID: itinerary, tripID: departure.tripID, highlight: [departure.call.stopID])) { row }
        } else {
            row
        }
    }
}

/// Aperçu des favoris sur l'écran d'accueil.
struct FavoritesSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let favorites = app.favoriteAreas()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Arrêts favoris").font(.title3.bold())
                Spacer()
                Button("Ajouter", systemImage: "plus") { app.selectedTab = .search }
                    .labelStyle(.iconOnly)
            }
            if favorites.isEmpty {
                Text("Touche ☆ sur un arrêt pour l'épingler ici.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(favorites) { area in
                NavigationLink(value: area) { FavoriteCard(area: area) }
                    .buttonStyle(.plain)
            }
        }
    }
}

private struct FavoriteCard: View {
    @Environment(AppModel.self) private var app
    let area: StopArea
    @State private var board: StopBoard?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(area.name).font(.headline)
                Spacer()
                if let board, board.status.kind != .live {
                    Image(systemName: "calendar").font(.caption).foregroundStyle(.orange)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if let board, let network = app.network {
                let groups = board.groups(in: network).prefix(4)
                if groups.isEmpty {
                    Text("Aucun départ prochainement").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(groups)) { group in
                    HStack(spacing: 8) {
                        LineBadge(line: network.line(group.lineID), size: .small)
                        Text(group.headsign).font(.subheadline).lineLimit(1)
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            Text(group.departures.prefix(2).map { TimeText.countdown(to: $0.time, from: context.date) }.joined(separator: " · "))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                        if group.departures.first?.quality == .live {
                            QualityTag(quality: .live, compact: true)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: area.id) {
            while !Task.isCancelled {
                board = try? await app.service.board(for: area, horizon: 2 * 3600)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
