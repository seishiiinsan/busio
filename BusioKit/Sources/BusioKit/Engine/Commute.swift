import Foundation

/// Arrêt mémorisé (favori, domicile, travail). Garde nom et position pour
/// retrouver l'arrêt si Zenbus renumérote ses quais.
public struct PlaceRef: Codable, Hashable, Sendable, Identifiable {
    public let areaID: String
    public let name: String
    public let coordinate: Coordinate

    public var id: String { areaID }

    public init(areaID: String, name: String, coordinate: Coordinate) {
        self.areaID = areaID
        self.name = name
        self.coordinate = coordinate
    }

    public init(_ area: StopArea) {
        self.init(areaID: area.id, name: area.name, coordinate: area.coordinate)
    }

    public func resolve(in network: Network) -> StopArea? {
        if let area = network.area(areaID) { return area }
        let key = TextFormatting.searchKey(name)
        return network.areas
            .filter { TextFormatting.searchKey($0.name) == key }
            .min { $0.coordinate.distance(to: coordinate) < $1.coordinate.distance(to: coordinate) }
            .flatMap { $0.coordinate.distance(to: coordinate) < 600 ? $0 : nil }
    }
}

public enum CommuteDirection: String, Codable, CaseIterable, Sendable, Identifiable {
    case toWork
    case toHome

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toWork: "Aller au travail"
        case .toHome: "Rentrer"
        }
    }

    public var opposite: CommuteDirection { self == .toWork ? .toHome : .toWork }
}

/// Réglages du trajet quotidien.
public struct CommuteSettings: Codable, Hashable, Sendable {
    public var home: PlaceRef?
    public var work: PlaceRef?
    /// Avant cette heure (minutes depuis minuit), l'app propose l'aller ; après, le retour.
    public var switchMinute: Int
    /// Jours travaillés (1 = dimanche … 7 = samedi).
    public var workdays: Set<Int>
    /// Heure limite d'arrivée au travail (minutes depuis minuit).
    public var arriveByMinute: Int
    /// Heure de sortie du travail (minutes depuis minuit).
    public var leaveWorkMinute: Int
    /// Marge ajoutée au temps de marche.
    public var bufferMinutes: Int
    /// Temps de marche utilisés quand la position est inconnue.
    public var walkToHomeStopMinutes: Int
    public var walkToWorkStopMinutes: Int

    public init(
        home: PlaceRef? = nil,
        work: PlaceRef? = nil,
        switchMinute: Int = 12 * 60,
        workdays: Set<Int> = [2, 3, 4, 5, 6],
        arriveByMinute: Int = 9 * 60 + 15,
        leaveWorkMinute: Int = 16 * 60 + 30,
        bufferMinutes: Int = 2,
        walkToHomeStopMinutes: Int = 5,
        walkToWorkStopMinutes: Int = 5
    ) {
        self.home = home
        self.work = work
        self.switchMinute = switchMinute
        self.workdays = workdays
        self.arriveByMinute = arriveByMinute
        self.leaveWorkMinute = leaveWorkMinute
        self.bufferMinutes = bufferMinutes
        self.walkToHomeStopMinutes = walkToHomeStopMinutes
        self.walkToWorkStopMinutes = walkToWorkStopMinutes
    }

    public var isConfigured: Bool { home != nil && work != nil }

    public func isWorkday(_ date: Date) -> Bool {
        workdays.contains(TransitClock.calendar.component(.weekday, from: date))
    }

    /// Sens proposé à cette heure.
    public func direction(at date: Date) -> CommuteDirection {
        let c = TransitClock.calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour! * 60 + c.minute!) < switchMinute ? .toWork : .toHome
    }

    public func origin(for direction: CommuteDirection) -> PlaceRef? { direction == .toWork ? home : work }
    public func destination(for direction: CommuteDirection) -> PlaceRef? { direction == .toWork ? work : home }

    /// Marche par défaut jusqu'à l'arrêt de départ.
    public func fallbackWalk(for direction: CommuteDirection) -> TimeInterval {
        TimeInterval((direction == .toWork ? walkToHomeStopMinutes : walkToWorkStopMinutes) * 60)
    }

    /// Marche de l'arrêt d'arrivée jusqu'à destination.
    public func egressWalk(for direction: CommuteDirection) -> TimeInterval {
        TimeInterval((direction == .toWork ? walkToWorkStopMinutes : walkToHomeStopMinutes) * 60)
    }

    public static func date(minute: Int, on day: Date) -> Date {
        let start = TransitClock.calendar.startOfDay(for: day)
        return TransitClock.calendar.date(byAdding: .minute, value: minute, to: start) ?? start
    }

    /// Bus conseillé : le dernier qui arrive à l'heure le matin, le premier après la sortie le soir.
    public func recommended(in journeys: [Journey], direction: CommuteDirection, on day: Date) -> Journey? {
        let usable = journeys.filter { !$0.isCancelled }
        switch direction {
        case .toWork:
            let deadline = Self.date(minute: arriveByMinute, on: day).addingTimeInterval(-egressWalk(for: direction))
            return usable.last { $0.arrivalTime <= deadline } ?? usable.first
        case .toHome:
            let earliest = Self.date(minute: leaveWorkMinute, on: day).addingTimeInterval(fallbackWalk(for: direction))
            return usable.first { $0.departureTime >= earliest } ?? usable.first
        }
    }
}

/// Quand partir à pied pour attraper un bus.
public struct LeaveAdvice: Hashable, Codable, Sendable {
    public let journeyID: String
    public let departure: Date
    public let walk: TimeInterval
    public let buffer: TimeInterval

    public init(journey: Journey, walk: TimeInterval, buffer: TimeInterval) {
        journeyID = journey.id
        departure = journey.departureTime
        self.walk = walk
        self.buffer = buffer
    }

    public var leaveAt: Date { departure.addingTimeInterval(-walk - buffer) }

    public func isReachable(from now: Date) -> Bool { leaveAt >= now.addingTimeInterval(-30) }
}
