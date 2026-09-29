import AppIntents
import SwiftUI
import WidgetKit
import BusioKit

struct TripWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Trajet favori"
    static let description = IntentDescription("Prochains départs d'un trajet favori, correspondances comprises.")

    @Parameter(title: "Trajet", description: "Vide : le trajet dont l'heure d'arrivée approche.")
    var trip: FavoriteTripEntity?

    init() {}
}

struct TripEntry: TimelineEntry {
    enum State { case ready, needsFavorite, noData }

    let date: Date
    let snapshot: TripSnapshot?
    let state: State

    var next: PlannedJourney? { snapshot?.next(at: date) }
    var upcoming: [PlannedJourney] { snapshot?.upcoming(at: date) ?? [] }
}

struct TripProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TripEntry {
        TripEntry(date: Date(), snapshot: nil, state: .noData)
    }

    func snapshot(for configuration: TripWidgetIntent, in context: Context) async -> TripEntry {
        let now = Date()
        guard let favorite = FavoriteTrip.resolve(configuration.trip, at: now) else {
            return TripEntry(date: now, snapshot: nil, state: .needsFavorite)
        }
        let snapshot = AppGroup.store.loadSnapshot(favoriteID: favorite.id)
        return TripEntry(date: now, snapshot: snapshot, state: snapshot == nil ? .noData : .ready)
    }

    func timeline(for configuration: TripWidgetIntent, in context: Context) async -> Timeline<TripEntry> {
        let now = Date()
        guard let favorite = FavoriteTrip.resolve(configuration.trip, at: now) else {
            return Timeline(entries: [TripEntry(date: now, snapshot: nil, state: .needsFavorite)], policy: .after(now.addingTimeInterval(3600)))
        }
        // Temps réel si possible, sinon dernier état calculé par l'app.
        var snapshot = AppGroup.store.loadSnapshot(favoriteID: favorite.id)
        if let fresh = try? await TripRefresher.refresh(favorite: favorite, now: now) { snapshot = fresh }
        guard let snapshot else {
            return Timeline(entries: [TripEntry(date: now, snapshot: nil, state: .noData)], policy: .after(now.addingTimeInterval(15 * 60)))
        }

        // Une entrée par départ pour que l'itinéraire mis en avant bascule tout seul.
        var dates = [now]
        for journey in snapshot.journeys where journey.departure > now {
            dates.append(journey.departure.addingTimeInterval(61))
        }
        let entries = dates.sorted().prefix(8).map { TripEntry(date: $0, snapshot: snapshot, state: .ready) }

        let soon = snapshot.journeys.contains { $0.departure.timeIntervalSince(now) < 45 * 60 }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(soon ? 5 * 60 : 30 * 60)))
    }
}

struct TripWidget: Widget {
    let kind = "TripWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TripWidgetIntent.self, provider: TripProvider()) { entry in
            TripWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Trajet favori")
        .description("Le prochain départ de ton trajet, correspondances et temps réel compris.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - Vues

struct TripWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TripEntry

    var body: some View {
        switch entry.state {
        case .needsFavorite:
            Label("Ajoute un trajet favori dans Busio", systemImage: "star")
                .font(.caption)
                .widgetURL(URL(string: "busio://planner"))
        case .noData:
            Label("Ouvre Busio pour charger les horaires", systemImage: "arrow.clockwise")
                .font(.caption)
        case .ready:
            if let snapshot = entry.snapshot {
                switch family {
                case .systemMedium: MediumView(entry: entry, snapshot: snapshot)
                case .accessoryRectangular: RectangularView(entry: entry, snapshot: snapshot)
                case .accessoryCircular: CircularView(entry: entry, snapshot: snapshot)
                case .accessoryInline: InlineView(entry: entry, snapshot: snapshot)
                default: SmallView(entry: entry, snapshot: snapshot)
                }
            }
        }
    }
}

/// « 🚶 › 3 › 10 » : enchaînement des bus d'un itinéraire.
struct LegStrip: View {
    let journey: PlannedJourney
    let snapshot: TripSnapshot
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(journey.rides.enumerated()), id: \.offset) { index, ride in
                if index > 0 {
                    Image(systemName: "chevron.compact.right").font(.system(size: size * 0.8)).foregroundStyle(.tertiary)
                }
                let style = snapshot.style(for: ride.lineID)
                Text(style?.badge ?? "?")
                    .font(.system(size: size, weight: .heavy, design: .rounded))
                    .foregroundStyle(style?.onTint ?? .white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: size * 1.9, minHeight: size * 1.5)
                    .background(style?.tint ?? .gray, in: RoundedRectangle(cornerRadius: size * 0.35, style: .continuous))
            }
            if journey.isWalkOnly {
                Image(systemName: "figure.walk").font(.system(size: size))
            }
        }
    }
}

private struct SmallView: View {
    let entry: TripEntry
    let snapshot: TripSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let journey = entry.next {
                HStack(spacing: 4) {
                    LegStrip(journey: journey, snapshot: snapshot)
                    if journey.quality == .live {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.caption2).foregroundStyle(.green)
                    }
                }
                let board = journey.firstRide?.departure ?? journey.departure
                Text(TimeText.clock(board))
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Text(board, style: .relative)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Text(journey.departure > entry.date && journey.departure < board ? "Pars à \(TimeText.clock(journey.departure))" : "Arrivée \(TimeText.clock(journey.arrival))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
                Text("Pas d'itinéraire prochainement").font(.caption)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MediumView: View {
    let entry: TripEntry
    let snapshot: TripSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(snapshot.title).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                if snapshot.status.kind != .live {
                    Image(systemName: "calendar").foregroundStyle(.orange).font(.caption)
                }
            }
            ForEach(Array(entry.upcoming.prefix(3))) { journey in
                HStack(spacing: 8) {
                    LegStrip(journey: journey, snapshot: snapshot)
                        .frame(width: 70, alignment: .leading)
                    Text(TimeText.clock(journey.firstRide?.departure ?? journey.departure))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .strikethrough(journey.isCancelled)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(TimeText.clock(journey.arrival)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if journey.quality == .live {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.caption2).foregroundStyle(.green)
                    }
                    Text(journey.firstRide?.departure ?? journey.departure, style: .relative)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(journey.id == entry.next?.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 62, alignment: .trailing)
                }
            }
            if entry.upcoming.isEmpty {
                Text("Pas d'itinéraire dans les prochaines heures.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct RectangularView: View {
    let entry: TripEntry
    let snapshot: TripSnapshot

    var body: some View {
        if let journey = entry.next, let ride = journey.firstRide {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "bus.fill")
                    Text(journey.rides.compactMap { snapshot.style(for: $0.lineID)?.badge }.joined(separator: "›") + " · " + TimeText.clock(ride.departure))
                        .font(.headline)
                        .monospacedDigit()
                }
                Text(ride.departure, style: .relative).font(.caption)
                Text("Arrivée \(TimeText.clock(journey.arrival))").font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(snapshot.title).font(.caption)
        }
    }
}

private struct CircularView: View {
    let entry: TripEntry
    let snapshot: TripSnapshot

    var body: some View {
        if let journey = entry.next, let ride = journey.firstRide {
            let minutes = TimeText.minutes(until: ride.departure, from: entry.date)
            Gauge(value: Double(max(0, 30 - min(minutes, 30))), in: 0...30) {
                Text(snapshot.style(for: ride.lineID)?.badge ?? "")
            } currentValueLabel: {
                Text("\(minutes)").font(.system(.title3, design: .rounded).weight(.bold))
            }
            .gaugeStyle(.accessoryCircular)
        } else {
            Image(systemName: "bus")
        }
    }
}

private struct InlineView: View {
    let entry: TripEntry
    let snapshot: TripSnapshot

    var body: some View {
        if let journey = entry.next, let ride = journey.firstRide {
            Text("\(Image(systemName: "bus.fill")) \(snapshot.style(for: ride.lineID)?.badge ?? "") à \(TimeText.clock(ride.departure)) → \(TimeText.clock(journey.arrival))")
        } else {
            Text(snapshot.title)
        }
    }
}

#if DEBUG
#Preview("Petit", as: .systemSmall) {
    TripWidget()
} timeline: {
    TripEntry(date: .now, snapshot: PreviewData.snapshot, state: .ready)
}

#Preview("Moyen", as: .systemMedium) {
    TripWidget()
} timeline: {
    TripEntry(date: .now, snapshot: PreviewData.snapshot, state: .ready)
}

#Preview("Écran verrouillé", as: .accessoryRectangular) {
    TripWidget()
} timeline: {
    TripEntry(date: .now, snapshot: PreviewData.snapshot, state: .ready)
}
#endif
