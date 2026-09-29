import SwiftUI
import BusioKit

/// « 🚶 6 › [3] › [10] › 🚶 3 »
struct JourneyLegsView: View {
    @Environment(AppModel.self) private var app
    let journey: PlannedJourney

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(journey.legs.enumerated()), id: \.offset) { index, leg in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                switch leg {
                case .walk(let walk):
                    HStack(spacing: 1) {
                        Image(systemName: "figure.walk")
                        Text("\(max(1, Int((walk.duration / 60).rounded())))")
                            .monospacedDigit()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                case .ride(let ride):
                    LineBadge(line: app.network?.line(ride.lineID), size: .small)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        journey.legs.map { leg in
            switch leg {
            case .walk(let walk): "\(TimeText.duration(walk.duration)) à pied"
            case .ride(let ride): app.network?.line(ride.lineID)?.displayName ?? "bus"
            }
        }.joined(separator: ", puis ")
    }
}

/// Résumé d'un itinéraire dans la liste des résultats.
struct JourneyCard: View {
    enum Highlight {
        case before(deadline: Date)
        case after(deadline: Date)
    }

    @Environment(AppModel.self) private var app
    let journey: PlannedJourney
    var highlight: Highlight?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let highlight { tag(highlight) }

            HStack(alignment: .firstTextBaseline) {
                Text("\(TimeText.clock(journey.departure)) → \(TimeText.clock(journey.arrival))")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .strikethrough(journey.isCancelled)
                Spacer()
                Text(TimeText.duration(journey.duration))
                    .font(.headline)
                    .monospacedDigit()
            }

            JourneyLegsView(journey: journey)

            HStack(spacing: 6) {
                if let ride = journey.firstRide {
                    QualityTag(quality: ride.quality, compact: true)
                    Text(boardingText(ride))
                        .lineLimit(1)
                    DelayTag(delay: ride.delay)
                } else {
                    Image(systemName: "figure.walk")
                    Text("\(Int(journey.walkDistance.rounded())) m à pied")
                }
                Spacer(minLength: 4)
                Text(transfersText).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.caption)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            if highlight != nil {
                RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.tint, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func boardingText(_ ride: RideLeg) -> String {
        let stop = app.network?.stop(ride.board.stopID)?.name ?? "arrêt"
        return "\(stop) · \(TimeText.clock(ride.departure))"
    }

    private var transfersText: String {
        guard !journey.isWalkOnly else { return "Sans bus" }
        let transfers = journey.transfers == 0 ? "Direct" : "\(journey.transfers) corresp."
        let wait = journey.transferWait >= 60 ? " · \(TimeText.duration(journey.transferWait)) d'attente" : ""
        return transfers + wait
    }

    @ViewBuilder
    private func tag(_ highlight: Highlight) -> some View {
        switch highlight {
        case .before(let deadline):
            let margin = deadline.timeIntervalSince(journey.arrival)
            Label(margin < 60 ? "Arrive pile à l'heure" : "Arrive \(TimeText.duration(margin)) avant", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
        case .after(let deadline):
            Label("Arrive \(TimeText.duration(journey.arrival.timeIntervalSince(deadline))) après", systemImage: "exclamationmark.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.orange)
        }
    }
}
