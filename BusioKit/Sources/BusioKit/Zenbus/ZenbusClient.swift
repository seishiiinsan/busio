import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftProtobuf

public enum TransitError: Error, LocalizedError, Sendable {
    case http(status: Int, url: String)
    case emptyResponse(url: String)
    case decoding(String)
    case noData

    public var errorDescription: String? {
        switch self {
        case .http(let status, _): "Serveur indisponible (HTTP \(status))"
        case .emptyResponse: "Réponse vide du serveur"
        case .decoding(let detail): "Données illisibles (\(detail))"
        case .noData: "Aucune donnée disponible"
        }
    }
}

/// Client de l'API publique utilisée par l'app et le site Zenbus.
public struct ZenbusClient: Sendable {
    public static let defaultAlias = "castres"

    public let alias: String
    public let baseURL: URL
    private let session: URLSession

    public init(alias: String = ZenbusClient.defaultAlias, baseURL: URL = URL(string: "https://zenbus.net")!, session: URLSession = .shared) {
        self.alias = alias
        self.baseURL = baseURL
        self.session = session
    }

    public var staticURL: URL {
        url(path: "/publicapp/static-data", query: [URLQueryItem(name: "alias", value: alias)])
    }

    /// `itinerary = nil` renvoie tout le réseau (≈ 350 Ko).
    public func pollURL(itinerary: String?) -> URL {
        var query = [URLQueryItem(name: "alias", value: alias)]
        if let itinerary { query.append(URLQueryItem(name: "itinerary", value: itinerary)) }
        return url(path: "/publicapp/poll", query: query)
    }

    /// Page web Zenbus équivalente (pour comparer en cas de doute).
    public func webURL(lineID: String? = nil, itineraryID: String? = nil, stopID: String? = nil) -> URL {
        var query: [URLQueryItem] = []
        if let lineID { query.append(URLQueryItem(name: "line", value: lineID)) }
        if let stopID { query.append(URLQueryItem(name: "stop", value: stopID)) }
        if let itineraryID { query.append(URLQueryItem(name: "itinerary", value: itineraryID)) }
        return url(path: "/publicapp/web/\(alias)", query: query)
    }

    public func fetchStaticData() async throws -> Data {
        try await fetch(staticURL, timeout: 20)
    }

    public func poll(itinerary: String?) async throws -> ZenbusRealtime_LiveMessage {
        try Self.decodeLive(try await pollData(itinerary: itinerary))
    }

    /// Réponse brute (pour la mise en cache disque).
    public func pollData(itinerary: String?) async throws -> Data {
        // Un message proto3 sans contenu est encodé en 0 octet : réponse vide valide.
        try await fetch(pollURL(itinerary: itinerary), timeout: itinerary == nil ? 20 : 10, allowEmpty: true)
    }

    public static func decodeStatic(_ data: Data) throws -> ZenbusRealtime_StaticMessage {
        do {
            let message = try ZenbusRealtime_StaticMessage(serializedBytes: data)
            guard !message.line.isEmpty, !message.stop.isEmpty else { throw TransitError.decoding("réseau vide") }
            return message
        } catch let error as TransitError {
            throw error
        } catch {
            throw TransitError.decoding(String(describing: error))
        }
    }

    public static func decodeLive(_ data: Data) throws -> ZenbusRealtime_LiveMessage {
        do {
            return try ZenbusRealtime_LiveMessage(serializedBytes: data)
        } catch {
            throw TransitError.decoding(String(describing: error))
        }
    }

    private func url(path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    private func fetch(_ url: URL, timeout: TimeInterval, allowEmpty: Bool = false) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/x-protobuf, application/protobuf, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TransitError.http(status: http.statusCode, url: url.absoluteString)
        }
        guard allowEmpty || !data.isEmpty else { throw TransitError.emptyResponse(url: url.absoluteString) }
        return data
    }
}
