import SwiftUI
import BusioKit

/// État détaillé des sources de données, pour vérifier la fiabilité.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app
    @State private var diagnostics: TransitService.Diagnostics?
    @State private var refreshing = false

    var body: some View {
        List {
            if let d = diagnostics {
                Section {
                    LabeledContent("Dernier relevé", value: d.lastLiveSuccess.map { Self.dateTime($0) } ?? "aucun")
                    if let error = d.lastLiveError {
                        LabeledContent("Dernière erreur", value: error)
                    }
                    let today = ServiceDay(containing: Date())
                    LabeledContent("Grille publiée", value: d.zenbusDays.isEmpty ? "–" : d.zenbusDays.map(Self.day).joined(separator: ", "))
                    if !d.zenbusDays.isEmpty && !d.zenbusDays.contains(today) {
                        Label("Zenbus n'a pas encore publié la grille d'aujourd'hui : Busio affiche les horaires théoriques.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Temps réel Zenbus")
                }

                Section("Réseau") {
                    LabeledContent("Lignes", value: "\(d.lineCount)")
                    LabeledContent("Arrêts", value: "\(d.stopCount)")
                    LabeledContent("Données du", value: d.networkDay.map(Self.day) ?? "–")
                    LabeledContent("Téléchargées", value: d.staticFileDate.map { Self.dateTime($0) } ?? "embarquées")
                }

                Section {
                    LabeledContent("Courses", value: "\(d.gtfsTripCount)")
                    LabeledContent("Validité", value: "\(d.gtfs?.startDay.map(Self.day) ?? "?") → \(d.gtfs?.endDay.map(Self.day) ?? "?")")
                    LabeledContent("Fichier", value: d.gtfsFileDate.map { Self.dateTime($0) } ?? "–")
                    if let error = d.gtfsError {
                        LabeledContent("Erreur", value: error)
                    }
                } header: {
                    Text("Horaires théoriques (GTFS)")
                } footer: {
                    Text("Utilisés quand Zenbus ne répond pas ou n'a pas publié la grille du jour. Ils sont produits par Zenbus et correspondent à la grille exploitée.")
                }
            } else {
                ProgressView()
            }

            Section {
                Button {
                    Task {
                        refreshing = true
                        await app.forceRefreshData()
                        diagnostics = await app.service.diagnostics()
                        refreshing = false
                    }
                } label: {
                    HStack {
                        Label("Retélécharger les données", systemImage: "arrow.clockwise")
                        Spacer()
                        if refreshing { ProgressView() }
                    }
                }
                .disabled(refreshing)
            }
        }
        .navigationTitle("Sources")
        .task { diagnostics = await app.service.diagnostics() }
    }

    static func day(_ day: ServiceDay) -> String {
        day.referenceDate.addingTimeInterval(12 * 3600).formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "fr_FR")))
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "fr_FR")))
    }
}
