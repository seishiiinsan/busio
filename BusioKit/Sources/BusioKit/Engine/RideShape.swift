import Foundation

/// Tracé d'un bus de la montée à la descente, avec la position de chaque arrêt le long du tracé.
/// Sert à dessiner l'itinéraire et à savoir où l'on en est dans le bus.
public struct RideShape: Sendable {
    public let points: [Coordinate]
    /// Distance (m) depuis la montée de chaque arrêt de `ride.calls`.
    public let stopOffsets: [Double]
    public let stopCoordinates: [Coordinate]
    private let cumulative: [Double]
    private let plane: Plane
    private let planar: [Point]

    public var length: Double { cumulative.last ?? 0 }

    public init(ride: RideLeg, network: Network) {
        let stops = ride.calls.map { call in
            network.stop(call.stopID)?.coordinate ?? network.area(containingStop: call.stopID)?.coordinate
        }
        let known = stops.compactMap { $0 }
        let plane = Plane(origin: known.first ?? Coordinate(latitude: 43.6, longitude: 2.25))

        // Variante de parcours qui passe au plus près de tous les arrêts.
        let candidates = ride.itineraryID.flatMap { network.itinerary($0)?.paths } ?? []
        let fallbackCandidates = network.itineraries(ofLine: ride.lineID).flatMap(\.paths)
        var best: (path: Polyline, offsets: [Double], fit: Double)?
        for path in candidates + fallbackCandidates where path.count > 1 {
            let polyline = Polyline(path.map(plane.point))
            guard let fitted = polyline.fit(stops.map { $0.map(plane.point) }) else { continue }
            if fitted.fit < (best?.fit ?? .infinity) { best = (polyline, fitted.offsets, fitted.fit) }
        }

        if let best, best.fit <= 150, let first = best.offsets.first, let last = best.offsets.last, last > first {
            let cut = best.path.slice(from: first, to: last)
            self.plane = plane
            planar = cut
            points = cut.map(plane.coordinate)
            cumulative = Polyline.cumulative(cut)
            stopOffsets = best.offsets.map { $0 - first }
        } else {
            // Pas de tracé fiable : ligne droite d'arrêt en arrêt.
            let straight = known.map(plane.point)
            self.plane = plane
            planar = straight
            points = known
            cumulative = Polyline.cumulative(straight)
            var offsets = cumulative
            while offsets.count < stops.count { offsets.append(offsets.last ?? 0) }
            stopOffsets = Array(offsets.prefix(stops.count))
        }
        let fallback = points.last ?? plane.origin
        stopCoordinates = stops.map { $0 ?? fallback }
    }

    /// Position le long du tracé (m depuis la montée) et écart au tracé (m).
    /// `after` évite de se raccrocher à un passage antérieur quand le tracé boucle.
    public func project(_ coordinate: Coordinate, after minOffset: Double = -.infinity) -> (offset: Double, distance: Double) {
        Polyline.project(plane.point(coordinate), on: planar, cumulative: cumulative, after: minOffset)
    }

    /// Point du tracé à `offset` mètres de la montée.
    public func coordinate(at offset: Double) -> Coordinate {
        guard planar.count > 1 else { return points.first ?? plane.coordinate(Point(x: 0, y: 0)) }
        let o = min(max(0, offset), length)
        for i in 1..<planar.count where cumulative[i] >= o {
            let span = cumulative[i] - cumulative[i - 1]
            let t = span > 0 ? (o - cumulative[i - 1]) / span : 0
            return plane.coordinate(planar[i - 1].lerp(planar[i], t))
        }
        return points[points.count - 1]
    }
}

// MARK: Géométrie plane locale

struct Point: Sendable {
    var x: Double
    var y: Double

    func distance(to other: Point) -> Double { hypot(x - other.x, y - other.y) }
    func lerp(_ other: Point, _ t: Double) -> Point { Point(x: x + (other.x - x) * t, y: y + (other.y - y) * t) }
}

/// Projection équirectangulaire autour d'un point (précise au mètre à l'échelle d'une agglomération).
struct Plane: Sendable {
    let origin: Coordinate
    private let kx: Double
    private let ky = 111_132.0

    init(origin: Coordinate) {
        self.origin = origin
        kx = 111_320 * cos(origin.latitude * .pi / 180)
    }

    func point(_ c: Coordinate) -> Point {
        Point(x: (c.longitude - origin.longitude) * kx, y: (c.latitude - origin.latitude) * ky)
    }

    func coordinate(_ p: Point) -> Coordinate {
        Coordinate(latitude: origin.latitude + p.y / ky, longitude: origin.longitude + p.x / kx)
    }
}

struct Polyline: Sendable {
    let points: [Point]
    let cumulative: [Double]

    init(_ points: [Point]) {
        self.points = points
        cumulative = Self.cumulative(points)
    }

    static func cumulative(_ points: [Point]) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(points.count)
        var total = 0.0
        for (i, p) in points.enumerated() {
            if i > 0 { total += points[i - 1].distance(to: p) }
            result.append(total)
        }
        return result
    }

    /// Projection sur le premier passage (à 15 m près) situé après `minOffset`.
    static func project(_ p: Point, on points: [Point], cumulative: [Double], after minOffset: Double) -> (offset: Double, distance: Double) {
        guard points.count > 1 else { return (0, points.first.map { p.distance(to: $0) } ?? .infinity) }
        var projections: [(offset: Double, distance: Double)] = []
        projections.reserveCapacity(points.count)
        for i in 1..<points.count where cumulative[i] >= minOffset {
            let a = points[i - 1], b = points[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let length2 = dx * dx + dy * dy
            let t = length2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2)) : 0
            let q = a.lerp(b, t)
            let offset = cumulative[i - 1] + t * (cumulative[i] - cumulative[i - 1])
            guard offset >= minOffset else { continue }
            projections.append((offset, p.distance(to: q)))
        }
        guard let nearest = projections.min(by: { $0.distance < $1.distance }) else {
            return (cumulative.last ?? 0, p.distance(to: points[points.count - 1]))
        }
        return projections.first { $0.distance <= nearest.distance + 15 } ?? nearest
    }

    /// Positions successives des arrêts sur le tracé et plus grand écart (m).
    func fit(_ stops: [Point?]) -> (offsets: [Double], fit: Double)? {
        var offsets: [Double] = []
        var worst = 0.0
        var cursor = -Double.infinity
        for stop in stops {
            guard let stop else {
                offsets.append(max(cursor, 0))
                continue
            }
            let projection = Self.project(stop, on: points, cumulative: cumulative, after: cursor)
            worst = max(worst, projection.distance)
            cursor = projection.offset
            offsets.append(projection.offset)
        }
        return offsets.isEmpty ? nil : (offsets, worst)
    }

    /// Portion du tracé entre deux positions.
    func slice(from start: Double, to end: Double) -> [Point] {
        var result: [Point] = [point(at: start)]
        for (i, p) in points.enumerated() where cumulative[i] > start && cumulative[i] < end { result.append(p) }
        result.append(point(at: end))
        return result
    }

    func point(at offset: Double) -> Point {
        for i in 1..<points.count where cumulative[i] >= offset {
            let span = cumulative[i] - cumulative[i - 1]
            let t = span > 0 ? (offset - cumulative[i - 1]) / span : 0
            return points[i - 1].lerp(points[i], t)
        }
        return points[points.count - 1]
    }
}
