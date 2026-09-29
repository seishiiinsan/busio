import SwiftUI
import BusioKit

/// Onglet principal : le trajet domicile ↔ travail, sens choisi selon l'heure.
struct CommuteView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = CommuteModel(preferences: AppGroup.store.loadPreferences())
    @State private var activityError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if app.preferences.commute.isConfigured {
                        commuteContent
                    } else {
                        setupPrompt
                    }
                    FavoritesSection()
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(app.preferences.commute.isConfigured ? model.direction.title : "Busio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Réglages", systemImage: "gearshape") { app.showSettings = true }
                }
            }
            .refreshable { await model.refresh(app: app) }
            .task(id: RefreshKey(direction: model.direction, configured: app.preferences.commute)) {
                // Rafraîchit toutes les 15 s tant que l'écran est visible.
                while !Task.isCancelled {
                    await model.refresh(app: app)
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.syncDirection(with: app.preferences)
                    Task { await model.refresh(app: app) }
                }
            }
            .navigationDestination(for: StopArea.self) { StopBoardView(area: $0) }
            .navigationDestination(for: TripRoute.self) { TripDetailView(route: $0) }
            .alert("Live Activity indisponible", isPresented: Binding(get: { activityError != nil }, set: { if !$0 { activityError = nil } })) {
                Button("OK") { activityError = nil }
            } message: {
                Text(activityError ?? "")
            }
        }
    }

    private struct RefreshKey: Equatable {
        let direction: CommuteDirection
        let configured: CommuteSettings
    }

    // MARK: Contenu

    @ViewBuilder
    private var commuteContent: some View {
        Picker("Sens", selection: Binding(get: { model.direction }, set: { model.select($0) })) {
            Text("Aller").tag(CommuteDirection.toWork)
            Text("Retour").tag(CommuteDirection.toHome)
        }
        .pickerStyle(.segmented)
        .padding(.top, 4)

        RouteHeader(
            origin: app.preferences.commute.origin(for: model.direction)?.name ?? "–",
            destination: app.preferences.commute.destination(for: model.direction)?.name ?? "–",
            walk: model.walk,
            walkIsMeasured: model.walkIsMeasured
        )

        if let snapshot = model.snapshot {
            FeedStatusBanner(status: snapshot.status)
            if let journey = model.nextJourney {
                NextBusCard(journey: journey, snapshot: snapshot, line: app.network?.line(journey.lineID)) {
                    Task {
                        do { try await model.follow(journey) } catch { activityError = error.localizedDescription }
                    }
                }
            } else {
                ContentUnavailableView("Plus de bus direct", systemImage: "moon.zzz", description: Text("Aucun bus direct dans les prochaines heures entre ces deux arrêts."))
            }
            UpcomingJourneys(snapshot: snapshot, highlightID: model.nextJourney?.id) { journey in
                Task {
                    do { try await model.follow(journey) } catch { activityError = error.localizedDescription }
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.secondary)
            }
        } else if model.isLoading {
            ProgressView("Chargement des horaires…").frame(maxWidth: .infinity).padding(.vertical, 40)
        } else if let error = model.errorMessage {
            ContentUnavailableView("Horaires indisponibles", systemImage: "wifi.exclamationmark", description: Text(error))
        }
    }

    private var setupPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "bus.doubledecker.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.top, 32)
            Text("Ton trajet en un coup d'œil").font(.title2.bold())
            Text("Choisis ton arrêt près de chez toi et celui du travail : Busio affiche le bon bus selon l'heure, en temps réel.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Configurer mon trajet") { app.showOnboarding = true }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
    }
}

// MARK: - En-tête

private struct RouteHeader: View {
    let origin: String
    let destination: String
    let walk: TimeInterval?
    let walkIsMeasured: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(origin).font(.headline)
                Image(systemName: "arrow.right").font(.subheadline.weight(.bold)).foregroundStyle(.tint)
                Text(destination).font(.headline)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            if let walk {
                Label("\(TimeText.duration(walk)) à pied jusqu'à l'arrêt\(walkIsMeasured ? "" : " (estimé)")", systemImage: "figure.walk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Carte « prochain bus »

private struct NextBusCard: View {
    let journey: Journey
    let snapshot: CommuteSnapshot
    let line: Line?
    let follow: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let now = context.date
            let advice = LeaveAdvice(journey: journey, walk: snapshot.walk, buffer: snapshot.buffer)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    LineBadge(line: line, size: .large)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("→ \(journey.headsign)").font(.headline).lineLimit(1)
                        if journey.id == snapshot.recommendedID {
                            Text("Conseillé pour ton horaire").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    QualityTag(quality: journey.quality)
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(TimeText.countdown(to: journey.departureTime, from: now))
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .strikethrough(journey.isCancelled)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("départ \(TimeText.clock(journey.departureTime))").font(.subheadline.weight(.semibold))
                        DelayTag(delay: journey.delay)
                    }
                    Spacer(minLength: 0)
                }

                if journey.isCancelled {
                    Label("Course supprimée", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.subheadline.weight(.semibold))
                } else {
                    leaveRow(advice: advice, now: now)
                }

                Divider()

                HStack {
                    Label("Arrivée \(TimeText.clock(journey.arrivalTime))", systemImage: "flag.checkered")
                    Spacer()
                    Text("\(TimeText.duration(journey.duration)) · \(journey.stopCount) arrêts")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)

                if let stops = journey.stopsAway, journey.state == .running {
                    Label(stops == 0 ? "Le bus est à l'arrêt" : "Le bus est à \(stops) arrêt\(stops > 1 ? "s" : "")", systemImage: "bus.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }

                HStack(spacing: 10) {
                    Button(action: follow) {
                        Label("Suivre sur l'écran verrouillé", systemImage: "platter.filled.bottom.iphone")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    if let itinerary = journey.itineraryID {
                        NavigationLink(value: TripRoute(itineraryID: itinerary, tripID: journey.tripID, highlight: [journey.origin.stopID, journey.destination.stopID])) {
                            Image(systemName: "list.bullet")
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Détail de la course")
                    }
                }
                .controlSize(.large)
            }
            .padding(20)
            .glassEffect(.regular.tint((line?.tint ?? .accentColor).opacity(0.18)), in: .rect(cornerRadius: 28))
            .animation(.snappy, value: journey)
        }
    }

    @ViewBuilder
    private func leaveRow(advice: LeaveAdvice, now: Date) -> some View {
        let untilLeave = advice.leaveAt.timeIntervalSince(now)
        HStack(spacing: 8) {
            Image(systemName: "figure.walk.departure")
            if untilLeave > 60 {
                Text("Pars à **\(TimeText.clock(advice.leaveAt))** (dans \(TimeText.countdown(to: advice.leaveAt, from: now)))")
            } else if untilLeave > -60 {
                Text("**Pars maintenant**")
            } else {
                Text("Ça va être juste : \(TimeText.duration(snapshot.walk)) de marche")
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(untilLeave > 5 * 60 ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
    }
}

// MARK: - Liste des bus suivants

private struct UpcomingJourneys: View {
    @Environment(AppModel.self) private var app
    let snapshot: CommuteSnapshot
    let highlightID: String?
    let follow: (Journey) -> Void

    var body: some View {
        let journeys = snapshot.upcoming(at: Date()).filter { $0.id != highlightID }
        if !journeys.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ensuite").font(.title3.bold())
                VStack(spacing: 0) {
                    ForEach(journeys) { journey in
                        row(journey)
                        if journey.id != journeys.last?.id { Divider().padding(.leading, 56) }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private func row(_ journey: Journey) -> some View {
        HStack(spacing: 12) {
            LineBadge(line: app.network?.line(journey.lineID))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(TimeText.clock(journey.departureTime)).font(.body.weight(.semibold)).monospacedDigit()
                        .strikethrough(journey.isCancelled)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(TimeText.clock(journey.arrivalTime)).monospacedDigit().foregroundStyle(.secondary)
                    DelayTag(delay: journey.delay)
                }
                HStack(spacing: 6) {
                    QualityTag(quality: journey.quality, compact: true)
                    if journey.id == snapshot.recommendedID {
                        Text("Conseillé").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                    }
                    Text(journey.isCancelled ? "Supprimé" : "\(TimeText.duration(journey.duration)) de trajet")
                        .font(.caption).foregroundStyle(journey.isCancelled ? .red : .secondary)
                }
            }
            Spacer()
            DepartureClock(date: journey.departureTime, cancelled: journey.isCancelled, emphasize: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Suivre ce bus", systemImage: "platter.filled.bottom.iphone") { follow(journey) }
        }
    }
}
