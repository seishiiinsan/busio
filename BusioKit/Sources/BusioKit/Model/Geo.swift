import Foundation

public struct Coordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude != 0 && longitude != 0 && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    /// Distance orthodromique en mètres.
    public func distance(to other: Coordinate) -> Double {
        let r = 6_371_000.0
        let φ1 = latitude * .pi / 180, φ2 = other.latitude * .pi / 180
        let dφ = (other.latitude - latitude) * .pi / 180
        let dλ = (other.longitude - longitude) * .pi / 180
        let a = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    public static func centroid(of coordinates: [Coordinate]) -> Coordinate? {
        guard !coordinates.isEmpty else { return nil }
        let n = Double(coordinates.count)
        return Coordinate(
            latitude: coordinates.map(\.latitude).reduce(0, +) / n,
            longitude: coordinates.map(\.longitude).reduce(0, +) / n
        )
    }
}

/// Couleur sRGB issue des données (#RRGGBB).
public struct RGBColor: Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        red = Double((v >> 16) & 0xFF) / 255
        green = Double((v >> 8) & 0xFF) / 255
        blue = Double(v & 0xFF) / 255
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }

    /// Luminance relative (WCAG).
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    public static let black = RGBColor(red: 0, green: 0, blue: 0)
    public static let white = RGBColor(red: 1, green: 1, blue: 1)
    public static let neutral = RGBColor(red: 0.45, green: 0.47, blue: 0.5)
}
