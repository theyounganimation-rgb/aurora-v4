@preconcurrency import EventKit
import Foundation

/// Stable, non-sensitive reasons a native Calendar request can fail. Raw
/// EventKit and operating-system errors intentionally never cross this
/// boundary.
public enum CalendarEventErrorCode: String, Codable, Sendable, Equatable, CaseIterable {
    case invalidTitle = "invalid_title"
    case invalidStartDate = "invalid_start_date"
    case invalidEndDate = "invalid_end_date"
    case invalidInterval = "invalid_interval"
    case invalidAllDayBoundary = "invalid_all_day_boundary"
    case invalidCalendar = "invalid_calendar"
    case invalidLocation = "invalid_location"
    case invalidNotes = "invalid_notes"
    case invalidIdempotencyKey = "invalid_idempotency_key"
    case idempotencyConflict = "idempotency_conflict"
    case accessRestricted = "access_restricted"
    case accessDenied = "access_denied"
    case fullAccessRequired = "full_access_required"
    case authorizationFailed = "authorization_failed"
    case noWritableCalendar = "no_writable_calendar"
    case requestedCalendarNotFound = "requested_calendar_not_found"
    case requestedCalendarAmbiguous = "requested_calendar_ambiguous"
    case saveFailed = "save_failed"
    case savedEventMissingIdentifier = "saved_event_missing_identifier"
    case savedEventCouldNotBeVerified = "saved_event_could_not_be_verified"
}

public enum CalendarEventServiceError: LocalizedError, Sendable, Equatable {
    case invalidTitle
    case invalidStartDate
    case invalidEndDate
    case invalidInterval
    case invalidAllDayBoundary
    case invalidCalendar
    case invalidLocation
    case invalidNotes
    case invalidIdempotencyKey
    case idempotencyConflict
    case accessRestricted
    case accessDenied
    case fullAccessRequired
    case authorizationFailed
    case noWritableCalendar
    case requestedCalendarNotFound
    case requestedCalendarAmbiguous
    case saveFailed
    case savedEventMissingIdentifier
    case savedEventCouldNotBeVerified

    public var code: CalendarEventErrorCode {
        switch self {
        case .invalidTitle: return .invalidTitle
        case .invalidStartDate: return .invalidStartDate
        case .invalidEndDate: return .invalidEndDate
        case .invalidInterval: return .invalidInterval
        case .invalidAllDayBoundary: return .invalidAllDayBoundary
        case .invalidCalendar: return .invalidCalendar
        case .invalidLocation: return .invalidLocation
        case .invalidNotes: return .invalidNotes
        case .invalidIdempotencyKey: return .invalidIdempotencyKey
        case .idempotencyConflict: return .idempotencyConflict
        case .accessRestricted: return .accessRestricted
        case .accessDenied: return .accessDenied
        case .fullAccessRequired: return .fullAccessRequired
        case .authorizationFailed: return .authorizationFailed
        case .noWritableCalendar: return .noWritableCalendar
        case .requestedCalendarNotFound: return .requestedCalendarNotFound
        case .requestedCalendarAmbiguous: return .requestedCalendarAmbiguous
        case .saveFailed: return .saveFailed
        case .savedEventMissingIdentifier: return .savedEventMissingIdentifier
        case .savedEventCouldNotBeVerified: return .savedEventCouldNotBeVerified
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidTitle:
            return "The calendar event needs a valid, non-empty title."
        case .invalidStartDate:
            return "The calendar event start time is invalid."
        case .invalidEndDate:
            return "The calendar event end time is invalid."
        case .invalidInterval:
            return "The calendar event must end after it starts and stay within the supported duration."
        case .invalidAllDayBoundary:
            return "An all-day event must use local midnight boundaries and end on a later day."
        case .invalidCalendar:
            return "The requested calendar name is invalid."
        case .invalidLocation:
            return "The calendar event location is invalid."
        case .invalidNotes:
            return "The calendar event notes are invalid."
        case .invalidIdempotencyKey:
            return "The calendar request identifier is invalid."
        case .idempotencyConflict:
            return "That calendar request identifier was already used for a different event."
        case .accessRestricted:
            return "Calendar access is restricted on this Mac."
        case .accessDenied:
            return "Aurora needs Calendar access before she can create that event."
        case .fullAccessRequired:
            return "Aurora needs full Calendar access so she can verify the event she creates."
        case .authorizationFailed:
            return "macOS could not complete the Calendar permission request."
        case .noWritableCalendar:
            return "No writable calendar is available on this Mac."
        case .requestedCalendarNotFound:
            return "The requested writable calendar could not be found."
        case .requestedCalendarAmbiguous:
            return "The requested calendar name matches more than one writable calendar."
        case .saveFailed:
            return "Calendar could not save that event."
        case .savedEventMissingIdentifier, .savedEventCouldNotBeVerified:
            return "The event may have been saved, but Aurora could not verify it safely."
        }
    }
}

/// A completely resolved Calendar write. Natural-language interpretation is
/// intentionally outside this type: callers must supply the exact effect.
/// The throwing initializer is the only public construction boundary, so an
/// invalid or oversized request cannot reach EventKit.
public struct CalendarEventCreationRequest: Sendable, Equatable {
    public static let maximumTitleCharacters = 500
    public static let maximumCalendarCharacters = 500
    public static let maximumLocationCharacters = 2_000
    public static let maximumNotesCharacters = 12_000
    public static let maximumIdempotencyKeyCharacters = 128
    public static let maximumDuration: TimeInterval = 10 * 366 * 24 * 60 * 60

    public let title: String
    public let startAt: Date
    public let endAt: Date
    public let isAllDay: Bool
    public let calendarName: String?
    public let location: String?
    public let notes: String?
    public let idempotencyKey: String?

    public init(
        title: String,
        startAt: Date,
        endAt: Date,
        isAllDay: Bool = false,
        calendarName: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        idempotencyKey: String? = nil
    ) throws {
        try Self.validateSingleLine(
            title,
            maximumCharacters: Self.maximumTitleCharacters,
            failure: .invalidTitle
        )
        guard startAt.timeIntervalSince1970.isFinite else {
            throw CalendarEventServiceError.invalidStartDate
        }
        guard endAt.timeIntervalSince1970.isFinite else {
            throw CalendarEventServiceError.invalidEndDate
        }
        let duration = endAt.timeIntervalSince(startAt)
        guard duration.isFinite, duration > 0, duration <= Self.maximumDuration else {
            throw CalendarEventServiceError.invalidInterval
        }

        if isAllDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            guard Self.sameInstant(startAt, calendar.startOfDay(for: startAt)),
                  Self.sameInstant(endAt, calendar.startOfDay(for: endAt)),
                  let days = calendar.dateComponents(
                    [.day],
                    from: calendar.startOfDay(for: startAt),
                    to: calendar.startOfDay(for: endAt)
                  ).day,
                  days > 0 else {
                throw CalendarEventServiceError.invalidAllDayBoundary
            }
        }

        if let calendarName {
            try Self.validateSingleLine(
                calendarName,
                maximumCharacters: Self.maximumCalendarCharacters,
                failure: .invalidCalendar
            )
        }
        if let location {
            try Self.validateSingleLine(
                location,
                maximumCharacters: Self.maximumLocationCharacters,
                failure: .invalidLocation
            )
        }
        if let notes {
            try Self.validateNotes(notes)
        }
        if let idempotencyKey {
            try Self.validateIdempotencyKey(idempotencyKey)
        }

        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.isAllDay = isAllDay
        self.calendarName = calendarName
        self.location = location
        self.notes = notes
        self.idempotencyKey = idempotencyKey
    }

    private static func validateSingleLine(
        _ value: String,
        maximumCharacters: Int,
        failure: CalendarEventServiceError
    ) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= maximumCharacters,
              value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw failure
        }
    }

    private static func validateNotes(_ value: String) throws {
        guard !value.isEmpty,
              value.count <= maximumNotesCharacters,
              value.unicodeScalars.allSatisfy({ scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "\n"
                    || scalar == "\r"
                    || scalar == "\t"
              }) else {
            throw CalendarEventServiceError.invalidNotes
        }
    }

    private static func validateIdempotencyKey(_ value: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        guard !value.isEmpty,
              value.count <= maximumIdempotencyKeyCharacters,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CalendarEventServiceError.invalidIdempotencyKey
        }
    }

    fileprivate static func sameInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 0.001
    }
}

/// Proof emitted only after EventKit has saved the event and the same retained
/// store has fetched every requested field back successfully.
public struct CalendarEventCreationReceipt: Codable, Sendable, Equatable {
    public let eventIdentifier: String
    public let calendarIdentifier: String
    public let calendarName: String
    public let title: String
    public let startAt: Date
    public let endAt: Date
    public let isAllDay: Bool
    public let location: String?
    public let notes: String?
    public let verified: Bool

    public init(
        eventIdentifier: String,
        calendarIdentifier: String,
        calendarName: String,
        title: String,
        startAt: Date,
        endAt: Date,
        isAllDay: Bool,
        location: String?,
        notes: String?,
        verified: Bool
    ) {
        self.eventIdentifier = eventIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.calendarName = calendarName
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.verified = verified
    }
}

/// Injectable capability boundary used by the host coordinator. Focused tests
/// can substitute a recorder without touching a real Calendar database.
public protocol CalendarEventCreating: Sendable {
    func createEvent(
        _ request: CalendarEventCreationRequest
    ) async throws -> CalendarEventCreationReceipt
}

/// Native, serialized Calendar access. One EKEventStore is retained for the
/// service lifetime, as required for reliable permission and post-save reads.
public actor EventKitCalendarEventService: CalendarEventCreating {
    public nonisolated static let maximumCachedOutcomes = 128

    private enum CachedOutcome {
        case success(CalendarEventCreationReceipt)
        case postSaveFailure(CalendarEventServiceError)
    }

    private struct CacheEntry {
        let request: CalendarEventCreationRequest
        let outcome: CachedOutcome
    }

    private let eventStore: EKEventStore
    private var outcomesByIdempotencyKey: [String: CacheEntry] = [:]
    private var outcomeInsertionOrder: [String] = []

    public init() {
        eventStore = EKEventStore()
    }

    public func createEvent(
        _ request: CalendarEventCreationRequest
    ) async throws -> CalendarEventCreationReceipt {
        if let cached = try cachedOutcome(for: request) {
            return try Self.resolve(cached)
        }

        try await ensureFullEventAccess()

        // Permission acquisition suspends this actor. Recheck idempotency after
        // resumption so concurrent retries cannot both create the event.
        if let cached = try cachedOutcome(for: request) {
            return try Self.resolve(cached)
        }

        let calendar = try resolveWritableCalendar(named: request.calendarName)
        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = request.title
        event.startDate = request.startAt
        event.endDate = request.endAt
        event.isAllDay = request.isAllDay
        event.location = request.location
        event.notes = request.notes
        if !request.isAllDay {
            event.timeZone = .current
        }

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarEventServiceError.saveFailed
        }

        guard let identifier = Self.validIdentifier(event.calendarItemIdentifier) else {
            let failure = CalendarEventServiceError.savedEventMissingIdentifier
            remember(.postSaveFailure(failure), for: request)
            throw failure
        }

        guard let fetched = eventStore.calendarItem(withIdentifier: identifier) as? EKEvent,
              Self.event(fetched, matches: request, calendar: calendar) else {
            let failure = CalendarEventServiceError.savedEventCouldNotBeVerified
            remember(.postSaveFailure(failure), for: request)
            throw failure
        }

        let receipt = CalendarEventCreationReceipt(
            eventIdentifier: identifier,
            calendarIdentifier: calendar.calendarIdentifier,
            calendarName: calendar.title,
            title: request.title,
            startAt: request.startAt,
            endAt: request.endAt,
            isAllDay: request.isAllDay,
            location: request.location,
            notes: request.notes,
            verified: true
        )
        remember(.success(receipt), for: request)
        return receipt
    }

    private func ensureFullEventAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted: Bool
            do {
                granted = try await eventStore.requestFullAccessToEvents()
            } catch {
                throw CalendarEventServiceError.authorizationFailed
            }
            guard granted else {
                throw CalendarEventServiceError.accessDenied
            }
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                throw CalendarEventServiceError.fullAccessRequired
            }
        case .restricted:
            throw CalendarEventServiceError.accessRestricted
        case .denied:
            throw CalendarEventServiceError.accessDenied
        case .writeOnly:
            throw CalendarEventServiceError.fullAccessRequired
        @unknown default:
            throw CalendarEventServiceError.fullAccessRequired
        }
    }

    private func resolveWritableCalendar(named requestedName: String?) throws -> EKCalendar {
        let writable = eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
        let defaultCalendar = eventStore.defaultCalendarForNewEvents

        guard let requestedName else {
            if let defaultCalendar, defaultCalendar.allowsContentModifications {
                return defaultCalendar
            }
            guard let fallback = writable.sorted(by: {
                $0.calendarIdentifier < $1.calendarIdentifier
            }).first else {
                throw CalendarEventServiceError.noWritableCalendar
            }
            return fallback
        }

        let matches = writable.filter {
            $0.title.compare(requestedName, options: [.caseInsensitive]) == .orderedSame
        }
        if let defaultCalendar,
           matches.contains(where: {
            $0.calendarIdentifier == defaultCalendar.calendarIdentifier
           }) {
            return defaultCalendar
        }
        guard !matches.isEmpty else {
            throw CalendarEventServiceError.requestedCalendarNotFound
        }
        guard matches.count == 1, let match = matches.first else {
            throw CalendarEventServiceError.requestedCalendarAmbiguous
        }
        return match
    }

    private func cachedOutcome(
        for request: CalendarEventCreationRequest
    ) throws -> CachedOutcome? {
        guard let key = request.idempotencyKey,
              let entry = outcomesByIdempotencyKey[key] else {
            return nil
        }
        guard entry.request == request else {
            throw CalendarEventServiceError.idempotencyConflict
        }
        return entry.outcome
    }

    private func remember(
        _ outcome: CachedOutcome,
        for request: CalendarEventCreationRequest
    ) {
        guard let key = request.idempotencyKey else { return }
        if outcomesByIdempotencyKey[key] == nil {
            outcomeInsertionOrder.append(key)
        }
        outcomesByIdempotencyKey[key] = CacheEntry(request: request, outcome: outcome)

        while outcomeInsertionOrder.count > Self.maximumCachedOutcomes {
            let oldest = outcomeInsertionOrder.removeFirst()
            outcomesByIdempotencyKey.removeValue(forKey: oldest)
        }
    }

    private static func resolve(
        _ outcome: CachedOutcome
    ) throws -> CalendarEventCreationReceipt {
        switch outcome {
        case .success(let receipt):
            return receipt
        case .postSaveFailure(let error):
            throw error
        }
    }

    private static func validIdentifier(_ value: String?) -> String? {
        guard let value,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 2_048,
              value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return value
    }

    private static func event(
        _ event: EKEvent,
        matches request: CalendarEventCreationRequest,
        calendar: EKCalendar
    ) -> Bool {
        event.title == request.title
            && abs(event.startDate.timeIntervalSince(request.startAt)) < 1
            && abs(event.endDate.timeIntervalSince(request.endAt)) < 1
            && event.isAllDay == request.isAllDay
            && event.calendar.calendarIdentifier == calendar.calendarIdentifier
            && event.location == request.location
            && event.notes == request.notes
    }
}
