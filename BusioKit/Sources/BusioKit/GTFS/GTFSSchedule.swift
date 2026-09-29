import Foundation
import ZIPFoundation

/// Horaires théoriques issus du GTFS open data (secours quand Zenbus ne répond pas
/// ou n'a pas publié la grille du jour).
///
/// Le GTFS Libellus est produit par Zenbus : les identifiants
/// (`zenbus:StopPoint:SP:<id>:LOC`, `zenbus:Line:<id>:LOC`) se ramènent
/// directement à ceux de l'API temps réel.
public struct GTFSSchedule: Sendable {
    public struct FeedInfo: Hashable, Codable, Sendable {
        public let startDay: ServiceDay?
        public let endDay: ServiceDay?
        public let version: String?
    }

    struct Service: Sendable {
        var weekdays: [Bool] // indexé par weekday Calendar (1 = dimanche) - 1
        var start: Int
        var end: Int
        var added: Set<Int> = []
        var removed: Set<Int> = []

        func isActive(on day: ServiceDay) -> Bool {
            if removed.contains(day.yyyymmdd) { return false }
            if added.contains(day.yyyymmdd) { return true }
            guard day.yyyymmdd >= start, day.yyyymmdd <= end else { return false }
            return weekdays[day.weekday - 1]
        }
    }

    struct Trip: Sendable {
        let id: String
        let lineID: String
        let serviceID: String
        let headsign: String?
        let missionID: String?
        var calls: [Call]
    }

    struct Call: Sendable {
        let stopID: String
        let sequence: Int
        let arrival: Int?
        let departure: Int?
    }

    public let info: FeedInfo
    let services: [String: Service]
    let trips: [Trip]
    /// quai → [(course, position du passage)]
    let callsByStop: [String: [(trip: Int, call: Int)]]

    public var tripCount: Int { trips.count }

    // MARK: Chargement

    public init(zipURL: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw TransitError.decoding("archive GTFS illisible")
        }
        func file(_ name: String) throws -> Data? {
            guard let entry = archive[name] else { return nil }
            var data = Data()
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
            return data
        }
        try self.init(files: { try file($0) })
    }

    init(files: (String) throws -> Data?) throws {
        guard let tripsData = try files("trips.txt"), let stopTimesData = try files("stop_times.txt") else {
            throw TransitError.decoding("GTFS incomplet")
        }

        // Services
        var services: [String: Service] = [:]
        if let data = try files("calendar.txt") {
            let t = CSVTable(data: data)
            let days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"].map { t.column($0) }
            let sid = t.column("service_id"), start = t.column("start_date"), end = t.column("end_date")
            for row in t.rows {
                guard let id = CSVTable.value(row, sid) else { continue }
                services[id] = Service(
                    weekdays: days.map { CSVTable.value(row, $0) == "1" },
                    start: CSVTable.value(row, start).flatMap(Int.init) ?? 0,
                    end: CSVTable.value(row, end).flatMap(Int.init) ?? 99_999_999
                )
            }
        }
        if let data = try files("calendar_dates.txt") {
            let t = CSVTable(data: data)
            let sid = t.column("service_id"), date = t.column("date"), type = t.column("exception_type")
            for row in t.rows {
                guard let id = CSVTable.value(row, sid), let day = CSVTable.value(row, date).flatMap(Int.init) else { continue }
                var service = services[id] ?? Service(weekdays: Array(repeating: false, count: 7), start: 0, end: 0)
                if CSVTable.value(row, type) == "1" { service.added.insert(day) } else { service.removed.insert(day) }
                services[id] = service
            }
        }

        // Courses
        let tt = CSVTable(data: tripsData)
        let tRoute = tt.column("route_id"), tService = tt.column("service_id"), tTrip = tt.column("trip_id")
        let tHeadsign = tt.column("trip_headsign"), tMission = tt.column("zenbus_mission_id")
        var trips: [Trip] = []
        var tripIndex: [String: Int] = [:]
        for row in tt.rows {
            guard let id = CSVTable.value(row, tTrip), let route = CSVTable.value(row, tRoute), let service = CSVTable.value(row, tService) else { continue }
            tripIndex[id] = trips.count
            trips.append(Trip(
                id: id,
                lineID: GTFSSchedule.zenbusID(route),
                serviceID: service,
                headsign: CSVTable.value(row, tHeadsign),
                missionID: CSVTable.value(row, tMission),
                calls: []
            ))
        }

        let st = CSVTable(data: stopTimesData)
        let sTrip = st.column("trip_id"), sStop = st.column("stop_id"), sSeq = st.column("stop_sequence")
        let sArr = st.column("arrival_time"), sDep = st.column("departure_time")
        for row in st.rows {
            guard let tripID = CSVTable.value(row, sTrip), let index = tripIndex[tripID], let stop = CSVTable.value(row, sStop) else { continue }
            trips[index].calls.append(Call(
                stopID: GTFSSchedule.zenbusID(stop),
                sequence: CSVTable.value(row, sSeq).flatMap(Int.init) ?? trips[index].calls.count,
                arrival: CSVTable.value(row, sArr).flatMap(GTFSSchedule.seconds),
                departure: CSVTable.value(row, sDep).flatMap(GTFSSchedule.seconds)
            ))
        }
        for i in trips.indices { trips[i].calls.sort { $0.sequence < $1.sequence } }

        var info = FeedInfo(startDay: nil, endDay: nil, version: nil)
        if let data = try files("feed_info.txt") {
            let t = CSVTable(data: data)
            if let row = t.rows.first {
                info = FeedInfo(
                    startDay: CSVTable.value(row, t.column("feed_start_date")).flatMap(Int.init).flatMap(ServiceDay.init(yyyymmdd:)),
                    endDay: CSVTable.value(row, t.column("feed_end_date")).flatMap(Int.init).flatMap(ServiceDay.init(yyyymmdd:)),
                    version: CSVTable.value(row, t.column("feed_version"))
                )
            }
        }

        self.info = info
        self.services = services
        self.trips = trips.filter { !$0.calls.isEmpty }
        var finalByStop: [String: [(trip: Int, call: Int)]] = [:]
        for (i, trip) in self.trips.enumerated() {
            for (j, call) in trip.calls.enumerated() { finalByStop[call.stopID, default: []].append((i, j)) }
        }
        callsByStop = finalByStop
    }

    /// `zenbus:StopPoint:SP:843740007:LOC` → `843740007`.
    static func zenbusID(_ raw: String) -> String {
        guard raw.hasPrefix("zenbus:") else { return raw }
        let parts = raw.split(separator: ":")
        return parts.last { $0.allSatisfy(\.isNumber) }.map(String.init) ?? raw
    }

    /// `25:10:00` → 90600.
    static func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    // MARK: Requêtes

    public func covers(_ day: ServiceDay) -> Bool {
        if let start = info.startDay, day < start { return false }
        if let end = info.endDay, day > end { return false }
        return true
    }

    /// Courses passant par `stopIDs` entre `from` et `to` (jours J-1 et J pour les services après minuit).
    public func trips(servingAny stopIDs: Set<String>, from: Date, to: Date, network: Network) -> [TripInstance] {
        var result: [String: TripInstance] = [:]
        let today = ServiceDay(containing: from)
        for day in [today.previous, today, ServiceDay(containing: to)] {
            for stopID in stopIDs {
                for (tripIndex, callIndex) in callsByStop[stopID] ?? [] {
                    let trip = trips[tripIndex]
                    guard services[trip.serviceID]?.isActive(on: day) == true else { continue }
                    let call = trip.calls[callIndex]
                    guard let seconds = call.departure ?? call.arrival else { continue }
                    let date = day.date(seconds: seconds)
                    guard date >= from, date <= to else { continue }
                    let instance = self.instance(trip, day: day, network: network)
                    result[instance.id] = instance
                }
            }
        }
        return Array(result.values)
    }

    /// Toutes les courses circulant (au moins un passage) entre `from` et `to`.
    public func trips(from: Date, to: Date, network: Network) -> [TripInstance] {
        var result: [TripInstance] = []
        var day = ServiceDay(containing: from).previous
        let last = ServiceDay(containing: to)
        while day <= last {
            let lower = day.seconds(of: from), upper = day.seconds(of: to)
            for trip in trips where services[trip.serviceID]?.isActive(on: day) == true {
                guard let first = trip.calls.first.flatMap({ $0.departure ?? $0.arrival }),
                      let end = trip.calls.last.flatMap({ $0.arrival ?? $0.departure }),
                      end >= lower, first <= upper else { continue }
                result.append(instance(trip, day: day, network: network))
            }
            day = day.next
        }
        return result
    }

    /// Toutes les courses d'une ligne pour un jour.
    public func trips(ofLine lineID: String, on day: ServiceDay, network: Network) -> [TripInstance] {
        trips.filter { $0.lineID == lineID && services[$0.serviceID]?.isActive(on: day) == true }
            .map { instance($0, day: day, network: network) }
    }

    func instance(_ trip: Trip, day: ServiceDay, network: Network) -> TripInstance {
        let itinerary = GTFSSchedule.matchItinerary(for: trip, network: network)
        let calls = trip.calls.enumerated().map { index, call in
            StopCall(
                stopID: call.stopID,
                index: index,
                scheduledArrival: call.arrival.map(day.date(seconds:)),
                scheduledDeparture: (call.departure ?? call.arrival).map(day.date(seconds:)),
                expectedArrival: nil,
                expectedDeparture: nil,
                passed: false
            )
        }
        let headsign = trip.calls.last.flatMap { network.stop($0.stopID)?.name }
            ?? trip.headsign.map { TextFormatting.prettyStopName($0.components(separatedBy: ">").last ?? $0) }
            ?? ""
        let first = trip.calls.first.flatMap { $0.departure ?? $0.arrival } ?? 0
        return TripInstance(
            id: "g:\(itinerary?.id ?? trip.lineID):\(day.yyyymmdd):\(first):\(trip.id)",
            lineID: trip.lineID,
            itineraryID: itinerary?.id,
            headsign: headsign,
            serviceDay: day,
            calls: calls,
            state: .planned,
            quality: .theoretical,
            source: .gtfs,
            vehicle: nil
        )
    }

    /// Sens Zenbus contenant la suite de quais de la course.
    static func matchItinerary(for trip: Trip, network: Network) -> Itinerary? {
        let stops = trip.calls.map(\.stopID)
        guard let first = stops.first else { return nil }
        return network.itineraries(ofLine: trip.lineID).first { itinerary in
            guard let start = itinerary.stopIDs.firstIndex(of: first) else { return false }
            var cursor = start
            for stop in stops.dropFirst() {
                guard let next = itinerary.stopIDs[(cursor + 1)...].firstIndex(of: stop) else { return false }
                cursor = next
            }
            return true
        }
    }
}
