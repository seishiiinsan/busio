import MapKit
import SwiftUI
import BusioKit

/// Carte des bus en circulation (positions Zenbus rafraîchies toutes les 10 s).
struct LiveMapView: View {
    @Environment(AppModel.self) private var app
    @State private var position: MapCameraPosition = .region(Self.agglomeration)
    @State private var trips: [TripInstance] = []
    @State private var hiddenLines: Set<String> = []
    @State private var selectedTrip: TripInstance?
    @State private var cameraDistance: Double = 30_000
    @State private var lastUpdate: Date?
    @State private var failed = false

    static let agglomeration = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 43.548, longitude: 2.305),
        span: MKCoordinateSpan(latitudeDelta: 0.17, longitudeDelta: 0.22)
    )

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                ForEach(polylines) { polyline in
                    MapPolyline(coordinates: polyline.coordinates)
                        .stroke(polyline.tint.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
                ForEach(cameraDistance < 5_000 ? (app.network?.areas ?? []) : []) { area in
                    Annotation(area.name, coordinate: area.coordinate.clCoordinate, anchor: .center) {
                        NavigationLink(value: area) {
                            Circle()
                                .fill(.background)
                                .stroke(.secondary, lineWidth: 2)
                                .frame(width: 10, height: 10)
                        }
                    }
                    .annotationTitles(cameraDistance < 2_000 ? .automatic : .hidden)
                }
                ForEach(buses) { bus in
                    Annotation(bus.trip.headsign, coordinate: bus.vehicle.coordinate.clCoordinate, anchor: .center) {
                        Button {
                            selectedTrip = bus.trip
                        } label: {
                            BusMarker(line: app.network?.line(bus.trip.lineID), heading: bus.vehicle.heading, stale: bus.vehicle.isStale(at: Date()))
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(.hidden)
                }
                UserAnnotation()
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll, showsTraffic: false))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                cameraDistance = context.camera.distance
            }
            .safeAreaInset(edge: .top) { lineFilter }
            .overlay(alignment: .bottom) { statusPill.padding(.bottom, 12) }
            .navigationDestination(for: StopArea.self) { StopBoardView(area: $0) }
            .navigationDestination(for: TripRoute.self) { TripDetailView(route: $0) }
            .sheet(item: $selectedTrip) { trip in
                NavigationStack {
                    if let itinerary = trip.itineraryID {
                        TripDetailView(route: TripRoute(itineraryID: itinerary, tripID: trip.id, highlight: []))
                            .navigationDestination(for: StopArea.self) { StopBoardView(area: $0) }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .task {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var visibleTrips: [TripInstance] {
        trips.filter { !hiddenLines.contains($0.lineID) }
    }

    private struct Bus: Identifiable {
        let trip: TripInstance
        let vehicle: VehicleSnapshot
        var id: String { trip.id }
    }

    private var buses: [Bus] {
        visibleTrips.compactMap { trip in trip.vehicle.map { Bus(trip: trip, vehicle: $0) } }
    }

    private struct Polyline: Identifiable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let tint: Color
    }

    private var polylines: [Polyline] {
        guard let network = app.network else { return [] }
        return network.itineraries.filter { !hiddenLines.contains($0.lineID) }.flatMap { itinerary in
            itinerary.paths.enumerated().map { index, path in
                Polyline(id: "\(itinerary.id)-\(index)", coordinates: path.map(\.clCoordinate), tint: network.line(itinerary.lineID)?.tint ?? .gray)
            }
        }
    }

    private func load() async {
        do {
            trips = try await app.service.runningTrips()
            lastUpdate = Date()
            failed = false
        } catch {
            failed = true
        }
    }

    private var lineFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(app.network?.lines ?? []) { line in
                        let hidden = hiddenLines.contains(line.id)
                        Button {
                            withAnimation(.snappy) {
                                if hidden { hiddenLines.remove(line.id) } else { hiddenLines.insert(line.id) }
                            }
                        } label: {
                            LineBadge(line: line, size: .small)
                                .opacity(hidden ? 0.35 : 1)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .accessibilityLabel("\(line.displayName) \(hidden ? "masquée" : "affichée")")
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 6)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            if failed {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text("Zenbus injoignable")
            } else if lastUpdate == nil {
                ProgressView()
                Text("Localisation des bus…")
            } else if visibleTrips.isEmpty {
                Image(systemName: "moon.zzz")
                Text("Aucun bus suivi en ce moment")
            } else {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("\(visibleTrips.count) bus en circulation")
            }
            if let lastUpdate {
                Text("· \(TimeText.clock(lastUpdate))").foregroundStyle(.secondary)
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}
