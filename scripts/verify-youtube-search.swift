import Foundation

private enum YouTubeSearchVerificationFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

private actor YouTubeSearchRecorder {
    enum Observation: Sendable {
        case requestedURL
        case url(URL)
        case unavailable
        case failure
    }

    private var openedURLs: [URL] = []
    private var verifiedURLs: [URL] = []
    private var openAccepted = true
    private var observation: Observation = .requestedURL

    func configure(openAccepted: Bool = true, observation: Observation = .requestedURL) {
        self.openAccepted = openAccepted
        self.observation = observation
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return openAccepted
    }

    func verify(_ requestedURL: URL) throws -> URL? {
        verifiedURLs.append(requestedURL)
        switch observation {
        case .requestedURL: return requestedURL
        case .url(let url): return url
        case .unavailable: return nil
        case .failure: throw YouTubeSearchVerificationFailure.failed("observer failed")
        }
    }

    func snapshot() -> (opened: [URL], verified: [URL]) {
        (openedURLs, verifiedURLs)
    }
}

@main
private struct VerifyYouTubeSearch {
    static func main() async throws {
        try await verifiesExactTypedSearchWithoutPhraseParsing()
        try await rejectsInvalidQueriesBeforeOpening()
        try await requiresTheOpenRequestToBeAccepted()
        try await requiresAVisiblePostcondition()
        try await rejectsMismatchedVisiblePages()
        try await mapsObserverFailureWithoutClaimingSuccess()
        print("Aurora typed YouTube search verification passed")
    }

    private static func verifiesExactTypedSearchWithoutPhraseParsing() async throws {
        let recorder = YouTubeSearchRecorder()
        let service = makeService(recorder)
        let query = "please search YouTube for Alex & Aurora = future? #1"
        let receipt = try await service.searchYouTube(
            YouTubeSearchRequest(query: query)
        )

        try expect(receipt.verified, "a matching visible results page was not verified")
        try expect(receipt.query == query, "the capability reinterpreted the typed query")
        try expect(receipt.requestedURL.scheme == "https", "search did not use HTTPS")
        try expect(receipt.requestedURL.host == "www.youtube.com", "search used the wrong host")
        try expect(receipt.requestedURL.path == "/results", "search used the wrong path")
        let items = URLComponents(
            url: receipt.requestedURL,
            resolvingAgainstBaseURL: false
        )?.queryItems
        try expect(
            items == [URLQueryItem(name: "search_query", value: query)],
            "reserved characters or the exact query were not preserved"
        )
        let snapshot = await recorder.snapshot()
        try expect(
            snapshot.opened == [receipt.requestedURL]
                && snapshot.verified == [receipt.requestedURL],
            "the typed route did not open and verify exactly one URL"
        )
    }

    private static func rejectsInvalidQueriesBeforeOpening() async throws {
        let invalidQueries = [
            "",
            " ",
            " leading",
            "trailing ",
            "two\nlines",
            "nul\u{0000}byte",
            String(repeating: "x", count: YouTubeSearchService.maximumQueryCharacters + 1),
            String(repeating: "🟣", count: 301),
        ]

        for query in invalidQueries {
            let recorder = YouTubeSearchRecorder()
            let service = makeService(recorder)
            do {
                _ = try await service.searchYouTube(YouTubeSearchRequest(query: query))
                throw YouTubeSearchVerificationFailure.failed(
                    "an invalid query reached execution"
                )
            } catch YouTubeSearchServiceError.invalidQuery {
                // Expected.
            }
            let snapshot = await recorder.snapshot()
            try expect(
                snapshot.opened.isEmpty && snapshot.verified.isEmpty,
                "an invalid query reached an external boundary"
            )
        }
    }

    private static func requiresTheOpenRequestToBeAccepted() async throws {
        let recorder = YouTubeSearchRecorder()
        await recorder.configure(openAccepted: false)
        let service = makeService(recorder)
        do {
            _ = try await service.searchYouTube(YouTubeSearchRequest(query: "lofi"))
            throw YouTubeSearchVerificationFailure.failed("a rejected open claimed success")
        } catch YouTubeSearchServiceError.openRejected {
            // Expected.
        }
        let snapshot = await recorder.snapshot()
        try expect(
            snapshot.opened.count == 1 && snapshot.verified.isEmpty,
            "postcondition inspection ran after macOS rejected the open"
        )
    }

    private static func requiresAVisiblePostcondition() async throws {
        let recorder = YouTubeSearchRecorder()
        await recorder.configure(observation: .unavailable)
        let service = makeService(recorder)
        do {
            _ = try await service.searchYouTube(YouTubeSearchRequest(query: "lofi"))
            throw YouTubeSearchVerificationFailure.failed("a missing visible URL claimed success")
        } catch YouTubeSearchServiceError.postconditionUnavailable {
            // Expected.
        }
    }

    private static func rejectsMismatchedVisiblePages() async throws {
        let query = "lofi & jazz"
        let mismatches = [
            "http://www.youtube.com/results?search_query=lofi%20%26%20jazz",
            "https://www.youtube.com.evil.test/results?search_query=lofi%20%26%20jazz",
            "https://m.youtube.com/results?search_query=lofi%20%26%20jazz",
            "https://www.youtube.com/watch?search_query=lofi%20%26%20jazz",
            "https://www.youtube.com/results?search_query=different",
            "https://www.youtube.com/results?search_query=lofi%20%26%20jazz&sp=CAI",
            "https://www.youtube.com/results?search_query=lofi%20%26%20jazz&search_query=other",
            "https://user@www.youtube.com/results?search_query=lofi%20%26%20jazz",
            "https://www.youtube.com:443/results?search_query=lofi%20%26%20jazz",
            "https://www.youtube.com/results?search_query=lofi%20%26%20jazz#watch",
        ]

        for text in mismatches {
            guard let url = URL(string: text) else {
                throw YouTubeSearchVerificationFailure.failed("invalid verifier fixture")
            }
            let recorder = YouTubeSearchRecorder()
            await recorder.configure(observation: .url(url))
            let service = makeService(recorder)
            do {
                _ = try await service.searchYouTube(YouTubeSearchRequest(query: query))
                throw YouTubeSearchVerificationFailure.failed(
                    "a mismatched visible page claimed success: \(text)"
                )
            } catch YouTubeSearchServiceError.postconditionMismatch {
                // Expected.
            }
        }

        let canonicalBareHost = URL(
            string: "https://youtube.com/results?search_query=lofi%20%26%20jazz"
        )!
        let recorder = YouTubeSearchRecorder()
        await recorder.configure(observation: .url(canonicalBareHost))
        let receipt = try await makeService(recorder).searchYouTube(
            YouTubeSearchRequest(query: query)
        )
        try expect(receipt.verified, "the canonical bare YouTube host was rejected")
    }

    private static func mapsObserverFailureWithoutClaimingSuccess() async throws {
        let recorder = YouTubeSearchRecorder()
        await recorder.configure(observation: .failure)
        let service = makeService(recorder)
        do {
            _ = try await service.searchYouTube(YouTubeSearchRequest(query: "lofi"))
            throw YouTubeSearchVerificationFailure.failed("an observer failure claimed success")
        } catch YouTubeSearchServiceError.postconditionFailed {
            // Expected.
        }
    }

    private static func makeService(
        _ recorder: YouTubeSearchRecorder
    ) -> YouTubeSearchService {
        YouTubeSearchService(
            openHandler: { url in await recorder.open(url) },
            postconditionVerifier: { url in try await recorder.verify(url) }
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw YouTubeSearchVerificationFailure.failed(message)
        }
    }
}
