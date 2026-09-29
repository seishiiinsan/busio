import SwiftUI
import BusioKit

/// Premier lancement : domicile, travail, autorisations.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.welcome
    @State private var home: StopArea?
    @State private var work: StopArea?

    enum Step: Int, CaseIterable {
        case welcome, home, work, permissions
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ProgressView(value: Double(step.rawValue), total: Double(Step.allCases.count - 1))
                    .tint(.accentColor)
                    .padding(.horizontal)

                switch step {
                case .welcome: welcome
                case .home: picker(title: "Ton arrêt près de chez toi", subtitle: "Celui où tu prends le bus pour aller au travail.", selection: $home)
                case .work: picker(title: "Ton arrêt au travail", subtitle: "Celui où tu descends le matin et reprends le bus le soir.", selection: $work)
                case .permissions: permissions
                }
            }
            .padding(.vertical)
            .toolbar {
                if step != .welcome {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Retour", systemImage: "chevron.left") {
                            withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Plus tard") { finish() }
                }
            }
        }
        .onAppear {
            if let network = app.network {
                home = app.preferences.commute.home?.resolve(in: network)
                work = app.preferences.commute.work?.resolve(in: network)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bus.doubledecker.fill")
                .font(.system(size: 80))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, options: .nonRepeating)
            Text("Bienvenue dans Busio").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 14) {
                Feature(icon: "dot.radiowaves.left.and.right", title: "Temps réel Zenbus", text: "Les mêmes données que l'app officielle, en plus lisible.")
                Feature(icon: "arrow.left.arrow.right", title: "Ton trajet d'abord", text: "L'aller le matin, le retour l'après-midi, sans rien toucher.")
                Feature(icon: "calendar.badge.checkmark", title: "Jamais sans horaire", text: "Si le temps réel tombe, Busio bascule sur les horaires officiels et te le dit.")
            }
            .padding(.horizontal, 28)
            Spacer()
            Button {
                withAnimation { step = .home }
            } label: {
                Text("Commencer").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal)
        }
    }

    private func picker(title: String, subtitle: String, selection: Binding<StopArea?>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            OnboardingStopList(selection: selection)
            Button {
                withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .permissions }
            } label: {
                Text(selection.wrappedValue.map { "Continuer avec \($0.name)" } ?? "Choisis un arrêt").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(selection.wrappedValue == nil)
            .padding(.horizontal)
        }
    }

    private var permissions: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bell.badge.fill").font(.system(size: 60)).foregroundStyle(.tint)
            Text("Ne rate plus ton bus").font(.title.bold())
            Text("Busio te prévient quand partir (temps de marche compris) et si ton bus a du retard.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            VStack(spacing: 12) {
                Button {
                    app.location.requestPermission()
                } label: {
                    Label(app.location.isAuthorized ? "Localisation activée" : "Activer la localisation", systemImage: app.location.isAuthorized ? "checkmark.circle.fill" : "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(!app.location.canAsk)
                Button {
                    Task { _ = await CommuteAlerts.requestAuthorization() }
                } label: {
                    Label("Activer les notifications", systemImage: "bell.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .padding(.horizontal)
            Spacer()
            Button {
                finish()
            } label: {
                Text("C'est parti").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal)
        }
    }

    private func finish() {
        if let home { app.preferences.commute.home = PlaceRef(home) }
        if let work { app.preferences.commute.work = PlaceRef(work) }
        app.preferences.hasCompletedOnboarding = true
        dismiss()
        app.showOnboarding = false
    }
}

private struct Feature: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct OnboardingStopList: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: StopArea?
    @State private var query = ""
    @State private var nearby: [NearbyArea] = []

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Nom de l'arrêt", text: $query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                if !app.location.isAuthorized {
                    Button("Autour de moi", systemImage: "location") { app.location.requestPermission() }
                        .labelStyle(.iconOnly)
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal)

            List {
                if let network = app.network {
                    if query.isEmpty, !nearby.isEmpty {
                        Section("À proximité") {
                            ForEach(nearby) { item in row(item.area, network: network) }
                        }
                    }
                    Section {
                        ForEach(network.searchAreas(query)) { area in row(area, network: network) }
                    }
                } else {
                    ProgressView()
                }
            }
            .listStyle(.plain)
        }
        .task(id: app.location.isAuthorized) {
            guard let network = app.network, let here = await app.location.currentCoordinate() else { return }
            nearby = network.nearestAreas(to: here, limit: 4).map { NearbyArea(area: $0.area, distance: $0.distance) }
        }
    }

    private func row(_ area: StopArea, network: Network) -> some View {
        Button {
            selection = area
        } label: {
            HStack {
                AreaRow(area: area, network: network)
                Spacer()
                if selection?.id == area.id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).font(.title3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
