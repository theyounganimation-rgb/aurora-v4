import Foundation

/// Retains the fact that a finalized owner input produced a tool call across
/// split Realtime callbacks. `response.done` can be processed before the
/// acknowledgement finishes playing, so the later playback callback must not
/// reclassify the same input as an ordinary conversation.
struct ToolAddressedInputProvenance {
    static let defaultRetentionLimit = 128

    private let retentionLimit: Int
    private var inputItemIDs = Set<String>()
    private var inputItemOrder: [String] = []

    init(retentionLimit: Int = defaultRetentionLimit) {
        precondition(retentionLimit > 0)
        self.retentionLimit = retentionLimit
    }

    mutating func mark(_ inputItemID: String) {
        guard inputItemIDs.insert(inputItemID).inserted else { return }
        inputItemOrder.append(inputItemID)
        trimToRetentionLimit()
    }

    func contains(_ inputItemID: String) -> Bool {
        inputItemIDs.contains(inputItemID)
    }

    /// Consumes provenance only after the completed foreground exchange has
    /// inherited it. An addressed-tool-only pass intentionally does not call
    /// this method because acknowledgement playback may still arrive later.
    @discardableResult
    mutating func consume(_ inputItemID: String) -> Bool {
        guard inputItemIDs.remove(inputItemID) != nil else { return false }
        inputItemOrder.removeAll { $0 == inputItemID }
        return true
    }

    mutating func remove(_ inputItemID: String) {
        _ = consume(inputItemID)
    }

    mutating func removeAll() {
        inputItemIDs.removeAll(keepingCapacity: true)
        inputItemOrder.removeAll(keepingCapacity: true)
    }

    private mutating func trimToRetentionLimit() {
        guard inputItemOrder.count > retentionLimit else { return }
        let expiredCount = inputItemOrder.count - retentionLimit
        let expired = inputItemOrder.prefix(expiredCount)
        inputItemOrder.removeFirst(expiredCount)
        for inputItemID in expired {
            inputItemIDs.remove(inputItemID)
        }
    }
}
