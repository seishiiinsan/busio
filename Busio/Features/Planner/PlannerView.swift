import SwiftUI
import BusioKit

/// Onglet principal : d'où, où, quand → par où passer.
struct PlannerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = PlannerModel()
    @State private var picking: Field?
    @State private var editingFavorite: FavoriteDraft?
    @State private var path = NavigationPath()

    enum Field: String, Identifiable {
        case from, to
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if app.follower.followed?.journey != nil {
                        FollowedJourneyBanner()
                    }
                    PhraseField(model: model)
                    SearchForm(model: model, picking: $picking)
                    if model.hasQuery {
                        resultsSection
                    } else {
                        FavoriteTripsSection(onSelect: select, onEdit: { editingFavorite = FavoriteDraft($0) }, onAdd: {
                            editingFavorite = FavoriteDraft()
                        })
                        RecentDestinations { place in
                            model.to = place
                            model.favoriteID = nil
                        }
                        FavoritesSection()
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Itinéraire")
            .toolbar {
                if model.hasQuery {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Effacer", systemImage: "xmark") {
                            withAnimation(.snappy) { model.clear() }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Réglages", systemImage: "gearshape") { app.showSettings = true }
                }
            }
            .refreshable { await model.search(app: app) }
            // Nouvelle recherche dès que le formulaire change, puis actualisation régulière.
            .task(id: SearchKey(model: model)) {
                guard model.hasQuery else { return }
                await model.search(app: app)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(model.timeMode == .now ? 30 : 90))
                    guard !Task.isCancelled else { break }
                    await model.search(app: app, silently: true)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, model.hasQuery { Task { await model.search(app: app, silently: true) } }
            }
            .onChange(of: app.pendingFavoriteID) { _, id in consumePendingFavorite(id) }
            .onChange(of: model.result?.journeys.first?.id) { _, _ in
                #if DEBUG
                if app.demoScreen == "detail", let first = model.result?.journeys.first {
                    app.demoScreen = nil
                    path.append(JourneyRoute(journeyID: first.id, journey: first))
                }
                if app.demoScreen == "followed", let result = model.result,
                   let journey = result.journeys.first(where: { $0.transfers > 0 }) ?? result.journeys.first {
                    app.demoScreen = nil
                    Task {
                        try? await app.follow(journey, request: result.request, title: model.title)
                        await app.follower.simulateMissedTransfer()
                        app.showFollowed = true
                    }
                }
                #endif
            }
            .onAppear {
                consumePendingFavorite(app.pendingFavoriteID)
                #if DEBUG
                if app.demoScreen == "phrase" {
                    app.demoScreen = nil
                    model.phrase = "demain 9h au boulot"
                    Task { await model.interpret(app: app) }
                }
                #endif
            }
            .sheet(item: $picking) { field in
                PlaceSearchView(title: field == .from ? "Départ" : "Arrivée", allowsCurrentLocation: field == .from) { place in
                    if field == .from { model.from = place } else { model.to = place }
                    model.favoriteID = nil
                }
            }
            .sheet(item: $editingFavorite) { draft in
                FavoriteTripEditor(draft: draft)
            }
            .navigationDestination(for: JourneyRoute.self) { route in
                JourneyDetailView(route: route, model: model)
            }
            .navigationDestination(for: StopArea.self) { StopBoardView(area: $0) }
            .navigationDestination(for: TripRoute.self) { TripDetailView(route: $0) }
        }
    }

    private struct SearchKey: Equatable {
        let from: String?, to: String?, mode: PlannerModel.TimeMode, date: Date, preference: RoutingOptions.Preference

        @MainActor init(model: PlannerModel) {
            from = model.from?.id
            to = model.to?.id
            mode = model.timeMode
            date = model.timeMode == .now ? .distantPast : model.date
            preference = model.preference
        }
    }

    private func select(_ favorite: FavoriteTrip) {
        withAnimation(.snappy) { model.apply(favorite) }
    }

    private func consumePendingFavorite(_ id: UUID?) {
        guard let id, let favorite = app.preferences.favoriteTrips.first(where: { $0.id == id }) else { return }
        app.pendingFavoriteID = nil
        path = NavigationPath()
        select(favorite)
    }

    // MARK: Résultats

    @ViewBuilder
    private var resultsSection: some View {
        if let result = model.result {
            FeedStatusBanner(status: result.status)
            if !result.alerts.isEmpty {
                VStack(alignment: .leading) { AlertsList(alerts: result.alerts, network: app.network) }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if result.journeys.isEmpty {
                ContentUnavailableView("Aucun itinéraire", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                       description: Text("Pas de bus dans les prochaines heures, ou aucun arrêt à moins de \(Int(app.preferences.routing.maxWalkDistance)) m. Tu peux augmenter la marche maximale dans les réglages."))
            } else if case .arriveBy(let deadline) = result.request.time {
                Text("Au plus proche de \(TimeText.clock(deadline))").font(.title3.bold())
                ForEach(result.journeys) { journey in
                    if journey.id == result.closestBeforeID {
                        card(journey, highlight: .before(deadline: deadline))
                    } else if journey.id == result.closestAfterID {
                        card(journey, highlight: .after(deadline: deadline))
                    } else {
                        card(journey, highlight: nil)
                    }
                }
            } else {
                ForEach(result.journeys) { journey in card(journey, highlight: nil) }
            }
            saveFavoriteButton
        } else if model.isSearching {
            ProgressView("Calcul de l'itinéraire…").frame(maxWidth: .infinity).padding(.vertical, 32)
        }
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func card(_ journey: PlannedJourney, highlight: JourneyCard.Highlight?) -> some View {
        NavigationLink(value: JourneyRoute(journeyID: journey.id, journey: journey)) {
            JourneyCard(journey: journey, highlight: highlight)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var saveFavoriteButton: some View {
        if let to = model.to, model.favoriteID == nil {
            let exists = app.preferences.favoriteTrips.contains { $0.to.id == to.id && $0.from.id == (model.from?.id ?? "here") }
            if !exists {
                Button {
                    var arriveBy: Int?
                    if model.timeMode == .arriveBy {
                        let c = TransitClock.calendar.dateComponents([.hour, .minute], from: model.date)
                        arriveBy = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                    }
                    editingFavorite = FavoriteDraft(from: model.from, to: to, arriveByMinute: arriveBy)
                } label: {
                    Label("Ajouter aux trajets favoris", systemImage: "star")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
    }
}

struct JourneyRoute: Hashable {
    let journeyID: String
    let journey: PlannedJourney
}

// MARK: - Formulaire

/// « Demain 9h au boulot » : remplit le formulaire (dictée comprise, via le clavier).
private struct PhraseField: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: PlannerModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: SmartQueryParser.isAvailable ? "sparkles" : "text.bubble")
                    .foregroundStyle(.tint)
                TextField("Demain 9h au boulot, gare de Mazamet avant 8h30…", text: $model.phrase)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await model.interpret(app: app) } }
                if model.isInterpreting {
                    ProgressView()
                } else if !model.phrase.isEmpty {
                    Button("Effacer", systemImage: "xmark.circle.fill") { model.phrase = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: .capsule)

            if let interpretation = model.interpretation {
                Label(interpretation.text, systemImage: interpretation.isProblem ? "exclamationmark.bubble" : (interpretation.usedModel ? "sparkles" : "checkmark.bubble"))
                    .font(.caption)
                    .foregroundStyle(interpretation.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 8)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: model.interpretation?.text)
    }
}

private struct SearchForm: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: PlannerModel
    @Binding var picking: PlannerView.Field?

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                row(icon: "location.circle.fill", tint: .blue, label: "Départ",
                    value: model.from?.name ?? "Ma position", isPlaceholder: false) { picking = .from }
                Divider().padding(.leading, 52)
                row(icon: "mappin.circle.fill", tint: .red, label: "Arrivée",
                    value: model.to?.name ?? "Où vas-tu ?", isPlaceholder: model.to == nil) { picking = .to }
            }
            .overlay(alignment: .trailing) {
                Button {
                    withAnimation(.snappy) { model.swap() }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(.trailing, 10)
                .disabled(model.to == nil)
                .accessibilityLabel("Inverser départ et arrivée")
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 24))

            HStack(spacing: 8) {
                Menu {
                    Picker("Heure", selection: $model.timeMode) {
                        ForEach(PlannerModel.TimeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    Label(timeLabel, systemImage: "clock")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.glass)

                Menu {
                    Picker("Préférence", selection: $model.preference) {
                        ForEach(RoutingOptions.Preference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                } label: {
                    Label(model.preference.title, systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.glass)
                Spacer(minLength: 0)
            }

            if model.timeMode != .now {
                DatePicker(model.timeMode.title, selection: $model.date, in: Date().addingTimeInterval(-3600)..., displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, TransitClock.timeZone)
                    .font(.subheadline)
                    .padding(.horizontal, 4)
            }
        }
        .onChange(of: model.timeMode) { _, mode in
            // Heure par défaut : maintenant arrondi au quart d'heure suivant.
            if mode != .now, model.date < Date() {
                let minutes = TransitClock.calendar.component(.minute, from: Date())
                model.date = Date().addingTimeInterval(TimeInterval(((15 - minutes % 15) % 15) * 60))
            }
        }
    }

    private var timeLabel: String {
        switch model.timeMode {
        case .now: "Maintenant"
        case .departAt: "Départ \(TimeText.clock(model.date))"
        case .arriveBy: "Arrivée \(TimeText.clock(model.date))"
        }
    }

    private func row(icon: String, tint: Color, label: String, value: String, isPlaceholder: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Text(value)
                        .font(.body.weight(isPlaceholder ? .regular : .semibold))
                        .foregroundStyle(isPlaceholder ? .secondary : .primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 56)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Accueil (formulaire vide)

private struct FavoriteTripsSection: View {
    @Environment(AppModel.self) private var app
    let onSelect: (FavoriteTrip) -> Void
    let onEdit: (FavoriteTrip) -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Trajets favoris").font(.title3.bold())
                Spacer()
                Button("Ajouter", systemImage: "plus", action: onAdd)
                    .labelStyle(.iconOnly)
            }
            if app.preferences.favoriteTrips.isEmpty {
                Text("Enregistre un trajet (ex. Archipel → Gares Mazamet, arrivée 9:00) pour le retrouver ici en un geste, dans les widgets et avec Siri.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(app.preferences.favoriteTrips) { favorite in
                FavoriteTripCard(favorite: favorite)
                    .onTapGesture { onSelect(favorite) }
                    .contextMenu {
                        Button("Modifier", systemImage: "pencil") { onEdit(favorite) }
                        Button("Supprimer", systemImage: "trash", role: .destructive) {
                            app.preferences.favoriteTrips.removeAll { $0.id == favorite.id }
                        }
                    }
            }
        }
    }
}

/// Favori avec le prochain départ calculé en direct.
private struct FavoriteTripCard: View {
    @Environment(AppModel.self) private var app
    let favorite: FavoriteTrip
    @State private var snapshot: TripSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                Text(favorite.displayName).font(.headline).lineLimit(1)
                Spacer()
                if let minute = favorite.arriveByMinute {
                    Text("arrivée \(TimeText.clock(FavoriteTrip.date(minute: minute, on: Date())))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let journey = snapshot?.next(at: Date()) {
                HStack(spacing: 10) {
                    JourneyLegsView(journey: journey)
                    Spacer()
                    Text("\(TimeText.clock(journey.departure)) → \(TimeText.clock(journey.arrival))")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    QualityTag(quality: journey.quality, compact: true)
                }
            } else if snapshot != nil {
                Text("Pas d'itinéraire dans les prochaines heures").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: favorite) {
            snapshot = AppGroup.store.loadSnapshot(favoriteID: favorite.id)
            while !Task.isCancelled {
                if let fresh = try? await TripRefresher.refresh(favorite: favorite, reloadWidgets: true) { snapshot = fresh }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

private struct RecentDestinations: View {
    @Environment(AppModel.self) private var app
    let onSelect: (Place) -> Void

    var body: some View {
        let recents = Array(app.preferences.recentPlaces.prefix(6))
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Récents").font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recents) { place in
                            Button {
                                onSelect(place)
                            } label: {
                                Label(place.name, systemImage: place.kind == .stop ? "bus.fill" : "mappin")
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }
}
