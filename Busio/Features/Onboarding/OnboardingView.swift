import SwiftUI
import BusioKit

/// Premier lancement : présentation puis autorisations.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.welcome

    enum Step: Int, CaseIterable {
        case welcome, permissions
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissions
                }
            }
            .padding(.vertical)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Plus tard") { finish() }
                }
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
                Feature(icon: "arrow.triangle.turn.up.right.diamond.fill", title: "Où tu veux, quand tu veux", text: "Une adresse, un lieu ou un arrêt : Busio trouve les bus et correspondances.")
                Feature(icon: "dot.radiowaves.left.and.right", title: "Temps réel Zenbus", text: "Les mêmes données que l'app officielle, en plus lisible.")
                Feature(icon: "star.fill", title: "Trajets favoris", text: "Ton trajet quotidien en un geste, avec l'heure d'arrivée qui t'arrange.")
                Feature(icon: "calendar.badge.checkmark", title: "Jamais sans horaire", text: "Si le temps réel tombe, Busio bascule sur les horaires officiels et te le dit.")
            }
            .padding(.horizontal, 28)
            Spacer()
            Button {
                withAnimation { step = .permissions }
            } label: {
                Text("Continuer").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal)
        }
    }

    private var permissions: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "location.north.circle.fill").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Pars de là où tu es").font(.title.bold())
            Text("Ta position sert de point de départ et à calculer la marche jusqu'à l'arrêt. Les notifications te préviennent quand partir et si ton bus a du retard.")
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
                    Task { _ = await JourneyAlerts.requestAuthorization() }
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
