import Foundation

private enum CalendarEventVerificationFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

private actor RecordingCalendarEventService: CalendarEventCreating {
    private var requests: [CalendarEventCreationRequest] = []
    private let receipt: CalendarEventCreationReceipt

    init(receipt: CalendarEventCreationReceipt) {
        self.receipt = receipt
    }

    func createEvent(
        _ request: CalendarEventCreationRequest
    ) async throws -> CalendarEventCreationReceipt {
        requests.append(request)
        return receipt
    }

    func snapshot() -> [CalendarEventCreationRequest] {
        requests
    }
}

@main
private struct CalendarEventVerification {
    private static var checks = 0

    static func main() async throws {
        let timedStart = Date(timeIntervalSince1970: 2_000_000_000)
        let timedEnd = timedStart.addingTimeInterval(90 * 60)
        let timed = try CalendarEventCreationRequest(
            title: "Dinner with Maya",
            startAt: timedStart,
            endAt: timedEnd,
            calendarName: "Personal",
            location: "River North",
            notes: "Meet by the entrance.\nBring the tickets.",
            idempotencyKey: "voice-calendar-session.turn-1"
        )
        try expect(
            timed.title == "Dinner with Maya"
                && timed.startAt == timedStart
                && timed.endAt == timedEnd
                && !timed.isAllDay
                && timed.calendarName == "Personal"
                && timed.location == "River North"
                && timed.notes?.contains("\n") == true
                && timed.idempotencyKey == "voice-calendar-session.turn-1",
            "a valid timed Calendar request did not preserve its exact typed effect"
        )

        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = .current
        let allDayStart = localCalendar.startOfDay(
            for: Date(timeIntervalSince1970: 2_000_100_000)
        )
        guard let allDayEnd = localCalendar.date(
            byAdding: .day,
            value: 1,
            to: allDayStart
        ) else {
            throw CalendarEventVerificationFailure.failed(
                "the verifier could not construct a local all-day interval"
            )
        }
        let allDay = try CalendarEventCreationRequest(
            title: "Cubs game",
            startAt: allDayStart,
            endAt: allDayEnd,
            isAllDay: true,
            idempotencyKey: "voice-calendar-session.turn-2"
        )
        try expect(
            allDay.isAllDay
                && allDay.startAt == allDayStart
                && allDay.endAt == allDayEnd
                && allDay.calendarName == nil
                && allDay.location == nil
                && allDay.notes == nil,
            "a valid local all-day Calendar request was not represented exactly"
        )

        try expectError(.invalidTitle) {
            _ = try CalendarEventCreationRequest(
                title: "",
                startAt: timedStart,
                endAt: timedEnd
            )
        }
        try expectError(.invalidTitle) {
            _ = try CalendarEventCreationRequest(
                title: " padded",
                startAt: timedStart,
                endAt: timedEnd
            )
        }
        try expectError(.invalidTitle) {
            _ = try CalendarEventCreationRequest(
                title: "bad\nname",
                startAt: timedStart,
                endAt: timedEnd
            )
        }
        try expectError(.invalidStartDate) {
            _ = try CalendarEventCreationRequest(
                title: "Bad start",
                startAt: Date(timeIntervalSince1970: .infinity),
                endAt: timedEnd
            )
        }
        try expectError(.invalidEndDate) {
            _ = try CalendarEventCreationRequest(
                title: "Bad end",
                startAt: timedStart,
                endAt: Date(timeIntervalSince1970: .nan)
            )
        }
        try expectError(.invalidInterval) {
            _ = try CalendarEventCreationRequest(
                title: "Backwards",
                startAt: timedStart,
                endAt: timedStart
            )
        }
        try expectError(.invalidInterval) {
            _ = try CalendarEventCreationRequest(
                title: "Too long",
                startAt: timedStart,
                endAt: timedStart.addingTimeInterval(
                    CalendarEventCreationRequest.maximumDuration + 1
                )
            )
        }
        try expectError(.invalidAllDayBoundary) {
            _ = try CalendarEventCreationRequest(
                title: "Not midnight",
                startAt: allDayStart.addingTimeInterval(60),
                endAt: allDayEnd,
                isAllDay: true
            )
        }
        try expectError(.invalidCalendar) {
            _ = try CalendarEventCreationRequest(
                title: "Bad calendar",
                startAt: timedStart,
                endAt: timedEnd,
                calendarName: " "
            )
        }
        try expectError(.invalidLocation) {
            _ = try CalendarEventCreationRequest(
                title: "Bad location",
                startAt: timedStart,
                endAt: timedEnd,
                location: "Line one\nLine two"
            )
        }
        try expectError(.invalidNotes) {
            _ = try CalendarEventCreationRequest(
                title: "Bad notes",
                startAt: timedStart,
                endAt: timedEnd,
                notes: "bad\u{0000}notes"
            )
        }
        try expectError(.invalidIdempotencyKey) {
            _ = try CalendarEventCreationRequest(
                title: "Bad key",
                startAt: timedStart,
                endAt: timedEnd,
                idempotencyKey: "contains spaces"
            )
        }

        let receipt = CalendarEventCreationReceipt(
            eventIdentifier: "event-opaque-1",
            calendarIdentifier: "calendar-opaque-1",
            calendarName: "Personal",
            title: timed.title,
            startAt: timed.startAt,
            endAt: timed.endAt,
            isAllDay: timed.isAllDay,
            location: timed.location,
            notes: timed.notes,
            verified: true
        )
        let recorder = RecordingCalendarEventService(receipt: receipt)
        let service: any CalendarEventCreating = recorder
        let returned = try await service.createEvent(timed)
        let recorded = await recorder.snapshot()
        try expect(
            returned == receipt
                && returned.verified
                && recorded == [timed],
            "the Calendar service protocol could not be replaced by a deterministic recorder"
        )

        let encodedReceipt = try JSONEncoder().encode(receipt)
        let decodedReceipt = try JSONDecoder().decode(
            CalendarEventCreationReceipt.self,
            from: encodedReceipt
        )
        try expect(
            decodedReceipt == receipt,
            "the verified Calendar receipt did not survive its private Codable boundary"
        )

        let rawCodes = CalendarEventErrorCode.allCases.map(\.rawValue)
        try expect(
            Set(rawCodes).count == rawCodes.count
                && rawCodes.allSatisfy({
                    !$0.isEmpty
                        && $0 == $0.lowercased()
                        && !$0.contains(" ")
                }),
            "Calendar failures do not have unique stable safe codes"
        )

        let representativeErrors: [CalendarEventServiceError] = [
            .accessRestricted,
            .accessDenied,
            .fullAccessRequired,
            .authorizationFailed,
            .noWritableCalendar,
            .requestedCalendarNotFound,
            .requestedCalendarAmbiguous,
            .saveFailed,
            .savedEventMissingIdentifier,
            .savedEventCouldNotBeVerified,
        ]
        try expect(
            representativeErrors.allSatisfy({ error in
                error.errorDescription?.isEmpty == false
                    && CalendarEventErrorCode.allCases.contains(error.code)
            }),
            "a Calendar service failure can escape without a bounded message and code"
        )

        let infoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(
            from: infoData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw CalendarEventVerificationFailure.failed(
                "Resources/Info.plist could not be decoded"
            )
        }
        let permissionText = info["NSCalendarsFullAccessUsageDescription"] as? String
        try expect(
            permissionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            "the app bundle lacks Calendar full-access permission text"
        )

        let result: [String: Any] = [
            "checks": checks,
            "mockable_service": true,
            "request_validation": "strict",
            "receipt_verification_boundary": true,
            "safe_error_codes": rawCodes.count,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys]
        )
        print(String(decoding: data, as: UTF8.self))
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw CalendarEventVerificationFailure.failed(message)
        }
        checks += 1
    }

    private static func expectError(
        _ code: CalendarEventErrorCode,
        _ body: () throws -> Void
    ) throws {
        do {
            try body()
        } catch let error as CalendarEventServiceError {
            guard error.code == code else {
                throw CalendarEventVerificationFailure.failed(
                    "expected Calendar error \(code.rawValue), received \(error.code.rawValue)"
                )
            }
            checks += 1
            return
        } catch {
            throw CalendarEventVerificationFailure.failed(
                "expected Calendar error \(code.rawValue), received an unrelated error"
            )
        }
        throw CalendarEventVerificationFailure.failed(
            "expected Calendar error \(code.rawValue), but the request was accepted"
        )
    }
}
