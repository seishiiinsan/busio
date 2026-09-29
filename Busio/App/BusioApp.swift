import SwiftUI
import BusioKit

@main
struct BusioApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await app.start() }
                .onOpenURL { app.handle($0) }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("Itinéraire", systemImage: "arrow.triangle.turn.up.right.diamond.fill", value: AppModel.Tab.planner) {
                PlannerView()
            }
            Tab("Carte", systemImage: "map.fill", value: AppModel.Tab.map) {
                LiveMapView()
            }
            Tab("Lignes", systemImage: "point.3.connected.trianglepath.dotted", value: AppModel.Tab.lines) {
                LinesView()
            }
            Tab(value: AppModel.Tab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $app.showSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $app.showOnboarding) {
            OnboardingView()
        }
        .sheet(isPresented: $app.showFollowed) {
            FollowedJourneyView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.resumeFollowing() }
        }
        .overlay {
            if app.network == nil, let error = app.loadError {
                ContentUnavailableView("Réseau indisponible", systemImage: "exclamationmark.triangle", description: Text(error))
                    .background(.background)
            }
        }
    }
}

#if DEBUG
#Preview {
    RootView()
        .environment(AppModel())
}
#endif
