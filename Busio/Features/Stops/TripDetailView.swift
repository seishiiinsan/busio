import MapKit
import SwiftUI
import BusioKit

struct TripRoute: Hashable {
    let itineraryID: String
    let tripID: String
    /// Quais à mettre en évidence (montée / descente).
    let highlight: [String]
}

/// Déroulé d'une course : tous les arrêts, horaires prévus / estimés, position du bus.
struct TripDetailView: View {
    @Environment(AppModel.self) private var app
    let route: TripRoute

    @State private var trip: TripInstance?
    @State private var status: FeedStatus?
    @State private var notFound = false

    var body: some View {
        let itinerary = app.network?.itinerary(route.itineraryID)
        let line = itinerary.flatMap { app.network?.line($0.lineID) }
        List {
            if let trip {
                Section {
                    TripMap(trip: trip, itinerary: itinerary, line: line)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                }
                if let status, status.kind != .live {
                    Section { FeedStatusBanner(status: status).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                }
                Section {
                    ForEach(trip.calls, id: \.index) { call in
                        CallRow(call: call, trip: trip, line: line, highlighted: route.highlight.contains(call.stopID), isLast: call.index == trip.calls.last?.index)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    HStack {
                        QualityTag(quality: trip.quality)
                        Spacer()
                        if let vehicle = trip.vehicle, let timestamp = vehicle.timestamp {
                            Text("Position \(TimeText.clock(timestamp))").font(.caption)
                        }
                    }
                    .textCase(nil)
                }
            } else if notFound {
                ContentUnavailableView("Course introuvable", systemImage: "questionmark.circle", description: Text("Cette course n'apparaît plus dans les données Zenbus."))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(trip.map { "\(line?.displayName ?? "") → \($0.headsign)" } ?? "Course")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: route) {
            while !Task.isCancelled {
                await load(itinerary: itinerary)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func load(itinerary: Itinerary?) async {
        guard let itinerary else { notFound = true; return }
        guard let result = try? await app.service.trips(of: itinerary) else { return }
        status = result.status
        if let match = result.trips.first(where: { $0.id == route.tripID }) {
            trip = match
            notFound = false
        } else if trip == nil {
            notFound = true
        }
    }
}

private struct CallRow: View {
    @Environment(AppModel.self) private var app
    let call: StopCall
    let trip: TripInstance
    let line: Line?
    let highlighted: Bool
    let isLast: Bool

    var body: some View {
        let isVehicleHere = trip.state == .running && trip.vehicle?.previousStopIndex == call.index
        HStack(spacing: 12) {
            // Rail de la ligne
            ZStack {
                Rectangle()
                    .fill(line?.tint ?? .gray)
                    .frame(width: 4)
                    .opacity(call.passed ? 0.35 : 1)
                    .padding(.bottom, isLast ? 22 : -8)
                    .padding(.top, call.index == trip.calls.first?.index ? 22 : -8)
                Circle()
                    .fill(highlighted ? (line?.tint ?? .accentColor) : Color(.systemBackground))
                    .stroke(line?.tint ?? .gray, lineWidth: 3)
                    .frame(width: highlighted ? 16 : 12, height: highlighted ? 16 : 12)
                if isVehicleHere {
                    Image(systemName: "bus.fill")
                        .font(.caption2)
                        .foregroundStyle(line?.onTint ?? .white)
                        .padding(4)
                        .background(line?.tint ?? .accentColor, in: Circle())
                        .offset(y: 18)
                        .symbolEffect(.pulse, options: .repeating)
                }
            }
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.network?.stop(call.stopID)?.name ?? call.stopID)
                    .font(highlighted ? .body.weight(.semibold) : .body)
                    .foregroundStyle(call.passed ? .secondary : .primary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if let expected = call.expected ?? call.arrival {
                    Text(TimeText.clock(expected))
                        .font(.body.monospacedDigit().weight(call.expected != nil && !call.passed ? .semibold : .regular))
                        .foregroundStyle(call.passed ? .secondary : (call.expected != nil ? Color.green : .primary))
                }
                if let scheduled = call.scheduled, let expected = call.expected, abs(expected.timeIntervalSince(scheduled)) >= 60 {
                    Text(TimeText.clock(scheduled)).font(.caption.monospacedDigit()).strikethrough().foregroundStyle(.tertiary)
                }
            }
        }
        .frame(minHeight: 44)
    }
}

private struct TripMap: View {
    let trip: TripInstance
    let itinerary: Itinerary?
    let line: Line?
    @Environment(AppModel.self) private var app

    var body: some View {
        Map(initialPosition: .automatic) {
            if let itinerary {
                ForEach(Array(itinerary.paths.enumerated()), id: \.offset) { _, path in
                    MapPolyline(coordinates: path.map(\.clCoordinate))
                        .stroke(line?.tint ?? .accentColor, lineWidth: 4)
                }
            }
            ForEach(trip.calls, id: \.index) { call in
                if let stop = app.network?.stop(call.stopID) {
                    Annotation(stop.name, coordinate: stop.coordinate.clCoordinate, anchor: .center) {
                        Circle()
                            .fill(.white)
                            .stroke(line?.tint ?? .gray, lineWidth: 2)
                            .frame(width: 8, height: 8)
                    }
                    .annotationTitles(.hidden)
                }
            }
            if let vehicle = trip.vehicle {
                Annotation("Bus", coordinate: vehicle.coordinate.clCoordinate) {
                    BusMarker(line: line, heading: vehicle.heading, stale: vehicle.isStale(at: Date()))
                }
            }
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }
}

/// Pastille d'un bus sur une carte (flèche orientée si le cap est connu).
struct BusMarker: View {
    let line: Line?
    let heading: Double?
    var stale = false

    var body: some View {
        ZStack {
            if let heading {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(line?.tint ?? .accentColor)
                    .offset(y: -22)
                    .rotationEffect(.degrees(heading))
            }
            Text(line?.badge ?? "")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(line?.onTint ?? .white)
                .frame(minWidth: 30, minHeight: 30)
                .background(line?.tint ?? .accentColor, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 3, y: 1)
        }
        .opacity(stale ? 0.55 : 1)
    }
}
