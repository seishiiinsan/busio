import AppIntents
import SwiftUI
import WidgetKit
import BusioKit

struct CommuteWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Mon trajet"
    static let description = IntentDescription("Prochains bus entre ton domicile et ton travail.")

    @Parameter(title: "Sens", default: .automatic)
    var direction: CommuteDirectionOption

    init() {}
}

struct CommuteEntry: TimelineEntry {
    let date: Date
    let snapshot: CommuteSnapshot?
    let needsSetup: Bool

    var journeys: [Journey] { snapshot?.upcoming(at: date).filter { !$0.isCancelled || $0.departureTime > date } ?? [] }

    var next: Journey? {
        guard let snapshot else { return nil }
        return CommuteRefresher.nextJourney(in: snapshot, now: date)
    }
}

struct CommuteProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CommuteEntry {
        CommuteEntry(date: Date(), snapshot: nil, needsSetup: false)
    }

    func snapshot(for configuration: CommuteWidgetIntent, in context: Context) async -> CommuteEntry {
        let now = Date()
        let direction = resolvedDirection(configuration, now: now)
        return CommuteEntry(date: now, snapshot: direction.flatMap { AppGroup.store.loadSnapshot($0) }, needsSetup: direction == nil)
    }

    func timeline(for configuration: CommuteWidgetIntent, in context: Context) async -> Timeline<CommuteEntry> {
        let now = Date()
        guard let direction = resolvedDirection(configuration, now: now) else {
            return Timeline(entries: [CommuteEntry(date: now, snapshot: nil, needsSetup: true)], policy: .after(now.addingTimeInterval(3600)))
        }
        // Données fraîches si possible (temps réel), sinon dernier état enregistré par l'app.
        var snapshot = AppGroup.store.loadSnapshot(direction)
        if let fresh = try? await CommuteRefresher.refresh(direction: direction, options: [], now: now) {
            snapshot = fresh
        }

        // Une entrée par départ pour que « le prochain bus » bascule tout seul.
        var dates = [now]
        for journey in snapshot?.journeys ?? [] where journey.departureTime > now {
            dates.append(journey.departureTime.addingTimeInterval(30))
        }
        let entries = dates.prefix(8).map { CommuteEntry(date: $0, snapshot: snapshot, needsSetup: false) }

        let preferences = AppGroup.store.loadPreferences()
        let inCommuteWindow = preferences.commute.isWorkday(now) && isNearCommute(now, settings: preferences.commute)
        let refresh = now.addingTimeInterval(inCommuteWindow ? 5 * 60 : 30 * 60)
        return Timeline(entries: entries, policy: .after(refresh))
    }

    private func resolvedDirection(_ configuration: CommuteWidgetIntent, now: Date) -> CommuteDirection? {
        let preferences = AppGroup.store.loadPreferences()
        guard preferences.commute.isConfigured else { return nil }
        return configuration.direction.direction ?? preferences.commute.direction(at: now)
    }

    /// 1 h 30 avant l'arrivée prévue au travail, ou autour de la sortie.
    private func isNearCommute(_ now: Date, settings: CommuteSettings) -> Bool {
        let morning = CommuteSettings.date(minute: settings.arriveByMinute, on: now)
        let evening = CommuteSettings.date(minute: settings.leaveWorkMinute, on: now)
        return (morning.addingTimeInterval(-90 * 60)...morning).contains(now)
            || (evening.addingTimeInterval(-30 * 60)...evening.addingTimeInterval(90 * 60)).contains(now)
    }
}

struct CommuteWidget: Widget {
    let kind = "CommuteWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: CommuteWidgetIntent.self, provider: CommuteProvider()) { entry in
            CommuteWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Mon trajet")
        .description("Le prochain bus pour aller au travail ou rentrer, en temps réel.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - Vues

struct CommuteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CommuteEntry

    var body: some View {
        if entry.needsSetup {
            Label("Configure ton trajet dans Busio", systemImage: "bus")
                .font(.caption)
                .widgetURL(URL(string: "busio://setup"))
        } else if let snapshot = entry.snapshot {
            switch family {
            case .systemMedium: MediumView(entry: entry, snapshot: snapshot)
            case .accessoryRectangular: RectangularView(entry: entry, snapshot: snapshot)
            case .accessoryCircular: CircularView(entry: entry, snapshot: snapshot)
            case .accessoryInline: InlineView(entry: entry, snapshot: snapshot)
            default: SmallView(entry: entry, snapshot: snapshot)
            }
        } else {
            Label("Ouvre Busio pour charger les horaires", systemImage: "arrow.clockwise")
                .font(.caption)
        }
    }
}

private struct Badge: View {
    let style: CommuteSnapshot.LineStyle?
    var size: CGFloat = 13

    var body: some View {
        Text(style?.badge ?? "–")
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(style?.onTint ?? .white)
            .padding(.horizontal, 5)
            .frame(minWidth: size * 2, minHeight: size * 1.5)
            .background(style?.tint ?? .gray, in: RoundedRectangle(cornerRadius: size * 0.4, style: .continuous))
    }
}

private struct LiveDot: View {
    let journey: Journey

    var body: some View {
        if journey.quality == .live {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
        } else if journey.quality == .theoretical {
            Image(systemName: "calendar").foregroundStyle(.secondary)
        }
    }
}

private struct SmallView: View {
    let entry: CommuteEntry
    let snapshot: CommuteSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.direction == .toWork ? "Vers \(snapshot.destinationName)" : "Retour \(snapshot.destinationName)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let journey = entry.next {
                HStack(spacing: 6) {
                    Badge(style: snapshot.style(for: journey.lineID))
                    LiveDot(journey: journey).font(.caption2)
                    Spacer(minLength: 0)
                }
                Text(TimeText.clock(journey.departureTime))
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(journey.departureTime, style: .relative)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
                let advice = LeaveAdvice(journey: journey, walk: snapshot.walk, buffer: snapshot.buffer)
                Spacer(minLength: 0)
                Text(advice.leaveAt > entry.date ? "Pars à \(TimeText.clock(advice.leaveAt))" : "Arrivée \(TimeText.clock(journey.arrivalTime))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
                Text("Plus de bus direct").font(.caption)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MediumView: View {
    let entry: CommuteEntry
    let snapshot: CommuteSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(snapshot.originName) → \(snapshot.destinationName)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if snapshot.status.kind != .live {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                }
            }
            ForEach(Array(entry.journeys.prefix(3))) { journey in
                HStack(spacing: 8) {
                    Badge(style: snapshot.style(for: journey.lineID))
                    Text(TimeText.clock(journey.departureTime))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .strikethrough(journey.isCancelled)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(TimeText.clock(journey.arrivalTime)).monospacedDigit().foregroundStyle(.secondary)
                    if let delay = TimeText.delay(journey.delay) {
                        Text(delay).font(.caption2.weight(.bold)).foregroundStyle(journey.delay! > 0 ? .red : .green)
                    }
                    Spacer(minLength: 0)
                    LiveDot(journey: journey).font(.caption2)
                    Text(journey.departureTime, style: .relative)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(journey.id == snapshot.recommendedID ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64, alignment: .trailing)
                }
            }
            if entry.journeys.isEmpty {
                Text("Plus de bus direct dans les prochaines heures.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct RectangularView: View {
    let entry: CommuteEntry
    let snapshot: CommuteSnapshot

    var body: some View {
        if let journey = entry.next {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "bus.fill")
                    Text("\(snapshot.style(for: journey.lineID)?.badge ?? "") · \(TimeText.clock(journey.departureTime))")
                        .font(.headline)
                        .monospacedDigit()
                    if journey.quality == .live { Image(systemName: "dot.radiowaves.left.and.right").font(.caption2) }
                }
                Text(journey.departureTime, style: .relative).font(.caption)
                Text("\(snapshot.originName) → \(snapshot.destinationName)").font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Plus de bus direct").font(.caption)
        }
    }
}

private struct CircularView: View {
    let entry: CommuteEntry
    let snapshot: CommuteSnapshot

    var body: some View {
        if let journey = entry.next {
            let minutes = TimeText.minutes(until: journey.departureTime, from: entry.date)
            Gauge(value: Double(max(0, 30 - min(minutes, 30))), in: 0...30) {
                Text(snapshot.style(for: journey.lineID)?.badge ?? "")
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
    let entry: CommuteEntry
    let snapshot: CommuteSnapshot

    var body: some View {
        if let journey = entry.next {
            Text("\(Image(systemName: "bus.fill")) \(snapshot.style(for: journey.lineID)?.badge ?? "") à \(TimeText.clock(journey.departureTime))")
        } else {
            Text("Plus de bus direct")
        }
    }
}
