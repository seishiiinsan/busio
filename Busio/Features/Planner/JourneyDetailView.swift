import MapKit
import SwiftUI
import BusioKit

/// Itinéraire pas à pas : marche, montée, arrêts, correspondance, arrivée.
struct JourneyDetailView: View {
    @Environment(AppModel.self) private var app
    let route: JourneyRoute
    let model: PlannerModel
    @State private var activityMessage: String?
    @State private var following = false

    /// Version la plus récente (le planificateur s'actualise en tâche de fond).
    private var journey: PlannedJourney { model.journey(id: route.journeyID) ?? route.journey }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                JourneyMap(journey: journey, origin: model.result?.origin, destination: model.result?.destination)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                header

                if let status = model.result?.status { FeedStatusBanner(status: status) }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        StepRow(step: step, isLast: index == steps.count - 1)
                    }
                }
                .padding(.vertical, 8)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Button {
                    Task { await follow() }
                } label: {
                    Label(following ? "Suivi sur l'écran verrouillé" : "Suivre ce trajet", systemImage: following ? "checkmark" : "platter.filled.bottom.iphone")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(journey.isWalkOnly)

                if let activityMessage {
                    Text(activityMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(model.to?.name ?? "Itinéraire")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(TimeText.clock(journey.departure)) → \(TimeText.clock(journey.arrival))")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Spacer()
                Text(TimeText.duration(journey.duration)).font(.title3.weight(.semibold))
            }
            JourneyLegsView(journey: journey)
            Text(summary).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        var parts: [String] = []
        parts.append(journey.transfers == 0 ? (journey.isWalkOnly ? "À pied" : "Direct") : "\(journey.transfers) correspondance\(journey.transfers > 1 ? "s" : "")")
        if journey.walkDuration >= 60 { parts.append("\(TimeText.duration(journey.walkDuration)) de marche") }
        if journey.transferWait >= 60 { parts.append("\(TimeText.duration(journey.transferWait)) d'attente") }
        return parts.joined(separator: " · ")
    }

    // MARK: Étapes

    enum Step {
        case start(name: String, time: Date)
        case walk(WalkLeg)
        case ride(RideLeg)
        case wait(TimeInterval, stop: String)
        case arrive(name: String, time: Date)
    }

    private var steps: [Step] {
        var steps: [Step] = [.start(name: model.result?.origin.name ?? "Départ", time: journey.departure)]
        var previousEnd: Date?
        for leg in journey.legs {
            if case .ride(let ride) = leg, let previousEnd {
                let wait = ride.departure.timeIntervalSince(previousEnd)
                if wait >= 60 { steps.append(.wait(wait, stop: app.network?.stop(ride.board.stopID)?.name ?? "l'arrêt")) }
            }
            switch leg {
            case .walk(let walk): steps.append(.walk(walk))
            case .ride(let ride): steps.append(.ride(ride))
            }
            previousEnd = leg.end
        }
        steps.append(.arrive(name: model.result?.destination.name ?? "Arrivée", time: journey.arrival))
        return steps
    }

    // MARK: Suivi

    private func follow() async {
        guard let snapshot = model.snapshot(network: app.network) else { return }
        guard JourneyActivityController.isEnabled else {
            activityMessage = "Les Live Activities sont désactivées pour Busio (Réglages › Busio)."
            return
        }
        do {
            try await JourneyActivityController.start(journey: journey, snapshot: snapshot, network: app.network)
            await JourneyAlerts.scheduleLeave(for: journey, snapshot: snapshot, id: "followed", preferences: app.preferences, network: app.network)
            following = true
            activityMessage = "Le compte à rebours s'affiche sur l'écran verrouillé et dans la Dynamic Island."
        } catch {
            activityMessage = error.localizedDescription
        }
    }
}

private struct StepRow: View {
    @Environment(AppModel.self) private var app
    let step: JourneyDetailView.Step
    let isLast: Bool
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(time.map(TimeText.clock) ?? "")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(width: 48, alignment: .trailing)
                .padding(.top, 2)
            ZStack(alignment: .top) {
                rail
                icon
            }
            .frame(width: 30)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 4 : 18)
        }
        .padding(.horizontal, 14)
    }

    private var time: Date? {
        switch step {
        case .start(_, let time), .arrive(_, let time): time
        case .walk(let walk): walk.start
        case .ride(let ride): ride.departure
        case .wait: nil
        }
    }

    @ViewBuilder
    private var rail: some View {
        if !isLast {
            switch step {
            case .ride(let ride):
                Rectangle().fill(app.network?.line(ride.lineID)?.tint ?? .gray).frame(width: 5).frame(maxHeight: .infinity).padding(.top, 14)
            default:
                Rectangle().fill(.quaternary).frame(width: 3).frame(maxHeight: .infinity).padding(.top, 14)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch step {
        case .start:
            Image(systemName: "circle.circle.fill").foregroundStyle(.blue).font(.title3).background(Circle().fill(Color(.secondarySystemGroupedBackground)))
        case .arrive:
            Image(systemName: "flag.checkered.circle.fill").foregroundStyle(.red).font(.title3).background(Circle().fill(Color(.secondarySystemGroupedBackground)))
        case .walk:
            Image(systemName: "figure.walk.circle.fill").foregroundStyle(.secondary).font(.title3).background(Circle().fill(Color(.secondarySystemGroupedBackground)))
        case .wait:
            Image(systemName: "hourglass.circle.fill").foregroundStyle(.orange).font(.title3).background(Circle().fill(Color(.secondarySystemGroupedBackground)))
        case .ride(let ride):
            LineBadge(line: app.network?.line(ride.lineID), size: .small)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .start(let name, _):
            Text(name).font(.headline)
        case .arrive(let name, _):
            Text("Arrivée · \(name)").font(.headline)
        case .walk(let walk):
            VStack(alignment: .leading, spacing: 2) {
                Text("Marcher jusqu'à \(walk.toName)").font(.subheadline.weight(.medium))
                Text("\(TimeText.duration(max(60, walk.duration))) · \(Int((walk.distance / 10).rounded() * 10)) m")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .wait(let duration, let stop):
            Text("Correspondance à \(stop) : \(TimeText.duration(duration)) d'attente")
                .font(.caption).foregroundStyle(.orange)
        case .ride(let ride):
            rideContent(ride)
        }
    }

    private func rideContent(_ ride: RideLeg) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(app.network?.line(ride.lineID)?.displayName ?? "Bus") → \(ride.headsign)")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                Text("Monter à \(name(ride.board.stopID))").font(.subheadline)
                QualityTag(quality: ride.quality, compact: true)
                DelayTag(delay: ride.delay)
            }
            if ride.isCancelled {
                Label("Course supprimée", systemImage: "xmark.octagon.fill").font(.caption.weight(.semibold)).foregroundStyle(.red)
            } else if let stops = ride.stopsAway {
                Label(stops == 0 ? "Le bus est à l'arrêt" : "Le bus est à \(stops) arrêt\(stops > 1 ? "s" : "")", systemImage: "bus.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if ride.calls.count > 2 {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(ride.calls.dropFirst().dropLast().enumerated()), id: \.offset) { _, call in
                            HStack {
                                Text(name(call.stopID)).font(.caption)
                                Spacer()
                                Text(call.departure.map(TimeText.clock) ?? "").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("\(ride.stopCount) arrêts · \(TimeText.duration(ride.arrival.timeIntervalSince(ride.departure)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Descendre à \(name(ride.alight.stopID)) · \(TimeText.clock(ride.arrival))")
                .font(.subheadline)
            if let itinerary = ride.itineraryID {
                NavigationLink(value: TripRoute(itineraryID: itinerary, tripID: ride.tripID, highlight: [ride.board.stopID, ride.alight.stopID])) {
                    Text("Voir la course").font(.caption.weight(.medium))
                }
            }
        }
    }

    private func name(_ stopID: String) -> String {
        app.network?.stop(stopID)?.name ?? stopID
    }
}

/// Carte de l'itinéraire : marche en pointillés, bus aux couleurs des lignes.
private struct JourneyMap: View {
    @Environment(AppModel.self) private var app
    let journey: PlannedJourney
    let origin: Place?
    let destination: Place?

    private struct Segment: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let dashed: Bool
    }

    private struct Pin: Identifiable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let color: Color
        let symbol: String
    }

    private var segments: [Segment] {
        journey.legs.enumerated().map { index, leg in
            switch leg {
            case .walk(let walk):
                return Segment(id: index, coordinates: [walk.from.clCoordinate, walk.to.clCoordinate], color: .gray, dashed: true)
            case .ride(let ride):
                let coordinates = ride.calls.compactMap { app.network?.stop($0.stopID)?.coordinate.clCoordinate }
                return Segment(id: index, coordinates: coordinates, color: app.network?.line(ride.lineID)?.tint ?? .accentColor, dashed: false)
            }
        }
    }

    private var pins: [Pin] {
        var pins: [Pin] = []
        if let origin, origin.kind != .currentLocation {
            pins.append(Pin(id: "origin", name: origin.name, coordinate: origin.coordinate.clCoordinate, color: .blue, symbol: "circle.fill"))
        }
        for ride in journey.rides {
            if let stop = app.network?.stop(ride.board.stopID) {
                pins.append(Pin(id: "b\(ride.tripID)", name: stop.name, coordinate: stop.coordinate.clCoordinate, color: app.network?.line(ride.lineID)?.tint ?? .accentColor, symbol: "bus.fill"))
            }
        }
        if let destination {
            pins.append(Pin(id: "destination", name: destination.name, coordinate: destination.coordinate.clCoordinate, color: .red, symbol: "flag.fill"))
        }
        return pins
    }

    var body: some View {
        Map(initialPosition: .automatic) {
            ForEach(segments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: segment.dashed ? 3 : 5, lineCap: .round, lineJoin: .round, dash: segment.dashed ? [4, 6] : []))
            }
            ForEach(pins) { pin in
                Marker(pin.name, systemImage: pin.symbol, coordinate: pin.coordinate)
                    .tint(pin.color)
            }
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
    }
}
