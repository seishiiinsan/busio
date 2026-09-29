import SwiftUI
import BusioKit

/// Brouillon d'un trajet favori (nouveau ou existant).
struct FavoriteDraft: Identifiable {
    let id = UUID()
    var existingID: UUID?
    var name = ""
    var from: Place?
    var to: Place?
    var arriveByMinute: Int?
    var days: Set<Int> = [2, 3, 4, 5, 6]
    var leaveAlerts = false

    init(from: Place? = nil, to: Place? = nil, arriveByMinute: Int? = nil) {
        self.from = from
        self.to = to
        self.arriveByMinute = arriveByMinute
    }

    init(_ favorite: FavoriteTrip) {
        existingID = favorite.id
        name = favorite.name
        from = favorite.from.kind == .currentLocation ? nil : favorite.from
        to = favorite.to
        arriveByMinute = favorite.arriveByMinute
        days = favorite.days
        leaveAlerts = favorite.leaveAlerts
    }

    static let currentLocation = Place(id: "here", name: "Ma position", coordinate: Coordinate(latitude: 0, longitude: 0), kind: .currentLocation)

    func favorite() -> FavoriteTrip? {
        guard let to else { return nil }
        return FavoriteTrip(
            id: existingID ?? UUID(),
            name: name,
            from: from ?? Self.currentLocation,
            to: to,
            arriveByMinute: arriveByMinute,
            days: days,
            leaveAlerts: arriveByMinute != nil && leaveAlerts
        )
    }
}

struct FavoriteTripEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FavoriteDraft
    @State private var picking: PlannerView.Field?
    @State private var addReturn = false

    init(draft: FavoriteDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    placeButton(label: "Départ", value: draft.from?.name ?? "Ma position", icon: "location.circle.fill", tint: .blue) { picking = .from }
                    placeButton(label: "Arrivée", value: draft.to?.name ?? "Choisir", icon: "mappin.circle.fill", tint: .red) { picking = .to }
                    TextField("Nom (facultatif)", text: $draft.name, prompt: Text(defaultName))
                }

                Section {
                    Toggle("Heure d'arrivée habituelle", isOn: Binding(
                        get: { draft.arriveByMinute != nil },
                        set: { draft.arriveByMinute = $0 ? (draft.arriveByMinute ?? 9 * 60) : nil }
                    ))
                    if draft.arriveByMinute != nil {
                        MinutePicker(title: "Arriver avant", minute: Binding(
                            get: { draft.arriveByMinute ?? 9 * 60 },
                            set: { draft.arriveByMinute = $0 }
                        ))
                        WeekdayPicker(selection: $draft.days)
                        Toggle("Rappel « pars maintenant »", isOn: $draft.leaveAlerts)
                    }
                } footer: {
                    Text(draft.arriveByMinute == nil
                         ? "Sans heure, Busio cherche les prochains départs."
                         : "Ces jours-là, Busio propose le bus qui arrive juste avant et celui juste après cette heure.")
                }

                if draft.existingID == nil {
                    Section {
                        Toggle("Créer aussi le trajet retour", isOn: $addReturn)
                    }
                }

                if let existing = draft.existingID {
                    Section {
                        Button("Supprimer ce trajet", role: .destructive) {
                            app.preferences.favoriteTrips.removeAll { $0.id == existing }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(draft.existingID == nil ? "Nouveau trajet favori" : "Trajet favori")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }
                        .disabled(draft.to == nil)
                }
            }
            .sheet(item: $picking) { field in
                PlaceSearchView(title: field == .from ? "Départ" : "Arrivée", allowsCurrentLocation: field == .from) { place in
                    if field == .from { draft.from = place } else { draft.to = place }
                }
            }
        }
    }

    private var defaultName: String {
        "\(draft.from?.name ?? "Ma position") → \(draft.to?.name ?? "…")"
    }

    private func placeButton(label: String, value: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint).font(.title3)
                Text(label).foregroundStyle(.primary)
                Spacer()
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func save() {
        guard let favorite = draft.favorite() else { return }
        if let index = app.preferences.favoriteTrips.firstIndex(where: { $0.id == favorite.id }) {
            app.preferences.favoriteTrips[index] = favorite
        } else {
            app.preferences.favoriteTrips.append(favorite)
            if addReturn, favorite.from.kind != .currentLocation {
                app.preferences.favoriteTrips.append(favorite.reversed)
            }
        }
        if favorite.leaveAlerts {
            Task { _ = await JourneyAlerts.requestAuthorization() }
        }
        dismiss()
    }
}
