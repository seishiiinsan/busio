import Foundation

public struct Line: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    /// Numéro commercial (« 10 », « Navette »).
    public let code: String
    /// Nom long (« Ligne 10 », « Castres Siala »).
    public let name: String
    public let color: RGBColor
    public let textColor: RGBColor
    public let sortOrder: Int

    public init(id: String, code: String, name: String, color: RGBColor, textColor: RGBColor, sortOrder: Int) {
        self.id = id
        self.code = code
        self.name = name
        self.color = color
        self.textColor = textColor
        self.sortOrder = sortOrder
    }

    public var isNumbered: Bool { Int(code) != nil }

    /// Texte court pour les pastilles (« 10 », « N »).
    public var badge: String { code.count <= 3 ? code : String(code.prefix(1)).uppercased() }

    /// Libellé lisible (« Ligne 10 », « Navette Siala »).
    public var displayName: String {
        if isNumbered { return "Ligne \(code)" }
        let place = name.replacingOccurrences(of: "Castres ", with: "")
        return "\(code) \(place)"
    }
}

public struct Stop: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let code: String
    public let coordinate: Coordinate

    public init(id: String, name: String, code: String, coordinate: Coordinate) {
        self.id = id
        self.name = name
        self.code = code
        self.coordinate = coordinate
    }
}

/// Regroupement des quais d'un même arrêt (les deux sens de circulation).
public struct StopArea: Identifiable, Hashable, Codable, Sendable {
    /// Identifiant stable : plus petit identifiant de quai du groupe.
    public let id: String
    public let name: String
    public let stopIDs: [String]
    public let coordinate: Coordinate
    /// Lignes desservant l'arrêt, triées.
    public let lineIDs: [String]

    public init(id: String, name: String, stopIDs: [String], coordinate: Coordinate, lineIDs: [String]) {
        self.id = id
        self.name = name
        self.stopIDs = stopIDs
        self.coordinate = coordinate
        self.lineIDs = lineIDs
    }
}

/// Un sens d'une ligne (Zenbus « itinerary »).
public struct Itinerary: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let lineID: String
    /// Nom brut (« GUYNEMER > GARES MAZAMET »).
    public let rawName: String
    /// Quais dans l'ordre de passage.
    public let stopIDs: [String]
    /// Distance cumulée (m) de chaque quai depuis le départ, si une variante couvre tout le sens.
    public let distances: [Int]?
    /// Tracés des variantes de parcours (un sens Zenbus réunit plusieurs missions).
    public let paths: [[Coordinate]]

    public init(id: String, lineID: String, rawName: String, stopIDs: [String], distances: [Int]?, paths: [[Coordinate]]) {
        self.id = id
        self.lineID = lineID
        self.rawName = rawName
        self.stopIDs = stopIDs
        self.distances = distances
        self.paths = paths
    }

    /// Terminus (« Gares Mazamet »).
    public var headsign: String {
        let parts = rawName.components(separatedBy: ">")
        return TextFormatting.prettyStopName(parts.last ?? rawName)
    }

    /// Départ (« Guynemer »).
    public var origin: String {
        let parts = rawName.components(separatedBy: ">")
        return TextFormatting.prettyStopName(parts.first ?? rawName)
    }
}

/// Topologie du réseau : lignes, sens, quais, arrêts.
public struct Network: Sendable {
    public let lines: [Line]
    public let itineraries: [Itinerary]
    public let stops: [Stop]
    public let areas: [StopArea]
    /// Version Zenbus des données statiques.
    public let version: Int64
    /// Jour pour lequel ces données ont été publiées.
    public let publishedDay: ServiceDay?

    private let lineIndex: [String: Int]
    private let itineraryIndex: [String: Int]
    private let stopIndex: [String: Int]
    private let areaIndex: [String: Int]
    private let areaOfStop: [String: String]

    public init(lines: [Line], itineraries: [Itinerary], stops: [Stop], version: Int64, publishedDay: ServiceDay?) {
        self.lines = lines.sorted { ($0.sortOrder, $0.isNumbered ? 0 : 1, Int($0.code) ?? 0, $0.name) < ($1.sortOrder, $1.isNumbered ? 0 : 1, Int($1.code) ?? 0, $1.name) }
        self.itineraries = itineraries
        self.stops = stops
        self.version = version
        self.publishedDay = publishedDay

        var linesOfStop: [String: Set<String>] = [:]
        for itinerary in itineraries {
            for stopID in itinerary.stopIDs { linesOfStop[stopID, default: []].insert(itinerary.lineID) }
        }
        let lineOrder = Dictionary(uniqueKeysWithValues: self.lines.enumerated().map { ($1.id, $0) })
        let areas = StopAreaBuilder.build(stops: stops, linesOfStop: linesOfStop, lineOrder: lineOrder)
        self.areas = areas

        lineIndex = Dictionary(self.lines.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        itineraryIndex = Dictionary(itineraries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        stopIndex = Dictionary(stops.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        areaIndex = Dictionary(areas.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var areaOfStop: [String: String] = [:]
        for area in areas { for stopID in area.stopIDs { areaOfStop[stopID] = area.id } }
        self.areaOfStop = areaOfStop
    }

    public func line(_ id: String) -> Line? { lineIndex[id].map { lines[$0] } }
    public func itinerary(_ id: String) -> Itinerary? { itineraryIndex[id].map { itineraries[$0] } }
    public func stop(_ id: String) -> Stop? { stopIndex[id].map { stops[$0] } }
    public func area(_ id: String) -> StopArea? { areaIndex[id].map { areas[$0] } }
    public func area(containingStop stopID: String) -> StopArea? { areaOfStop[stopID].flatMap { area($0) } }

    public func itineraries(ofLine lineID: String) -> [Itinerary] {
        itineraries.filter { $0.lineID == lineID }
    }

    /// Sens desservant au moins un quai de `area`.
    public func itineraries(serving area: StopArea) -> [Itinerary] {
        let ids = Set(area.stopIDs)
        return itineraries.filter { $0.stopIDs.contains(where: ids.contains) }
    }

    /// Arrêts les plus proches, triés par distance.
    public func nearestAreas(to coordinate: Coordinate, limit: Int = 10, within radius: Double = 1_500) -> [(area: StopArea, distance: Double)] {
        areas
            .map { ($0, $0.coordinate.distance(to: coordinate)) }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { (area: $0.0, distance: $0.1) }
    }

    /// Recherche tolérante (accents, casse, tirets).
    public func searchAreas(_ query: String) -> [StopArea] {
        let q = TextFormatting.searchKey(query)
        guard !q.isEmpty else { return areas.sorted { $0.name < $1.name } }
        let tokens = q.split(separator: " ")
        return areas
            .compactMap { area -> (StopArea, Int)? in
                let key = TextFormatting.searchKey(area.name)
                guard tokens.allSatisfy({ key.contains($0) }) else { return nil }
                let score = key.hasPrefix(q) ? 0 : (key.contains(" " + q) ? 1 : 2)
                return (area, score)
            }
            .sorted { ($0.1, $0.0.name) < ($1.1, $1.0.name) }
            .map(\.0)
    }
}

enum StopAreaBuilder {
    /// Regroupe les quais de même nom situés à moins de `radius` mètres
    /// (deux « Languedoc » à Castres et Aussillon restent distincts).
    static func build(stops: [Stop], linesOfStop: [String: Set<String>], lineOrder: [String: Int], radius: Double = 450) -> [StopArea] {
        let byName = Dictionary(grouping: stops) { TextFormatting.searchKey($0.name) }
        var areas: [StopArea] = []
        for (_, group) in byName {
            var clusters: [[Stop]] = []
            for stop in group.sorted(by: { $0.id < $1.id }) {
                if let i = clusters.firstIndex(where: { $0.contains { $0.coordinate.distance(to: stop.coordinate) <= radius } }) {
                    clusters[i].append(stop)
                } else {
                    clusters.append([stop])
                }
            }
            for cluster in clusters {
                let ids = cluster.map(\.id).sorted()
                let lineIDs = Set(ids.flatMap { linesOfStop[$0] ?? [] })
                    .sorted { (lineOrder[$0] ?? .max) < (lineOrder[$1] ?? .max) }
                areas.append(StopArea(
                    id: ids[0],
                    name: cluster[0].name,
                    stopIDs: ids,
                    coordinate: Coordinate.centroid(of: cluster.map(\.coordinate)) ?? cluster[0].coordinate,
                    lineIDs: lineIDs
                ))
            }
        }
        return areas.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}
