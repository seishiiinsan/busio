import Foundation

/// Conversion des messages protobuf Zenbus vers le modèle Busio.
public enum ZenbusMapper {
    // MARK: Données statiques

    public static func network(from message: ZenbusRealtime_StaticMessage) -> Network {
        let lines = message.line.map { line -> Line in
            let color = RGBColor(hex: line.color) ?? .neutral
            let text = RGBColor(hex: line.textColor) ?? (color.luminance > 0.45 ? .black : .white)
            return Line(
                id: String(line.lineID),
                code: line.code.isEmpty ? line.displayShortName : line.code,
                name: line.name.isEmpty ? line.displayLongName : line.name,
                color: color,
                textColor: text,
                sortOrder: Int(line.routeSortOrder)
            )
        }

        let stops = message.stop.compactMap { stop -> Stop? in
            let coordinate = Coordinate(latitude: Double(stop.center.latitude), longitude: Double(stop.center.longitude))
            guard coordinate.isValid else { return nil }
            return Stop(
                id: String(stop.stopID),
                name: TextFormatting.prettyStopName(stop.name.isEmpty ? stop.code : stop.name),
                code: stop.code,
                coordinate: coordinate
            )
        }

        let shapesByID = Dictionary(message.shape.map { ($0.shapeID, $0) }, uniquingKeysWith: { a, _ in a })
        let shapesByItinerary = Dictionary(grouping: message.shape.filter { $0.itineraryOneof != nil }) { $0.itineraryID }

        let itineraries = message.itinerary.map { itinerary -> Itinerary in
            let stopIDs = itinerary.stopRef.map { String($0.stopID) }
            // Variantes (missions partielles), la plus complète d'abord.
            let variants = (shapesByItinerary[itinerary.itineraryID] ?? []).sorted { $0.anchor.count > $1.anchor.count }
            let best = variants.first
            var distances: [Int]?
            if let best, !stopIDs.isEmpty {
                var d = [Int](repeating: -1, count: stopIDs.count)
                for (position, anchor) in best.anchor.enumerated() {
                    let index = anchor.stopIndexInItinerary != 0 ? Int(anchor.stopIndexInItinerary) : (position == 0 ? 0 : position)
                    if d.indices.contains(index) { d[index] = Int(anchor.distanceTravelled) }
                }
                distances = d.contains(-1) ? nil : d
            }
            return Itinerary(
                id: String(itinerary.itineraryID),
                lineID: String(itinerary.lineID),
                rawName: itinerary.name,
                stopIDs: stopIDs,
                distances: distances,
                paths: distinctPaths(variants.map { path(of: $0, shapes: shapesByID) })
            )
        }

        return Network(
            lines: lines,
            itineraries: itineraries,
            stops: stops,
            version: message.version,
            publishedDay: message.resource.yyyymmdd.last.flatMap { ServiceDay(yyyymmdd: Int($0)) }
        )
    }

    /// Écarte les variantes entièrement contenues dans une autre (même tracé, plus court).
    private static func distinctPaths(_ paths: [[Coordinate]]) -> [[Coordinate]] {
        var result: [[Coordinate]] = []
        for path in paths where path.count > 1 {
            let points = Set(path.map { "\(Int($0.latitude * 20_000)),\(Int($0.longitude * 20_000))" })
            let covered = result.contains { existing in
                let other = Set(existing.map { "\(Int($0.latitude * 20_000)),\(Int($0.longitude * 20_000))" })
                return Double(points.intersection(other).count) >= Double(points.count) * 0.95
            }
            if !covered { result.append(path) }
        }
        return result
    }

    private static func path(of shape: ZenbusRealtime_Shape, shapes: [Int64: ZenbusRealtime_Shape], depth: Int = 0) -> [Coordinate] {
        switch shape.pathOneof {
        case .points(let points):
            return points.point.map { Coordinate(latitude: Double($0.latitude), longitude: Double($0.longitude)) }.filter(\.isValid)
        case .segments(let segments) where depth < 4:
            return segments.shapeReference.flatMap { ref -> [Coordinate] in
                guard let sub = shapes[ref.shapeID] else { return [] }
                return path(of: sub, shapes: shapes, depth: depth + 1)
            }
        default:
            return []
        }
    }

    // MARK: Temps réel

    public struct LiveSnapshot: Sendable {
        public let trips: [TripInstance]
        public let alerts: [ServiceAlert]
        /// Jours de service couverts par la réponse, par sens.
        public let serviceDays: [String: ServiceDay]
        /// Horodatage serveur.
        public let serverTime: Date?
    }

    public static func snapshot(from message: ZenbusRealtime_LiveMessage, network: Network) -> LiveSnapshot {
        var trips: [TripInstance] = []
        var days: [String: ServiceDay] = [:]

        for timetable in message.timetable {
            guard timetable.itineraryOneof != nil else { continue }
            let itineraryID = String(timetable.itineraryID)
            guard let itinerary = network.itinerary(itineraryID) else { continue }
            let midnight = timetable.midnight > 0 ? Date(timeIntervalSince1970: TimeInterval(timetable.midnight)) : nil
            guard let day = serviceDay(yyyymmdd: timetable.yyyymmddOneof != nil ? timetable.yyyymmdd : 0, midnight: midnight) else { continue }
            days[itineraryID] = day
            for (position, column) in timetable.column.enumerated() {
                if let trip = trip(from: column, itinerary: itinerary, network: network, day: day, midnight: midnight, position: position) {
                    trips.append(trip)
                }
            }
        }

        // Courses hors grille (ajoutées, non planifiées).
        for (position, column) in message.tripColumn.enumerated() {
            guard column.itineraryOneof != nil, let itinerary = network.itinerary(String(column.itineraryID)) else { continue }
            let midnight = column.midnight > 0 ? Date(timeIntervalSince1970: TimeInterval(column.midnight)) : nil
            let yyyymmdd = column.yyyymmddOneof != nil ? column.yyyymmdd : 0
            guard let day = serviceDay(yyyymmdd: yyyymmdd, midnight: midnight) ?? days[itinerary.id] else { continue }
            if let trip = trip(from: column, itinerary: itinerary, network: network, day: day, midnight: midnight, position: 10_000 + position),
               !trips.contains(where: { $0.id == trip.id }) {
                trips.append(trip)
            }
        }

        let alerts = message.messages.compactMap(alert(from:))
        let serverTime = message.endProcessing > 0 ? Date(timeIntervalSince1970: TimeInterval(message.endProcessing) / 1000) : nil
        return LiveSnapshot(trips: trips, alerts: alerts, serviceDays: days, serverTime: serverTime)
    }

    static func serviceDay(yyyymmdd: Int32, midnight: Date?) -> ServiceDay? {
        if let day = ServiceDay(yyyymmdd: Int(yyyymmdd)) { return day }
        // Midi local du jour dont `midnight` est le début.
        return midnight.map { ServiceDay(containing: $0.addingTimeInterval(12 * 3600)) }
    }

    static func trip(from column: ZenbusRealtime_TripColumn, itinerary: Itinerary, network: Network, day: ServiceDay, midnight: Date?, position: Int) -> TripInstance? {
        let base = column.midnight > 0 ? Date(timeIntervalSince1970: TimeInterval(column.midnight)) : (midnight ?? day.referenceDate)
        func date(_ seconds: Int32) -> Date? { seconds > 0 ? base.addingTimeInterval(TimeInterval(seconds)) : nil }

        func indexed(_ times: [ZenbusRealtime_StopTime]) -> [Int: ZenbusRealtime_StopTime] {
            var result: [Int: ZenbusRealtime_StopTime] = [:]
            for (position, time) in times.enumerated() {
                let index = time.stopInItineraryOneof != nil ? Int(time.stopIndexInItinerary) : position
                result[index] = time
            }
            return result
        }
        let aimed = indexed(column.aimed)
        let estimated = indexed(column.estimactual)
        let indices = Set(aimed.keys).union(estimated.keys).filter { itinerary.stopIDs.indices.contains($0) }.sorted()
        guard !indices.isEmpty else { return nil }

        let descriptor = column.jtfsScheduleRelationshipDescriptor
        let isLiveDescriptor = descriptor.rawValue >= 100
        let hasPosition = !column.pos.isEmpty
        let previousIndex = Int(column.previousIndexInItinerary)

        let state: TripState
        if descriptor == .canceledLive {
            state = .cancelled
        } else if column.tripStatus == .archived {
            state = .finished
        } else if isLiveDescriptor && hasPosition && previousIndex >= 0 {
            state = .running
        } else {
            state = .planned
        }

        var calls: [StopCall] = []
        var lastDelay: TimeInterval?
        for index in indices {
            let a = aimed[index], e = estimated[index]
            let scheduledArrival = a.flatMap { date($0.arrival) ?? date($0.arriparture) }
            let scheduledDeparture = a.flatMap { date($0.departure) ?? date($0.arriparture) } ?? scheduledArrival
            var expectedArrival = e.flatMap { date($0.arrival) }
            var expectedDeparture = e.flatMap { date($0.departure) }
            let passed = state == .finished || (state == .running && index <= previousIndex)

            if state == .running {
                if let expectedDeparture, let scheduledDeparture {
                    lastDelay = expectedDeparture.timeIntervalSince(scheduledDeparture)
                } else if !passed, expectedArrival == nil, expectedDeparture == nil, let lastDelay {
                    // Pas d'estimation pour ce quai : on propage le dernier retard connu.
                    expectedArrival = scheduledArrival?.addingTimeInterval(lastDelay)
                    expectedDeparture = scheduledDeparture?.addingTimeInterval(lastDelay)
                }
            }

            calls.append(StopCall(
                stopID: itinerary.stopIDs[index],
                index: index,
                scheduledArrival: scheduledArrival,
                scheduledDeparture: scheduledDeparture,
                expectedArrival: state == .cancelled ? nil : expectedArrival,
                expectedDeparture: state == .cancelled ? nil : expectedDeparture,
                passed: passed
            ))
        }

        let quality: TimingQuality
        switch state {
        case .running, .finished: quality = .live
        case .planned: quality = estimated.isEmpty ? .planned : .estimated
        case .cancelled: quality = .planned
        }

        var vehicle: VehicleSnapshot?
        if let pos = column.pos.last {
            let coordinate = Coordinate(latitude: Double(pos.latitude), longitude: Double(pos.longitude))
            if coordinate.isValid {
                let timestamp: Date?
                switch pos.timestampOneof {
                case .secondsAfterMidnight(let s): timestamp = base.addingTimeInterval(TimeInterval(s))
                case .utcMillis(let ms): timestamp = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
                case nil: timestamp = nil
                }
                vehicle = VehicleSnapshot(
                    id: column.vehicleOneof != nil ? String(column.vehicleID) : "trip-\(position)",
                    coordinate: coordinate,
                    heading: pos.heading != 0 ? Double(pos.heading) : nil,
                    timestamp: timestamp,
                    distanceTravelled: column.distanceTravelled > 0 ? Int(column.distanceTravelled) : nil,
                    previousStopIndex: previousIndex >= 0 ? previousIndex : nil
                )
            }
        }

        let headsign: String
        if !column.tripHeadsign.isEmpty {
            headsign = TextFormatting.prettyStopName(column.tripHeadsign.components(separatedBy: ">").last ?? column.tripHeadsign)
        } else if let last = indices.last, let stop = network.stop(itinerary.stopIDs[last]) {
            headsign = stop.name
        } else {
            headsign = itinerary.headsign
        }

        let firstAimed: Int = column.aimed.first.map { Int($0.departure > 0 ? $0.departure : $0.arrival) } ?? position
        let firstIndex = indices[0]
        return TripInstance(
            id: "z:\(itinerary.id):\(day.yyyymmdd):\(firstAimed):\(firstIndex)",
            lineID: itinerary.lineID,
            itineraryID: itinerary.id,
            headsign: headsign,
            serviceDay: day,
            calls: calls,
            state: state,
            quality: quality,
            source: .zenbus,
            vehicle: vehicle
        )
    }

    static func alert(from message: ZenbusRealtime_WallMessage) -> ServiceAlert? {
        guard message.deleted == 0 else { return nil }
        let text = message.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = message.shortMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !short.isEmpty else { return nil }
        func date(_ value: Int64) -> Date? {
            guard value > 0 else { return nil }
            return Date(timeIntervalSince1970: value > 100_000_000_000 ? TimeInterval(value) / 1000 : TimeInterval(value))
        }
        let severity: ServiceAlert.Severity
        switch message.effect {
        case .noService, .significantDelays, .detour, .stopMoved: severity = .severe
        case .reducedService, .modifiedService: severity = .warning
        default: severity = message.priority == .high ? .severe : (message.priority == .medium ? .warning : .info)
        }
        return ServiceAlert(
            id: String(message.msgID),
            lineIDs: message.informedEntity.map(\.lineID).filter { $0 != 0 }.map(String.init),
            title: short.isEmpty ? String(text.prefix(80)) : short,
            message: text.isEmpty ? short : text,
            severity: severity,
            start: date(message.eventStart) ?? date(message.notifyStart),
            end: date(message.eventEnd) ?? date(message.notifyEnd)
        )
    }
}
