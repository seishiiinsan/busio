import AppIntents
import SwiftUI
import WidgetKit

@main
struct BusioWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CommuteWidget()
        CommuteLiveActivity()
        FollowBusControl()
    }
}

/// Bouton du Centre de contrôle / écran verrouillé / bouton Action.
struct FollowBusControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "FollowBusControl") {
            ControlWidgetButton(action: StartCommuteActivityIntent()) {
                Label("Suivre mon bus", systemImage: "bus.fill")
            }
        }
        .displayName("Suivre mon bus")
        .description("Lance le compte à rebours du prochain bus de ton trajet.")
    }
}
