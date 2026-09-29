import SwiftUI
import BusioKit

/// Pastille de ligne aux couleurs officielles.
struct LineBadge: View {
    let line: Line?
    var size: Size = .regular

    enum Size {
        case small, regular, large

        var font: Font {
            switch self {
            case .small: .system(.caption, design: .rounded).weight(.heavy)
            case .regular: .system(.subheadline, design: .rounded).weight(.heavy)
            case .large: .system(.title3, design: .rounded).weight(.heavy)
            }
        }

        var minWidth: CGFloat {
            switch self {
            case .small: 24
            case .regular: 32
            case .large: 44
            }
        }
    }

    var body: some View {
        Text(line?.badge ?? "?")
            .font(size.font)
            .foregroundStyle(line?.onTint ?? .white)
            .lineLimit(1)
            .padding(.horizontal, size == .large ? 8 : 5)
            .padding(.vertical, size == .large ? 4 : 2)
            .frame(minWidth: size.minWidth)
            .background(line?.tint ?? .gray, in: RoundedRectangle(cornerRadius: size == .large ? 10 : 7, style: .continuous))
            .accessibilityLabel(line?.displayName ?? "Ligne inconnue")
    }
}

/// Indique la fiabilité d'un horaire (direct, prévu, théorique).
struct QualityTag: View {
    let quality: TimingQuality
    var compact = false

    var body: some View {
        Group {
            if compact {
                Image(systemName: quality.symbol)
            } else {
                Label(quality.label, systemImage: quality.symbol)
            }
        }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: quality == .live)
            .accessibilityLabel(quality.label)
    }

    private var color: Color {
        switch quality {
        case .live: .green
        case .estimated: .teal
        case .planned: .secondary
        case .theoretical: .orange
        }
    }
}

/// Retard / avance.
struct DelayTag: View {
    let delay: TimeInterval?

    var body: some View {
        if let text = TimeText.delay(delay), let delay {
            Text(text)
                .font(.caption2.weight(.bold))
                .foregroundStyle(delay > 0 ? .red : .blue)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background((delay > 0 ? Color.red : Color.blue).opacity(0.12), in: Capsule())
        } else if delay != nil {
            Text("à l'heure")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        }
    }
}

/// Bandeau expliquant l'état des données (temps réel indisponible, etc.).
struct FeedStatusBanner: View {
    let status: FeedStatus

    var body: some View {
        if status.kind != .live {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let detail = status.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if let last = status.lastLiveUpdate {
                        Text("Dernier relevé Zenbus : \(TimeText.clock(last))").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private var title: String {
        switch status.kind {
        case .live: "Temps réel"
        case .partial: "Temps réel partiel"
        case .theoretical: "Horaires théoriques"
        case .unavailable: "Données indisponibles"
        }
    }

    private var icon: String {
        switch status.kind {
        case .live: "dot.radiowaves.left.and.right"
        case .partial: "exclamationmark.circle.fill"
        case .theoretical: "calendar.badge.exclamationmark"
        case .unavailable: "wifi.exclamationmark"
        }
    }

    private var tint: Color {
        switch status.kind {
        case .live: .green
        case .partial, .theoretical: .orange
        case .unavailable: .red
        }
    }
}

/// Messages d'information voyageurs.
struct AlertsList: View {
    let alerts: [ServiceAlert]
    let network: Network?

    var body: some View {
        ForEach(alerts) { alert in
            DisclosureGroup {
                Text(alert.message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: alert.severity == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(alert.severity == .severe ? .red : (alert.severity == .warning ? .orange : .blue))
                    ForEach(alert.lineIDs.prefix(3), id: \.self) { LineBadge(line: network?.line($0), size: .small) }
                    Text(alert.title).font(.subheadline.weight(.medium)).lineLimit(2)
                }
            }
        }
    }
}

/// Heure de passage avec compte à rebours qui se met à jour chaque seconde.
struct DepartureClock: View {
    let date: Date
    var scheduled: Date?
    var cancelled = false
    var emphasize = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .trailing, spacing: 0) {
                Text(TimeText.countdown(to: date, from: context.date))
                    .font(emphasize ? .system(.title3, design: .rounded).weight(.bold) : .system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .strikethrough(cancelled)
                HStack(spacing: 4) {
                    if let scheduled, abs(scheduled.timeIntervalSince(date)) >= 60 {
                        Text(TimeText.clock(scheduled)).strikethrough().foregroundStyle(.tertiary)
                    }
                    Text(TimeText.clock(date))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .animation(.default, value: TimeText.countdown(to: date, from: context.date))
        }
    }
}
