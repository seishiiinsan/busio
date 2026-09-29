import SwiftUI
import BusioKit

/// Liste des lignes du réseau Libellus.
struct LinesView: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let network = app.network {
                    ForEach(network.lines) { line in
                        NavigationLink(value: line) {
                            HStack(spacing: 12) {
                                LineBadge(line: line, size: .large)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.displayName).font(.headline)
                                    Text(Self.termini(of: line, in: network))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Lignes")
            .navigationDestination(for: Line.self) { LineDetailView(line: $0) }
            .navigationDestination(for: StopArea.self) { StopBoardView(area: $0) }
            .navigationDestination(for: TripRoute.self) { TripDetailView(route: $0) }
            .task(id: app.network == nil) {
                if app.demoScreen == "line", let line = app.network?.lines.first(where: { $0.code == "10" }) {
                    path.append(line)
                    app.demoScreen = nil
                }
            }
        }
    }

    /// « Guynemer ↔ Gares Mazamet »
    static func termini(of line: Line, in network: Network) -> String {
        let itineraries = network.itineraries(ofLine: line.id).sorted { $0.stopIDs.count > $1.stopIDs.count }
        guard let main = itineraries.first else { return "" }
        return "\(main.origin) ↔ \(main.headsign)"
    }
}

/// Schéma d'un sens de ligne : arrêts, prochains passages, bus en circulation.
struct LineDetailView: View {
    @Environment(AppModel.self) private var app
    let line: Line

    @State private var itineraryID: String?
    @State private var trips: [TripInstance] = []
    @State private var status: FeedStatus?
    @State private var alerts: [ServiceAlert] = []

    var body: some View {
        let itineraries = (app.network?.itineraries(ofLine: line.id) ?? []).sorted { $0.stopIDs.count > $1.stopIDs.count }
        let itinerary = itineraries.first { $0.id == itineraryID } ?? itineraries.first
        List {
            Section {
                Picker("Direction", selection: Binding(get: { itinerary?.id }, set: { itineraryID = $0 })) {
                    ForEach(itineraries) { item in
                        Text("\(item.origin) → \(item.headsign)").tag(Optional(item.id))
                    }
                }
                .pickerStyle(.menu)
            }
            if let status, status.kind != .live {
                Section { FeedStatusBanner(status: status).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            }
            if let itinerary {
                let next = Self.nextPassages(trips: trips, now: Date())
                let vehicles = Self.vehicles(trips: trips)
                Section("\(itinerary.stopIDs.count) arrêts") {
                    ForEach(Array(itinerary.stopIDs.enumerated()), id: \.offset) { index, stopID in
                        LineStopRow(
                            line: line,
                            stopName: app.network?.stop(stopID)?.name ?? stopID,
                            area: app.network?.area(containingStop: stopID),
                            nextPassage: next[index],
                            busesAfter: vehicles[index] ?? 0,
                            isFirst: index == 0,
                            isLast: index == itinerary.stopIDs.count - 1
                        )
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(line.displayName)
        .toolbar {
            ToolbarItem(placement: .principal) { LineBadge(line: line, size: .large) }
        }
        .task(id: itinerary?.id) {
            guard let itinerary else { return }
            trips = []
            while !Task.isCancelled {
                if let result = try? await app.service.trips(of: itinerary) {
                    trips = result.trips
                    status = result.status
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Prochain passage par position dans le sens.
    static func nextPassages(trips: [TripInstance], now: Date) -> [Int: (date: Date, live: Bool)] {
        var result: [Int: (date: Date, live: Bool)] = [:]
        for trip in trips where trip.state != .finished && trip.state != .cancelled {
            for call in trip.calls where !call.passed {
                guard let date = call.departure, date >= now.addingTimeInterval(-30) else { continue }
                if let existing = result[call.index], existing.date <= date { continue }
                result[call.index] = (date, trip.quality == .live && call.expected != nil)
            }
        }
        return result
    }

    /// Nombre de bus entre l'arrêt i et le suivant.
    static func vehicles(trips: [TripInstance]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for trip in trips where trip.state == .running {
            if let index = trip.vehicle?.previousStopIndex { result[index, default: 0] += 1 }
        }
        return result
    }
}

private struct LineStopRow: View {
    let line: Line
    let stopName: String
    let area: StopArea?
    let nextPassage: (date: Date, live: Bool)?
    let busesAfter: Int
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        let content = HStack(spacing: 12) {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(line.tint)
                    .frame(width: 5)
                    .padding(.top, isFirst ? 22 : -8)
                    .padding(.bottom, isLast ? 22 : -8)
                    .frame(maxHeight: .infinity)
                if busesAfter > 0 {
                    // Un bus vient de desservir cet arrêt (ou y est à quai).
                    Image(systemName: "bus.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(line.onTint)
                        .frame(width: 24, height: 24)
                        .background(line.tint, in: Circle())
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .padding(.top, 10)
                        .symbolEffect(.pulse, options: .repeating)
                        .accessibilityLabel("Bus à cet arrêt")
                } else {
                    Circle()
                        .fill(Color(.systemBackground))
                        .stroke(line.tint, lineWidth: 3)
                        .frame(width: 13, height: 13)
                        .padding(.top, 15)
                }
            }
            .frame(width: 26)

            Text(stopName)
                .font(isFirst || isLast ? .body.weight(.semibold) : .body)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let nextPassage {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    HStack(spacing: 4) {
                        if nextPassage.live {
                            Image(systemName: "dot.radiowaves.left.and.right").font(.caption2).foregroundStyle(.green)
                        }
                        Text(TimeText.countdown(to: nextPassage.date, from: context.date))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
        }
        .frame(minHeight: 44)

        if let area {
            NavigationLink(value: area) { content }
        } else {
            content
        }
    }
}
