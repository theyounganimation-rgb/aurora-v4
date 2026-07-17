import Foundation

/// A fully resolved YouTube search. The query is already understood by
/// Realtime; this capability never tries to reinterpret natural language.
public struct YouTubeSearchRequest: Sendable, Equatable {
    public let query: String

    public init(query: String) {
        self.query = query
    }
}

/// Proof returned only after the requested results URL was opened and the
/// caller's trusted browser observer reported that exact search as visible.
public struct YouTubeSearchReceipt: Codable, Sendable, Equatable {
    public let query: String
    public let requestedURL: URL
    public let visibleURL: URL
    public let verified: Bool

    public init(
        query: String,
        requestedURL: URL,
        visibleURL: URL,
        verified: Bool
    ) {
        self.query = query
        self.requestedURL = requestedURL
        self.visibleURL = visibleURL
        self.verified = verified
    }
}

/// The narrow boundary the capability broker can depend on without knowing
/// how a browser is opened or how its visible location is observed.
public protocol YouTubeSearching: Sendable {
    func searchYouTube(
        _ request: YouTubeSearchRequest
    ) async throws -> YouTubeSearchReceipt
}

public typealias YouTubeSearchOpenHandler = @Sendable (URL) async -> Bool
public typealias YouTubeSearchPostconditionVerifier = @Sendable (URL) async throws -> URL?

public enum YouTubeSearchServiceError: LocalizedError, Sendable, Equatable {
    case invalidQuery
    case couldNotConstructURL
    case openRejected
    case postconditionFailed
    case postconditionUnavailable
    case postconditionMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "The YouTube search needs one short, non-empty query."
        case .couldNotConstructURL:
            return "Aurora could not construct the YouTube search URL."
        case .openRejected:
            return "macOS did not accept the YouTube search request."
        case .postconditionFailed:
            return "Aurora could not inspect the browser after opening the YouTube search."
        case .postconditionUnavailable:
            return "The browser did not expose a visible page for the YouTube search."
        case .postconditionMismatch:
            return "The visible browser page did not match the requested YouTube search."
        }
    }
}

/// Typed, phrase-free YouTube results navigation. Video selection and
/// playback deliberately remain outside this capability and can fall through
/// to Aurora's broader Osiris worker.
public actor YouTubeSearchService: YouTubeSearching {
    public nonisolated static let maximumQueryCharacters = 300
    public nonisolated static let maximumQueryUTF8Bytes = 1_200

    private static let trustedVisibleHosts: Set<String> = [
        "youtube.com",
        "www.youtube.com",
    ]

    private let openHandler: YouTubeSearchOpenHandler
    private let postconditionVerifier: YouTubeSearchPostconditionVerifier

    public init(
        openHandler: @escaping YouTubeSearchOpenHandler,
        postconditionVerifier: @escaping YouTubeSearchPostconditionVerifier
    ) {
        self.openHandler = openHandler
        self.postconditionVerifier = postconditionVerifier
    }

    public func searchYouTube(
        _ request: YouTubeSearchRequest
    ) async throws -> YouTubeSearchReceipt {
        let query = try Self.validatedQuery(request.query)
        let requestedURL = try Self.makeResultsURL(query: query)

        guard await openHandler(requestedURL) else {
            throw YouTubeSearchServiceError.openRejected
        }

        let visibleURL: URL?
        do {
            visibleURL = try await postconditionVerifier(requestedURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw YouTubeSearchServiceError.postconditionFailed
        }
        guard let visibleURL else {
            throw YouTubeSearchServiceError.postconditionUnavailable
        }
        guard Self.visibleResultsURL(visibleURL, matchesQuery: query) else {
            throw YouTubeSearchServiceError.postconditionMismatch
        }

        return YouTubeSearchReceipt(
            query: query,
            requestedURL: requestedURL,
            visibleURL: visibleURL,
            verified: true
        )
    }

    private nonisolated static func validatedQuery(_ value: String) throws -> String {
        guard
            !value.isEmpty,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            value.count <= maximumQueryCharacters,
            value.utf8.count <= maximumQueryUTF8Bytes,
            value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw YouTubeSearchServiceError.invalidQuery
        }
        return value
    }

    private nonisolated static func makeResultsURL(query: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/results"
        components.queryItems = [
            URLQueryItem(name: "search_query", value: query),
        ]
        guard let url = components.url else {
            throw YouTubeSearchServiceError.couldNotConstructURL
        }
        return url
    }

    /// Verification is intentionally stricter than a host suffix check. It
    /// accepts only YouTube's two canonical hosts, HTTPS, the results path,
    /// and one exact search_query item with no unrequested filters.
    nonisolated static func visibleResultsURL(
        _ url: URL,
        matchesQuery query: String
    ) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              trustedVisibleHosts.contains(host),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path == "/results",
              components.fragment == nil,
              let items = components.queryItems,
              items.count == 1,
              items[0].name == "search_query",
              items[0].value == query else {
            return false
        }
        return true
    }
}
