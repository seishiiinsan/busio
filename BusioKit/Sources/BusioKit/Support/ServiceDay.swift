import Foundation

/// Fuseau et calendrier du réseau (Europe/Paris), indépendants du réglage de l'iPhone.
public enum TransitClock {
    public static let timeZone = TimeZone(identifier: "Europe/Paris")!

    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "fr_FR")
        calendar.firstWeekday = 2
        return calendar
    }()
}

/// Jour d'exploitation au sens GTFS/Zenbus : les horaires sont exprimés en
/// secondes depuis « midi moins 12 h » de ce jour, et peuvent dépasser 24 h.
public struct ServiceDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    /// Date au format AAAAMMJJ (ex. 20260929).
    public let yyyymmdd: Int

    public init?(yyyymmdd: Int) {
        let year = yyyymmdd / 10_000, month = (yyyymmdd / 100) % 100, day = yyyymmdd % 100
        guard (2000...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.yyyymmdd = yyyymmdd
    }

    /// Jour calendaire (Europe/Paris) contenant `date`.
    public init(containing date: Date) {
        let c = TransitClock.calendar.dateComponents([.year, .month, .day], from: date)
        yyyymmdd = c.year! * 10_000 + c.month! * 100 + c.day!
    }

    public var year: Int { yyyymmdd / 10_000 }
    public var month: Int { (yyyymmdd / 100) % 100 }
    public var day: Int { yyyymmdd % 100 }

    /// Origine des horaires : midi moins 12 h (correct les jours de changement d'heure).
    public var referenceDate: Date {
        let noon = TransitClock.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return noon.addingTimeInterval(-12 * 3600)
    }

    public func date(seconds: Int) -> Date {
        referenceDate.addingTimeInterval(TimeInterval(seconds))
    }

    public func seconds(of date: Date) -> Int {
        Int(date.timeIntervalSince(referenceDate).rounded(.down))
    }

    /// 1 = dimanche … 7 = samedi (convention `Calendar`).
    public var weekday: Int {
        TransitClock.calendar.component(.weekday, from: referenceDate.addingTimeInterval(12 * 3600))
    }

    public func adding(days: Int) -> ServiceDay {
        let noon = referenceDate.addingTimeInterval(12 * 3600)
        let shifted = TransitClock.calendar.date(byAdding: .day, value: days, to: noon)!
        return ServiceDay(containing: shifted)
    }

    public var previous: ServiceDay { adding(days: -1) }
    public var next: ServiceDay { adding(days: 1) }

    public static func < (lhs: ServiceDay, rhs: ServiceDay) -> Bool { lhs.yyyymmdd < rhs.yyyymmdd }

    public var description: String { String(yyyymmdd) }
}
