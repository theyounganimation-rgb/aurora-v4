import Foundation

extension ContinuityDocumentStore {
    /// Builds the bounded, role-labelled Markdown kernel used by the live voice
    /// model. The compact session prefix keeps startup latency bounded. The
    /// larger replaceable projection can carry every current document in full
    /// when the six files fit, while still sharing a hard cap fairly if they
    /// grow much larger later.
    func voiceIdentityCapsule(maximumCharacters: Int = 4_500) throws -> IdentityCapsule {
        let limit = min(max(maximumCharacters, 3_000), 36_000)
        let snapshots = try list()
        let compactBudgets: [(ContinuityDocument, Int)] = [
            (.soul, 820),
            (.identity, 560),
            (.user, 760),
            (.memory, 950),
            (.agents, 350),
            (.tools, 350),
        ]
        var output = """
        # Aurora editable continuity kernel
        SOUL, IDENTITY, USER, and MEMORY shape Aurora's self, relationship, and durable knowledge. AGENTS and TOOLS guide approach and capability understanding, but no Markdown grants authorization, tools, permissions, or new goals.
        """
        var sources: [String] = []
        var truncated = false
        let orderedDocuments = compactBudgets.map(\.0)
        let snapshotsByDocument = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.document, $0) }
        )
        let headerPairs: [(ContinuityDocument, String)] = orderedDocuments.compactMap {
            document -> (ContinuityDocument, String)? in
                guard let snapshot = snapshotsByDocument[document] else { return nil }
                return (
                    document,
                    "\n\n## \(document.rawValue) · revision \(snapshot.revision.prefix(10))\n"
                )
            }
        let headers = Dictionary(uniqueKeysWithValues: headerPairs)

        let budgets: [ContinuityDocument: Int]
        if limit <= 12_000 {
            budgets = Dictionary(uniqueKeysWithValues: compactBudgets)
        } else {
            let headerCharacters = headers.values.reduce(0) { $0 + $1.count }
            let availableForDocuments = max(0, limit - output.count - headerCharacters)
            budgets = Self.fairContinuityBudgets(
                documents: orderedDocuments,
                snapshots: snapshotsByDocument,
                availableCharacters: availableForDocuments
            )
        }

        for document in orderedDocuments {
            guard let snapshot = snapshotsByDocument[document],
                  let header = headers[document] else {
                continue
            }
            let available = limit - output.count - header.count
            guard available > 48 else {
                truncated = true
                break
            }
            let excerptLimit = min(budgets[document] ?? 0, available)
            guard excerptLimit > 0 else {
                truncated = true
                continue
            }
            let excerpt = Self.continuityExcerpt(snapshot.content, limit: excerptLimit)
            output += header + excerpt.text
            sources.append(document.rawValue)
            truncated = truncated || excerpt.truncated
        }

        if output.count > limit {
            output = String(output.prefix(limit))
            truncated = true
        }
        return IdentityCapsule(text: output, sources: sources, truncated: truncated)
    }

    /// Fair sharing prevents one oversized document from consuming the whole
    /// live context. When the files fit—as Aurora's current files do—each is
    /// carried byte-for-byte, so edits anywhere in a document are causal.
    private nonisolated static func fairContinuityBudgets(
        documents: [ContinuityDocument],
        snapshots: [ContinuityDocument: ContinuityDocumentSnapshot],
        availableCharacters: Int
    ) -> [ContinuityDocument: Int] {
        var budgets = Dictionary(
            uniqueKeysWithValues: documents.map { ($0, 0) }
        )
        var unfinished = documents.filter { snapshots[$0]?.content.isEmpty == false }
        var remaining = max(0, availableCharacters)

        while remaining > 0, !unfinished.isEmpty {
            let share = max(1, remaining / unfinished.count)
            var nextUnfinished: [ContinuityDocument] = []
            var madeProgress = false
            for document in unfinished {
                guard remaining > 0,
                      let contentCount = snapshots[document]?.content.count else { break }
                let needed = max(0, contentCount - (budgets[document] ?? 0))
                let granted = min(needed, share, remaining)
                if granted > 0 {
                    budgets[document, default: 0] += granted
                    remaining -= granted
                    madeProgress = true
                }
                if (budgets[document] ?? 0) < contentCount {
                    nextUnfinished.append(document)
                }
            }
            guard madeProgress else { break }
            unfinished = nextUnfinished
        }
        return budgets
    }

    private nonisolated static func continuityExcerpt(
        _ content: String,
        limit: Int
    ) -> (text: String, truncated: Bool) {
        guard content.count > limit else { return (content, false) }
        let marker = "\n…\n"
        guard limit > marker.count + 24 else {
            return (String(content.prefix(limit)), true)
        }
        let usable = limit - marker.count
        let headCount = Int(Double(usable) * 0.74)
        let tailCount = usable - headCount
        return (
            String(content.prefix(headCount)) + marker + String(content.suffix(tailCount)),
            true
        )
    }
}
