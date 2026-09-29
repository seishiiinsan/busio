import SwiftUI
import UserNotifications
import BusioKit

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var editing: FavoriteDraft?
    @State private var pickingPlace: NamedPlace?

    enum NamedPlace: String, Identifiable {
        case home, work
        var id: String { rawValue }
        var title: String { self == .home ? "Maison" : "Travail" }
        var icon: String { self == .home ? "house.fill" : "briefcase.fill" }
    }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section {
                    ForEach(app.preferences.favoriteTrips) { favorite in
                        Button {
                            editing = FavoriteDraft(favorite)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(favorite.displayName).foregroundStyle(.primary)
                                if let minute = favorite.arriveByMinute {
                                    Text("Arrivée \(TimeText.clock(FavoriteTrip.date(minute: minute, on: Date())))\(favorite.leaveAlerts ? " · rappel" : "")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { app.preferences.favoriteTrips.remove(atOffsets: $0) }
                    .onMove { app.preferences.favoriteTrips.move(fromOffsets: $0, toOffset: $1) }
                    Button("Ajouter un trajet favori", systemImage: "plus") { editing = FavoriteDraft() }
                } header: {
                    Text("Trajets favoris")
                } footer: {
                    Text("Ils apparaissent sur l'accueil, dans les widgets et avec Siri. Le premier sert par défaut quand aucun n'a d'heure d'arrivée proche.")
                }

                Section {
                    placeRow(.home, place: app.preferences.home)
                    placeRow(.work, place: app.preferences.work)
                } header: {
                    Text("Lieux")
                } footer: {
                    Text("Pour chercher « demain 9h au boulot » ou « à la maison » dans l'onglet Itinéraire.")
                }

                Section {
                    Picker("Préférence", selection: $app.preferences.routing.preference) {
                        ForEach(RoutingOptions.Preference.allCases) { Text($0.title).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("Marche max jusqu'à un arrêt : \(Int(app.preferences.routing.maxWalkDistance)) m")
                        Slider(value: $app.preferences.routing.maxWalkDistance, in: 300...2_000, step: 100)
                    }
                    Stepper("Marge de correspondance : \(Int(app.preferences.routing.minTransferTime / 60)) min",
                            value: Binding(get: { Int(app.preferences.routing.minTransferTime / 60) },
                                           set: { app.preferences.routing.minTransferTime = TimeInterval($0 * 60) }),
                            in: 0...10)
                    Picker("Allure de marche", selection: $app.preferences.routing.walkSpeed) {
                        Text("Tranquille").tag(1.0)
                        Text("Normale").tag(1.25)
                        Text("Rapide").tag(1.5)
                    }
                    Stepper("Correspondances max : \(app.preferences.routing.maxTransfers)", value: $app.preferences.routing.maxTransfers, in: 0...4)
                } header: {
                    Text("Calcul d'itinéraire")
                } footer: {
                    Text("La marge laisse le temps de descendre d'un bus et de rejoindre l'autre quai.")
                }

                Section {
                    Toggle("Rappels « pars maintenant »", isOn: $app.preferences.leaveNowAlerts)
                    Toggle("Retards et suppressions", isOn: $app.preferences.delayAlerts)
                    Toggle("Correspondance menacée (plan B)", isOn: $app.preferences.transferAlerts)
                    Toggle("Avant la descente", isOn: $app.preferences.alightAlerts)
                    if app.preferences.delayAlerts {
                        Stepper("Alerter dès \(app.preferences.delayThresholdMinutes) min de retard", value: $app.preferences.delayThresholdMinutes, in: 1...15)
                    }
                    if notificationStatus != .authorized {
                        Button("Autoriser les notifications") {
                            Task {
                                _ = await JourneyAlerts.requestAuthorization()
                                await refreshNotificationStatus()
                            }
                        }
                    }
                } header: {
                    Text("Alertes")
                } footer: {
                    Text("Itinéraire suivi : Busio vérifie le temps réel toutes les 45 s, propose un plan B si une correspondance saute et, avec le GPS, te prévient au moment de descendre (sinon à l'heure prévue). Trajets favoris : rappels si une heure d'arrivée et l'option « rappel » sont définies.")
                }

                Section("Automatisation conseillée") {
                    AutomationGuide()
                }

                Section("Données") {
                    NavigationLink("État des sources") { DiagnosticsView() }
                    Link(destination: URL(string: "https://zenbus.net/publicapp/web/castres")!) {
                        Label("Ouvrir Zenbus (comparer)", systemImage: "safari")
                    }
                }

                Section {
                    Button("Revoir l'accueil") {
                        dismiss()
                        app.showOnboarding = true
                    }
                } footer: {
                    Text("Données : Zenbus (temps réel) et Communauté d'agglomération de Castres-Mazamet — GTFS Libellus, licence ODbL via transport.data.gouv.fr. Adresses : Plans. Busio n'est pas une application officielle.")
                }
            }
            .navigationTitle("Réglages")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .sheet(item: $editing) { FavoriteTripEditor(draft: $0) }
            .sheet(item: $pickingPlace) { kind in
                PlaceSearchView(title: kind.title, allowsCurrentLocation: false) { place in
                    guard let place else { return }
                    if kind == .home { app.preferences.home = place } else { app.preferences.work = place }
                }
            }
            .task { await refreshNotificationStatus() }
        }
    }

    private func placeRow(_ kind: NamedPlace, place: Place?) -> some View {
        Button {
            pickingPlace = kind
        } label: {
            LabeledContent {
                Text(place?.name ?? "Choisir").foregroundStyle(place == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            } label: {
                Label(kind.title, systemImage: kind.icon).foregroundStyle(.primary)
            }
        }
        .swipeActions {
            if place != nil {
                Button("Retirer", role: .destructive) {
                    if kind == .home { app.preferences.home = nil } else { app.preferences.work = nil }
                }
            }
        }
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// Sélection d'une heure (stockée en minutes depuis minuit).
struct MinutePicker: View {
    let title: String
    @Binding var minute: Int

    var body: some View {
        DatePicker(title, selection: Binding(
            get: { FavoriteTrip.date(minute: minute, on: Date()) },
            set: {
                let c = TransitClock.calendar.dateComponents([.hour, .minute], from: $0)
                minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        ), displayedComponents: .hourAndMinute)
        .environment(\.timeZone, TransitClock.timeZone)
    }
}

struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    /// Weekday `Calendar` (1 = dimanche) et initiale, du lundi au dimanche.
    private let days = [2, 3, 4, 5, 6, 7, 1]
    private let letters = ["L", "M", "M", "J", "V", "S", "D"]

    var body: some View {
        HStack {
            Text("Jours")
            Spacer()
            ForEach(0..<7, id: \.self) { position in
                let day = days[position]
                let isOn = selection.contains(day)
                Button {
                    if isOn { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(letters[position])
                        .font(.footnote.weight(.bold))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(isOn ? Color.white : .primary)
                        .background(isOn ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Explique comment lancer la Live Activity chaque matin via Raccourcis.
struct AutomationGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ouvre **Raccourcis** › Automatisation › **+**", systemImage: "1.circle.fill")
            Label("Choisis **Heure de la journée**, par ex. 8:15, du lundi au vendredi, puis **Exécuter immédiatement**", systemImage: "2.circle.fill")
            Label("Ajoute l'action Busio **Suivre mon trajet** et choisis ton trajet favori", systemImage: "3.circle.fill")
            Text("Le compte à rebours apparaît alors tout seul sur l'écran verrouillé, avec les correspondances et un bouton pour l'actualiser.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }
}
