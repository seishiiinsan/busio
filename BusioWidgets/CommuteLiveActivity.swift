import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import BusioKit

struct CommuteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CommuteActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        LineChip(attributes: context.attributes, size: 16)
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
                    Text("→ \(context.attributes.headsign)").font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(context.attributes.originName) · \(TimeText.clock(context.state.departure))")
                            if let leaveAt = context.state.leaveAt {
                                Text("Pars à \(TimeText.clock(leaveAt))").foregroundStyle(.orange)
                            } else {
                                Text("Arrivée \(context.attributes.destinationName) \(TimeText.clock(context.state.arrival))").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        Spacer()
                        Button(intent: RefreshCommuteActivityIntent()) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .font(.body.weight(.semibold))
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                LineChip(attributes: context.attributes, size: 12)
            } compactTrailing: {
                Countdown(state: context.state)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .frame(maxWidth: 52)
            } minimal: {
                LineChip(attributes: context.attributes, size: 10)
            }
            .keylineTint(Color(hex: context.attributes.lineColorHex))
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<CommuteActivityAttributes>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                LineChip(attributes: context.attributes, size: 16)
                Text("→ \(context.attributes.headsign)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if state.isCancelled {
                    Text("Supprimé").font(.headline).foregroundStyle(.red)
                } else {
                    Countdown(state: state)
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .frame(maxWidth: 130, alignment: .trailing)
                }
            }
            HStack(spacing: 12) {
                Label {
                    Text("\(context.attributes.originName) \(TimeText.clock(state.departure))")
                } icon: {
                    Image(systemName: "figure.walk")
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
                    Label("Pars à \(TimeText.clock(leaveAt))", systemImage: "bell.fill").foregroundStyle(.orange)
                } else if let stops = state.stopsAway, state.isLive {
                    Label(stops <= 1 ? "Le bus arrive" : "Le bus est à \(stops) arrêts", systemImage: "bus.fill")
                } else {
                    Label(state.isLive ? "Suivi en direct" : "Horaire prévu", systemImage: state.isLive ? "dot.radiowaves.left.and.right" : "clock")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("MAJ \(TimeText.clock(state.updatedAt))").foregroundStyle(.tertiary)
                Button(intent: RefreshCommuteActivityIntent()) {
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
    let state: CommuteActivityAttributes.ContentState

    var body: some View {
        if state.departure > Date() {
            Text(timerInterval: Date()...state.departure, countsDown: true, showsHours: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            Text("Départ").multilineTextAlignment(.trailing)
        }
    }
}

private struct LineChip: View {
    let attributes: CommuteActivityAttributes
    let size: CGFloat

    var body: some View {
        Text(attributes.lineBadge)
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(Color(hex: attributes.lineTextColorHex))
            .padding(.horizontal, size * 0.35)
            .frame(minWidth: size * 1.8, minHeight: size * 1.4)
            .background(Color(hex: attributes.lineColorHex), in: RoundedRectangle(cornerRadius: size * 0.35, style: .continuous))
    }
}

#if DEBUG
#Preview("Écran verrouillé", as: .content, using: PreviewData.activityAttributes) {
    CommuteLiveActivity()
} contentStates: {
    PreviewData.activityState
}

#Preview("Dynamic Island", as: .dynamicIsland(.expanded), using: PreviewData.activityAttributes) {
    CommuteLiveActivity()
} contentStates: {
    PreviewData.activityState
}

#Preview("Compact", as: .dynamicIsland(.compact), using: PreviewData.activityAttributes) {
    CommuteLiveActivity()
} contentStates: {
    PreviewData.activityState
}
#endif
