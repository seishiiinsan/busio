import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import BusioKit

struct JourneyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JourneyActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        LineChip(state: context.state, size: 16)
                        if context.state.isLive {
                            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green).font(.caption)
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(state: context.state)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .frame(maxWidth: 110, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(PhaseText.headline(context.state)).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            if let leaveAt = context.state.leaveAt {
                                Text("Pars à \(TimeText.clock(leaveAt))").foregroundStyle(.orange)
                            }
                            if let next = context.state.nextStep { Text(next).foregroundStyle(.secondary) }
                            Text("Arrivée \(context.attributes.destinationName) \(TimeText.clock(context.state.arrival))").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .lineLimit(1)
                        Spacer()
                        Button(intent: RefreshTripActivityIntent()) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .font(.body.weight(.semibold))
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                LineChip(state: context.state, size: 12)
            } compactTrailing: {
                Countdown(state: context.state)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .frame(maxWidth: 52)
            } minimal: {
                LineChip(state: context.state, size: 10)
            }
            .keylineTint(Color(hex: context.state.lineColorHex))
        }
    }
}

enum PhaseText {
    static func headline(_ state: JourneyActivityAttributes.ContentState) -> String {
        switch state.phase {
        case .boarding: "\(state.lineBadge) à \(state.stopName) → \(state.headsign)"
        case .riding: "Descends à \(state.stopName)"
        case .arrived: "Arrivé"
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<JourneyActivityAttributes>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                LineChip(state: state, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(PhaseText.headline(state)).font(.headline).lineLimit(1)
                    Text(context.attributes.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if state.isCancelled {
                    Text("Supprimé").font(.headline).foregroundStyle(.red)
                } else {
                    Countdown(state: state)
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .frame(maxWidth: 120, alignment: .trailing)
                }
            }
            HStack(spacing: 10) {
                if let next = state.nextStep {
                    Label(next, systemImage: "arrow.turn.down.right").lineLimit(1)
                }
                if let delay = state.delayMinutes, delay != 0 {
                    Text(delay > 0 ? "+\(delay) min" : "\(delay) min")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(delay > 0 ? .red : .green)
                }
                Spacer()
                Text("Arrivée \(TimeText.clock(state.arrival))").foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack {
                if let leaveAt = state.leaveAt {
                    Label("Pars à \(TimeText.clock(leaveAt))", systemImage: "figure.walk").foregroundStyle(.orange)
                } else if let stops = state.stopsAway, state.isLive {
                    Label(stops <= 1 ? "Le bus arrive" : "Le bus est à \(stops) arrêts", systemImage: "bus.fill")
                } else {
                    Label(state.isLive ? "Suivi en direct" : "Horaire prévu", systemImage: state.isLive ? "dot.radiowaves.left.and.right" : "clock")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("MAJ \(TimeText.clock(state.updatedAt))").foregroundStyle(.tertiary)
                Button(intent: RefreshTripActivityIntent()) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            .font(.caption2)
        }
        .padding(16)
    }
}

private struct Countdown: View {
    let state: JourneyActivityAttributes.ContentState

    var body: some View {
        if state.target > Date() {
            Text(timerInterval: Date()...state.target, countsDown: true, showsHours: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            Text(state.phase == .riding ? "Arrêt" : "Départ").multilineTextAlignment(.trailing)
        }
    }
}

private struct LineChip: View {
    let state: JourneyActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        Text(state.lineBadge)
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(Color(hex: state.lineTextColorHex))
            .padding(.horizontal, size * 0.35)
            .frame(minWidth: size * 1.8, minHeight: size * 1.4)
            .background(Color(hex: state.lineColorHex), in: RoundedRectangle(cornerRadius: size * 0.35, style: .continuous))
    }
}

#if DEBUG
#Preview("Écran verrouillé", as: .content, using: PreviewData.activityAttributes) {
    JourneyLiveActivity()
} contentStates: {
    PreviewData.activityState
}

#Preview("Dynamic Island", as: .dynamicIsland(.expanded), using: PreviewData.activityAttributes) {
    JourneyLiveActivity()
} contentStates: {
    PreviewData.activityState
}
#endif
