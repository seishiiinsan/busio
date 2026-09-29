import AppIntents
import SwiftUI
import WidgetKit

@main
struct BusioWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TripWidget()
        JourneyLiveActivity()
        FollowTripControl()
    }
}

/// Bouton du Centre de contrôle / écran verrouillé / bouton Action.
struct FollowTripControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "FollowTripControl") {
            ControlWidgetButton(action: StartTripActivityIntent()) {
                Label("Suivre mon trajet", systemImage: "bus.fill")
            }
        }
        .displayName("Suivre mon trajet")
        .description("Lance le compte à rebours de ton trajet favori le plus proche.")
    }
}
