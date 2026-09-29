import SwiftUI
import UserNotifications
import BusioKit

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        StopPickerView(title: "Arrêt domicile", selected: app.preferences.commute.home) {
                            app.preferences.commute.home = PlaceRef($0)
                        }
                    } label: {
                        LabeledContent("Domicile", value: app.preferences.commute.home?.name ?? "Choisir")
                    }
                    NavigationLink {
                        StopPickerView(title: "Arrêt travail", selected: app.preferences.commute.work) {
                            app.preferences.commute.work = PlaceRef($0)
                        }
                    } label: {
                        LabeledContent("Travail", value: app.preferences.commute.work?.name ?? "Choisir")
                    }
                } header: {
                    Text("Mon trajet")
                } footer: {
                    Text("Choisis l'arrêt où tu montes près de chez toi et celui du travail. Busio propose l'aller le matin et le retour l'après-midi.")
                }

                Section {
                    MinutePicker(title: "Arriver au travail avant", minute: $app.preferences.commute.arriveByMinute)
                    MinutePicker(title: "Sortie du travail", minute: $app.preferences.commute.leaveWorkMinute)
                    MinutePicker(title: "Bascule aller → retour", minute: $app.preferences.commute.switchMinute)
                    WeekdayPicker(selection: $app.preferences.commute.workdays)
                } header: {
                    Text("Horaires")
                } footer: {
                    Text("Le bus « conseillé » est le dernier qui te dépose à l'heure le matin, et le premier après ta sortie le soir.")
                }

                Section {
                    Stepper("Marge : \(app.preferences.commute.bufferMinutes) min", value: $app.preferences.commute.bufferMinutes, in: 0...10)
                    Stepper("Maison → arrêt : \(app.preferences.commute.walkToHomeStopMinutes) min", value: $app.preferences.commute.walkToHomeStopMinutes, in: 0...30)
                    Stepper("Arrêt → travail : \(app.preferences.commute.walkToWorkStopMinutes) min", value: $app.preferences.commute.walkToWorkStopMinutes, in: 0...30)
                } header: {
                    Text("Marche")
                } footer: {
                    Text("Quand ta position est disponible, Busio calcule le temps de marche réel avec Plans. Ces valeurs servent sinon.")
                }

                Section {
                    Toggle("Rappel « pars maintenant »", isOn: $app.preferences.leaveNowAlerts)
                    Toggle("Retards et suppressions", isOn: $app.preferences.delayAlerts)
                    if app.preferences.delayAlerts {
                        Stepper("Alerter dès \(app.preferences.delayThresholdMinutes) min de retard", value: $app.preferences.delayThresholdMinutes, in: 1...15)
                    }
                    Toggle("Live Activity automatique", isOn: $app.preferences.autoLiveActivity)
                    if notificationStatus != .authorized {
                        Button("Autoriser les notifications") {
                            Task {
                                _ = await CommuteAlerts.requestAuthorization()
                                await refreshNotificationStatus()
                            }
                        }
                    }
                } header: {
                    Text("Alertes")
                } footer: {
                    Text("Sans serveur push, iOS réveille Busio quand il le juge bon. Pour un suivi garanti chaque matin, crée l'automatisation ci-dessous.")
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
                    Text("Données : Zenbus (temps réel) et Communauté d'agglomération de Castres-Mazamet — GTFS Libellus, licence ODbL via transport.data.gouv.fr. Busio n'est pas une application officielle.")
                }
            }
            .navigationTitle("Réglages")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .task { await refreshNotificationStatus() }
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
            get: { CommuteSettings.date(minute: minute, on: Date()) },
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
    private let days: [(Int, String)] = [(2, "L"), (3, "M"), (4, "M"), (5, "J"), (6, "V"), (7, "S"), (1, "D")]

    var body: some View {
        HStack {
            Text("Jours")
            Spacer()
            ForEach(days, id: \.0) { day, letter in
                let isOn = selection.contains(day)
                Button {
                    if isOn { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(letter)
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
            Label("Choisis **Heure de la journée**, par ex. 8:30, du lundi au vendredi, puis **Exécuter immédiatement**", systemImage: "2.circle.fill")
            Label("Ajoute l'action Busio **Suivre mon bus**", systemImage: "3.circle.fill")
            Text("Le compte à rebours apparaît alors tout seul sur l'écran verrouillé, avec un bouton pour l'actualiser.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }
}
