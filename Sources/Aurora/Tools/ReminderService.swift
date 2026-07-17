@preconcurrency import EventKit
import Foundation

/// A fully specified reminder write. The caller supplies an idempotency key so
/// a retried Realtime function call cannot create the same reminder twice
/// during this Aurora process.
public struct ReminderCreationRequest: Sendable, Equatable {
    public let title: String
    public let dueAt: Date
    public let idempotencyKey: String

    public init(title: String, dueAt: Date, idempotencyKey: String) {
        self.title = title
        self.dueAt = dueAt
        self.idempotencyKey = idempotencyKey
    }
}

/// Proof returned only after EventKit saved the reminder and Aurora fetched it
/// back from the same long-lived event store with the requested title and due
/// date intact.
public struct ReminderCreationReceipt: Codable, Sendable, Equatable {
    public let reminderIdentifier: String
    public let title: String
    public let dueAt: Date
    public let verified: Bool

    public init(
        reminderIdentifier: String,
        title: String,
        dueAt: Date,
        verified: Bool
    ) {
        self.reminderIdentifier = reminderIdentifier
        self.title = title
        self.dueAt = dueAt
        self.verified = verified
    }
}

/// The narrow injectable boundary used by Aurora's tool coordinator. Tests do
/// not need access to EventKit or the user's real reminders database.
public protocol ReminderCreating: Sendable {
    func createReminder(_ request: ReminderCreationRequest) async throws -> ReminderCreationReceipt
}

public enum ReminderServiceError: LocalizedError, Sendable, Equatable {
    case invalidTitle
    case invalidDueDate
    case invalidIdempotencyKey
    case idempotencyConflict
    case accessRestricted
    case accessDenied
    case fullAccessRequired
    case authorizationFailed(code: Int?)
    case noDefaultCalendar
    case saveFailed(code: Int?)
    case savedReminderMissingIdentifier
    case savedReminderCouldNotBeVerified

    public var errorDescription: String? {
        switch self {
        case .invalidTitle:
            return "The reminder needs a short, non-empty title."
        case .invalidDueDate:
            return "The reminder due time was not valid."
        case .invalidIdempotencyKey:
            return "The reminder request identifier was not valid."
        case .idempotencyConflict:
            return "That reminder request identifier was already used for a different reminder."
        case .accessRestricted:
            return "Reminders access is restricted on this Mac."
        case .accessDenied:
            return "Aurora needs Reminders access before she can create that reminder."
        case .fullAccessRequired:
            return "Aurora needs full Reminders access so she can verify what she created."
        case .authorizationFailed:
            return "macOS could not complete the Reminders permission request."
        case .noDefaultCalendar:
            return "No default reminders list is available on this Mac."
        case .saveFailed:
            return "Reminders could not save that reminder."
        case .savedReminderMissingIdentifier, .savedReminderCouldNotBeVerified:
            return "The reminder was saved, but Aurora could not verify it safely."
        }
    }
}

/// Direct native Apple Reminders access. A single EKEventStore is intentionally
/// retained for the service lifetime, as EventKit recommends, and all access
/// is serialized by this actor.
public actor EventKitReminderService: ReminderCreating {
    public nonisolated static let maximumTitleCharacters = 500
    public nonisolated static let maximumIdempotencyKeyCharacters = 128
    public nonisolated static let maximumCachedOutcomes = 128

    private struct ValidatedRequest: Equatable {
        let title: String
        let dueAt: Date
        let idempotencyKey: String
    }

    private enum CachedOutcome {
        case success(ReminderCreationReceipt)
        case postSaveFailure(ReminderServiceError)
    }

    private struct CacheEntry {
        let request: ValidatedRequest
        let outcome: CachedOutcome
    }

    private let eventStore: EKEventStore
    private var outcomesByIdempotencyKey: [String: CacheEntry] = [:]
    private var outcomeInsertionOrder: [String] = []

    public init() {
        eventStore = EKEventStore()
    }

    public func createReminder(
        _ request: ReminderCreationRequest
    ) async throws -> ReminderCreationReceipt {
        let request = try Self.validate(request)
        if let cached = try cachedOutcome(for: request) {
            return try Self.resolve(cached)
        }

        try await ensureFullReminderAccess()

        // Permission acquisition suspends the actor. Recheck after it returns
        // so concurrent retries cannot both write the same reminder.
        if let cached = try cachedOutcome(for: request) {
            return try Self.resolve(cached)
        }

        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            throw ReminderServiceError.noDefaultCalendar
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = request.title
        reminder.calendar = calendar
        reminder.dueDateComponents = Self.dueDateComponents(for: request.dueAt)

        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            throw ReminderServiceError.saveFailed(code: (error as NSError).code)
        }

        guard let identifier = Self.validIdentifier(reminder.calendarItemIdentifier) else {
            let failure = ReminderServiceError.savedReminderMissingIdentifier
            remember(.postSaveFailure(failure), for: request)
            throw failure
        }

        guard
            let fetched = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder,
            fetched.title == request.title,
            fetched.calendar.calendarIdentifier == calendar.calendarIdentifier,
            let fetchedDueAt = Self.date(from: fetched.dueDateComponents),
            Self.sameSecond(fetchedDueAt, request.dueAt)
        else {
            let failure = ReminderServiceError.savedReminderCouldNotBeVerified
            remember(.postSaveFailure(failure), for: request)
            throw failure
        }

        let receipt = ReminderCreationReceipt(
            reminderIdentifier: identifier,
            title: request.title,
            dueAt: request.dueAt,
            verified: true
        )
        remember(.success(receipt), for: request)
        return receipt
    }

    private func ensureFullReminderAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted: Bool
            do {
                granted = try await eventStore.requestFullAccessToReminders()
            } catch {
                throw ReminderServiceError.authorizationFailed(code: (error as NSError).code)
            }
            guard granted else {
                throw ReminderServiceError.accessDenied
            }
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                throw ReminderServiceError.fullAccessRequired
            }
        case .restricted:
            throw ReminderServiceError.accessRestricted
        case .denied:
            throw ReminderServiceError.accessDenied
        case .writeOnly:
            throw ReminderServiceError.fullAccessRequired
        @unknown default:
            throw ReminderServiceError.fullAccessRequired
        }
    }

    private func cachedOutcome(for request: ValidatedRequest) throws -> CachedOutcome? {
        guard let entry = outcomesByIdempotencyKey[request.idempotencyKey] else {
            return nil
        }
        guard entry.request == request else {
            throw ReminderServiceError.idempotencyConflict
        }
        return entry.outcome
    }

    private static func resolve(_ outcome: CachedOutcome) throws -> ReminderCreationReceipt {
        switch outcome {
        case .success(let receipt):
            return receipt
        case .postSaveFailure(let error):
            throw error
        }
    }

    private func remember(_ outcome: CachedOutcome, for request: ValidatedRequest) {
        if outcomesByIdempotencyKey[request.idempotencyKey] == nil {
            outcomeInsertionOrder.append(request.idempotencyKey)
        }
        outcomesByIdempotencyKey[request.idempotencyKey] = CacheEntry(
            request: request,
            outcome: outcome
        )

        while outcomeInsertionOrder.count > Self.maximumCachedOutcomes {
            let oldest = outcomeInsertionOrder.removeFirst()
            outcomesByIdempotencyKey.removeValue(forKey: oldest)
        }
    }

    private static func validate(_ request: ReminderCreationRequest) throws -> ValidatedRequest {
        let title = request.title
        guard
            !title.isEmpty,
            title == title.trimmingCharacters(in: .whitespacesAndNewlines),
            title.count <= maximumTitleCharacters,
            title.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw ReminderServiceError.invalidTitle
        }

        let key = request.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !key.isEmpty,
            key.count <= maximumIdempotencyKeyCharacters,
            key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw ReminderServiceError.invalidIdempotencyKey
        }

        let seconds = request.dueAt.timeIntervalSinceReferenceDate
        let maximumDate = Calendar(identifier: .gregorian).date(
            byAdding: .year,
            value: 100,
            to: Date()
        ) ?? .distantFuture
        guard
            seconds.isFinite,
            request.dueAt >= Date(timeIntervalSince1970: 0),
            request.dueAt <= maximumDate
        else {
            throw ReminderServiceError.invalidDueDate
        }

        // EventKit reminders store date components to whole-second precision.
        let normalizedDueAt = Date(timeIntervalSinceReferenceDate: seconds.rounded(.down))
        return ValidatedRequest(title: title, dueAt: normalizedDueAt, idempotencyKey: key)
    }

    private static func dueDateComponents(for date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents(
            [.era, .year, .month, .day, .hour, .minute, .second],
            from: date
        )
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return components
    }

    private static func date(from components: DateComponents?) -> Date? {
        guard let components else { return nil }
        var calendar = components.calendar ?? Calendar(identifier: .gregorian)
        calendar.timeZone = components.timeZone ?? .current
        return calendar.date(from: components)
    }

    private static func sameSecond(_ lhs: Date, _ rhs: Date) -> Bool {
        Int64(lhs.timeIntervalSinceReferenceDate.rounded(.down))
            == Int64(rhs.timeIntervalSinceReferenceDate.rounded(.down))
    }

    private static func validIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1_024 else { return nil }
        return trimmed
    }
}
