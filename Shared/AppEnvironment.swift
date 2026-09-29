import Foundation
import SwiftUI
import BusioKit

/// Conteneur partagé entre l'app, les widgets et les intents.
enum AppGroup {
    static let identifier: String =
        Bundle.main.object(forInfoDictionaryKey: "BusioAppGroup") as? String ?? "group.fr.seishiiinsan.busio"

    static let containerURL: URL = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        // Signature sans App Group (ex. simulateur non signé) : dossier local.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Busio", isDirectory: true)
    }()

    static let store = SharedStore(containerURL: containerURL)

    /// Données embarquées : `Seed/` dans l'app (aussi lisible depuis l'extension).
    static let seedDirectory: URL? = {
        var candidates = [Bundle.main.bundleURL.appendingPathComponent("Seed")]
        if Bundle.main.bundleURL.pathExtension == "appex" {
            let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(app.appendingPathComponent("Seed"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }()
}

enum Transit {
    /// Service unique par processus.
    static let service = TransitService(configuration: .init(
        cacheDirectory: AppGroup.store.cacheDirectory,
        seedDirectory: AppGroup.seedDirectory
    ))
}

// MARK: - Couleurs

extension RGBColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

extension Color {
    init(hex: String) {
        self = (RGBColor(hex: hex) ?? .neutral).color
    }
}

extension Line {
    var tint: Color { color.color }
    var onTint: Color { textColor.color }
}

extension LineStyle {
    var tint: Color { color.color }
    var onTint: Color { textColor.color }
}

// MARK: - Temps

enum TimeText {
    private static let clockStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "fr_FR"), calendar: TransitClock.calendar, timeZone: TransitClock.timeZone)

    /// « 08:14 »
    static func clock(_ date: Date) -> String { date.formatted(clockStyle) }

    /// Minutes entières restantes (arrondi inférieur, jamais négatif).
    static func minutes(until date: Date, from now: Date) -> Int {
        max(0, Int(date.timeIntervalSince(now) / 60))
    }

    /// « à l'instant », « 4 min », « 1 h 05 »
    static func countdown(to date: Date, from now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 30 { return "à l'instant" }
        let minutes = max(1, Int((seconds / 60).rounded(.down)))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }

    /// « +3 min », « −1 min », nil si à l'heure (écart < 1 min).
    static func delay(_ delay: TimeInterval?) -> String? {
        guard let delay, abs(delay) >= 60 else { return nil }
        let minutes = Int((abs(delay) / 60).rounded())
        return delay > 0 ? "+\(minutes) min" : "−\(minutes) min"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }

    /// « aujourd'hui », « demain », « lundi 5 octobre »
    static func dayLabel(_ date: Date, now: Date = Date()) -> String {
        let calendar = TransitClock.calendar
        if calendar.isDate(date, inSameDayAs: now) { return "aujourd'hui" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "demain" }
        return date.formatted(Date.FormatStyle(locale: Locale(identifier: "fr_FR"), calendar: calendar, timeZone: TransitClock.timeZone).weekday(.wide).day().month(.wide))
    }
}

extension TimingQuality {
    var label: String {
        switch self {
        case .live: "En direct"
        case .estimated: "Estimé"
        case .planned: "Prévu"
        case .theoretical: "Théorique"
        }
    }

    var symbol: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .estimated: "clock.badge.checkmark"
        case .planned: "clock"
        case .theoretical: "calendar"
        }
    }
}
