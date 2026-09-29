import SwiftUI
import BusioKit

/// Itinéraire suivi : où l'on en est (GPS), correspondance menacée et plan B, étapes à jour.
struct FollowedJourneyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let followed = app.follower.followed, let journey = followed.journey {
                    content(followed, journey: journey)
                } else {
                    ContentUnavailableView("Aucun trajet suivi", systemImage: "platter.filled.bottom.iphone",
                                           description: Text("Choisis un itinéraire puis « Suivre ce trajet »."))
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(app.follower.followed?.title ?? "Trajet suivi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .refreshable { await app.follower.refreshNow() }
        }
    }

    private func content(_ followed: FollowedJourney, journey: PlannedJourney) -> some View {
        let context = JourneyContext(followed: followed, network: app.network)
        let steps = JourneyStep.list(for: journey, originName: followed.request.from.kind == .currentLocation ? "Départ" : followed.request.from.name,
                                     destinationName: followed.request.to.name, stopName: context.stopName)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                JourneyMap(journey: journey, origin: followed.request.from, destination: followed.request.to)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                StatusCard(followed: followed, journey: journey, context: context)

                if let issue = followed.issue {
                    IssueCard(issue: issue, journey: journey, planB: followed.planB, context: context)
                }

                LocationRow()

                JourneyStepsList(steps: steps, current: currentStep(in: steps, followed: followed, journey: journey))

                Button(role: .destructive) {
                    Task {
                        await app.follower.stop()
                        dismiss()
                    }
                } label: {
                    Label("Arrêter le suivi", systemImage: "stop.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    /// Étape du bus en cours (ou attendu).
    private func currentStep(in steps: [JourneyStep], followed: FollowedJourney, journey: PlannedJourney, now: Date = Date()) -> Int? {
        let rides = journey.rides
        let target: Int?
        switch followed.progress?.stage {
        case .onboard(let ride)?, .toStop(let ride)?: target = ride
        case .arrived?: return steps.count - 1
        case nil: target = rides.firstIndex { $0.arrival > now }
        }
        guard let target else { return journey.arrival < now ? steps.count - 1 : nil }
        var seen = 0
        for (index, step) in steps.enumerated() {
            if case .ride = step {
                if seen == target { return index }
                seen += 1
            }
        }
        return nil
    }
}

/// En-tête : bus attendu ou en cours, compte à rebours.
private struct StatusCard: View {
    let followed: FollowedJourney
    let journey: PlannedJourney
    let context: JourneyContext

    var body: some View {
        let status = currentStatus()
        HStack(alignment: .center, spacing: 12) {
            if let ride = status.ride, let style = context.style(ride.lineID) {
                Text(style.badge)
                    .font(.system(.title3, design: .rounded).weight(.heavy))
                    .foregroundStyle(style.onTint)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 44, minHeight: 36)
                    .background(style.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: "flag.checkered").font(.title2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title).font(.headline)
                Text(status.detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let target = status.target, target > Date() {
                Group {
                    // Au-delà d'une heure, un compte à rebours en minutes ne se lit plus.
                    if target.timeIntervalSinceNow > 3600 {
                        let day = TimeText.dayLabel(target)
                        Text(day == "aujourd'hui" ? "dans \(TimeText.duration(target.timeIntervalSinceNow))" : day)
                            .font(.system(.headline, design: .rounded))
                    } else {
                        Text(timerInterval: Date()...target, countsDown: true, showsHours: false)
                            .font(.system(.title2, design: .rounded).weight(.bold))
                    }
                }
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100, alignment: .trailing)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func currentStatus(now: Date = Date()) -> (title: String, detail: String, target: Date?, ride: RideLeg?) {
        let rides = journey.rides
        let tracked = followed.progress.flatMap { now.timeIntervalSince($0.updatedAt) < 10 * 60 ? $0 : nil }
        switch tracked?.stage {
        case .onboard(let index)? where rides.indices.contains(index):
            let ride = rides[index]
            let stop = context.stopName(ride.alight.stopID)
            let detail: String
            switch tracked?.stopsLeft {
            case 1?: detail = "Descends au prochain arrêt : \(stop)"
            case let n? where n > 1: detail = "Descente à \(stop) dans \(n) arrêts"
            default: detail = "Descente à \(stop) · \(TimeText.clock(ride.arrival))"
            }
            return ("Dans le \(context.badge(ride.lineID)) → \(ride.headsign)", detail, ride.arrival, ride)
        case .arrived?:
            return ("Arrivé", followed.request.to.name, nil, nil)
        default:
            let index: Int? = {
                if case .toStop(let ride)? = tracked?.stage { return ride }
                return rides.firstIndex { $0.arrival > now }
            }()
            guard let index, rides.indices.contains(index) else {
                return ("Arrivée \(TimeText.clock(journey.arrival))", followed.request.to.name, journey.arrival, nil)
            }
            let ride = rides[index]
            var detail = "Depuis \(context.stopName(ride.board.stopID)) → \(ride.headsign)"
            if ride.isCancelled {
                detail = "Supprimé · " + detail
            } else if let stops = ride.stopsAway {
                detail += stops == 0 ? " · le bus est à l'arrêt" : " · le bus est à \(stops) arrêt\(stops > 1 ? "s" : "")"
            }
            return ("\(context.badge(ride.lineID)) à \(TimeText.clock(ride.departure))", detail, ride.departure, ride)
        }
    }
}

/// Correspondance menacée ou bus supprimé, avec le plan B.
private struct IssueCard: View {
    @Environment(AppModel.self) private var app
    let issue: JourneyIssue
    let journey: PlannedJourney
    let planB: PlannedJourney?
    let context: JourneyContext
    @State private var switching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(context.issueTitle(issue, journey: journey), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(context.issueMessage(issue, journey: journey, planB: planB)).font(.subheadline)
            if let planB {
                HStack {
                    JourneyLegsView(journey: planB)
                    Spacer()
                    Text("\(TimeText.clock(planB.departure)) → \(TimeText.clock(planB.arrival))")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                Button {
                    switching = true
                    Task {
                        await app.follower.switchToPlanB()
                        switching = false
                    }
                } label: {
                    Label(issue.kind == .tightTransfer ? "Passer au plan B" : "Suivre le plan B", systemImage: "arrow.triangle.branch")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.orange)
                .disabled(switching)
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// État du GPS (alerte avant la descente).
private struct LocationRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if !app.location.isAuthorized {
                Button {
                    app.location.requestPermission()
                } label: {
                    Label("Autorise la localisation pour être prévenu avant ta descente", systemImage: "location.slash")
                }
                .disabled(!app.location.canAsk)
            } else if app.follower.isTrackingLocation {
                Label("GPS actif : Busio sait quand tu es dans le bus et te prévient avant ta descente.", systemImage: "location.fill")
                    .foregroundStyle(.green)
            } else {
                Label("GPS en pause : rappel de descente à l'heure prévue.", systemImage: "location")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 4)
    }
}

/// Rappel du trajet en cours, en haut de l'onglet Itinéraire.
struct FollowedJourneyBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let followed = app.follower.followed, let journey = followed.journey {
            let context = JourneyContext(followed: followed, network: app.network)
            Button {
                app.showFollowed = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: followed.issue == nil ? "location.fill.viewfinder" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(followed.issue == nil ? Color.accentColor : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(followed.issue.map { context.issueShort($0, journey: journey, planB: followed.planB) } ?? "Trajet en cours")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(followed.title) · arrivée \(TimeText.clock(journey.arrival))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        }
    }
}
