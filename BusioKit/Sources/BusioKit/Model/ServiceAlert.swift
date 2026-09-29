import Foundation

/// Message d'information voyageurs (travaux, grève, déviation…).
public struct ServiceAlert: Identifiable, Hashable, Codable, Sendable {
    public enum Severity: Int, Codable, Sendable, Comparable {
        case info = 0, warning = 1, severe = 2
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let id: String
    /// Lignes concernées (vide = tout le réseau).
    public let lineIDs: [String]
    public let title: String
    public let message: String
    public let severity: Severity
    public let start: Date?
    public let end: Date?

    public init(id: String, lineIDs: [String], title: String, message: String, severity: Severity, start: Date?, end: Date?) {
        self.id = id
        self.lineIDs = lineIDs
        self.title = title
        self.message = message
        self.severity = severity
        self.start = start
        self.end = end
    }

    public func isActive(at date: Date) -> Bool {
        if let start, date < start { return false }
        if let end, date > end { return false }
        return true
    }

    public func concerns(lineID: String) -> Bool { lineIDs.isEmpty || lineIDs.contains(lineID) }
}
