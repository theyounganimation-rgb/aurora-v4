import Foundation

/// The kind of explicit leave-taking Aurora heard in a finalized owner turn.
///
/// Raw values are intentionally stable because the app may journal or test the
/// decision without depending on the classifier's internal phrase lists.
public enum ConversationClosingIntent: String, Codable, Sendable, Equatable {
    case notClosing = "not_closing"
    case goodbye
    case leavingNow = "leaving_now"
    case talkLater = "talk_later"
    case seeYou = "see_you"
    case goodNight = "good_night"
    case headingOut = "heading_out"

    public var shouldSleep: Bool {
        self != .notClosing
    }
}

/// A deliberately conservative, deterministic classifier for deciding when a
/// completed owner utterance should put Aurora back into wake-word sleep.
///
/// This does not try to infer mood or relationship meaning. It only recognizes
/// unmistakable, present-tense conversational closings and prefers a false
/// negative over putting Aurora to sleep during an ordinary sentence.
public enum ConversationClosingIntentClassifier {
    public static func classify(
        finalizedOwnerTranscript transcript: String
    ) -> ConversationClosingIntent {
        let evidence = Evidence(transcript)
        guard !evidence.normalized.isEmpty,
              !evidence.isQuotedClosing,
              !evidence.isNegated,
              !evidence.isHypothetical,
              !evidence.isDiscussingClosingLanguage,
              !evidence.isNonImmediatePlan else {
            return .notClosing
        }

        if evidence.matchesDirectFarewell {
            return .goodbye
        }
        if evidence.matchesGoodNight {
            return .goodNight
        }
        if evidence.matchesSeeYou {
            return .seeYou
        }
        if evidence.matchesTalkLater {
            return .talkLater
        }
        if evidence.matchesHeadingOut {
            return .headingOut
        }
        if evidence.matchesLeavingNow {
            return .leavingNow
        }
        return .notClosing
    }

    public static func shouldSleep(
        after finalizedOwnerTranscript: String
    ) -> Bool {
        classify(finalizedOwnerTranscript: finalizedOwnerTranscript).shouldSleep
    }
}

private extension ConversationClosingIntentClassifier {
    struct Evidence {
        private static let leadingFillers: Set<String> = [
            "ah", "alright", "anyway", "aurora", "hey", "hmm", "kay", "okay",
            "ok", "right", "so", "uh", "um", "well", "yeah", "yep",
        ]

        private static let trailingFillers: Set<String> = [
            "alright", "aurora", "okay", "ok", "then",
        ]

        private static let closingLexemes = [
            "goodbye", "good bye", "bye", "bye bye", "good night", "goodnight",
            "talk later", "talk to you later", "see you later", "see you soon",
            "catch you later", "i gotta go", "i have to go", "i need to go",
            "i m heading out", "i am heading out", "i m going to bed",
            "i am going to bed", "i m going to sleep", "i am going to sleep",
        ]

        let original: String
        let normalized: String
        let core: String
        let closingClauses: [String]

        init(_ transcript: String) {
            original = String(transcript.prefix(2_000))
            normalized = Self.normalize(original)
            core = Self.stripConversationalFillers(from: normalized)

            closingClauses = original
                .components(separatedBy: CharacterSet(charactersIn: ".,!?;:\n\u{2013}\u{2014}"))
                .map(Self.normalize)
                .map(Self.stripConversationalFillers)
                .filter { !$0.isEmpty }
        }

        var isQuotedClosing: Bool {
            let doubleQuoteNormalized = original
                .replacingOccurrences(of: "\u{201C}", with: "\"")
                .replacingOccurrences(of: "\u{201D}", with: "\"")
                .replacingOccurrences(of: "\u{00AB}", with: "\"")
                .replacingOccurrences(of: "\u{00BB}", with: "\"")
            let parts = doubleQuoteNormalized.components(separatedBy: "\"")
            guard parts.count >= 3 else { return false }

            return parts.enumerated().contains { index, part in
                guard index.isMultiple(of: 2) == false else { return false }
                let quoted = Self.normalize(part)
                return Self.closingLexemes.contains { quoted.containsPhrase($0) }
            }
        }

        var isNegated: Bool {
            containsAny([
                "not saying goodbye", "not saying bye", "not ready to say goodbye",
                "not ready to say bye", "not goodbye yet", "not good night yet",
                "do not say goodbye", "don t say goodbye", "dont say goodbye",
                "do not say bye", "don t say bye", "dont say bye",
                "never say goodbye", "never said goodbye", "without saying goodbye",
                "not saying i gotta go", "not saying i have to go",
                "not saying that i gotta go", "not saying that i have to go",
                "never said i gotta go", "never said i have to go",
                "don t mean i gotta go", "dont mean i gotta go",
                "don t mean i have to go", "dont mean i have to go",
                "i do not have to go", "i don t have to go", "i dont have to go",
                "i do not need to go", "i don t need to go", "i dont need to go",
                "i m not leaving", "i am not leaving", "i m not heading out",
                "i am not heading out", "i m not going to bed",
                "i am not going to bed", "i m not going to sleep",
                "i am not going to sleep", "we re not leaving", "we are not leaving",
            ])
        }

        var isHypothetical: Bool {
            containsAny([
                "if i say goodbye", "if i said goodbye", "if i say bye",
                "if i said bye", "if i have to go", "if i gotta go",
                "if i told you goodbye", "when i say goodbye", "when i say bye",
                "when i have to go", "whenever i say goodbye", "what if i say goodbye",
                "what if i said goodbye", "what if i have to go", "suppose i say goodbye",
                "suppose i said goodbye", "imagine i say goodbye", "imagine i said goodbye",
                "should i say goodbye", "should i say bye", "could i say goodbye",
                "can i say goodbye", "am i supposed to say goodbye",
                "do i have to go", "did i say i have to go", "did i say i gotta go",
                "why do i have to go", "when do i have to go", "how do i have to go",
                "would saying goodbye", "would you sleep if", "would you go to sleep if",
                "hypothetically", "theoretically",
            ])
        }

        var isDiscussingClosingLanguage: Bool {
            if containsAny([
                "the word goodbye", "the word bye", "the phrase goodbye",
                "the phrase bye", "what does goodbye mean", "what goodbye means",
                "how do you say goodbye", "how should i say goodbye",
                "how to say goodbye", "spell goodbye", "translate goodbye",
                "talking about goodbye", "talk about goodbye", "discuss goodbye",
                "you said goodbye", "you said bye", "did you say goodbye",
                "did you say bye", "why did you say goodbye", "why did you say bye",
                "i said goodbye", "i said bye", "he said goodbye", "he said bye",
                "she said goodbye", "she said bye", "they said goodbye", "they said bye",
                "someone said goodbye", "someone said bye", "jack said goodbye",
                "jack said bye", "saying goodbye is", "saying bye is",
                "the phrase i gotta go", "the phrase i have to go",
                "the words i gotta go", "the words i have to go",
                "what does i gotta go mean", "what does i have to go mean",
                "you said i gotta go", "you said i have to go", "i said i gotta go",
                "i said i have to go", "he said i gotta go", "he said i have to go",
                "she said i gotta go", "she said i have to go", "they said i gotta go",
                "they said i have to go", "someone said i gotta go",
                "someone said i have to go", "did you say i gotta go",
                "did you say i have to go", "are you saying i have to go",
                "hate saying goodbye", "hate saying bye", "hard to say goodbye",
                "weird to say goodbye", "want you to say goodbye", "make you say goodbye",
                "ask you to say goodbye", "tell you to say goodbye",
                "wave goodbye", "waved goodbye", "kiss goodbye", "kissed goodbye",
            ]) {
                return true
            }

            if containsAny(["say goodbye to", "say bye to", "tell goodbye to", "tell bye to"]),
               !containsAny([
                   "say goodbye to you", "say bye to you", "say goodbye to aurora",
                   "say bye to aurora",
               ]) {
                return true
            }

            // "Goodbye to the old wallpaper" and similar uses are about
            // something ending, not about ending this conversation.
            return containsAny(["goodbye to", "bye to"])
                && !containsAny([
                    "goodbye to you", "bye to you", "goodbye to aurora", "bye to aurora",
                ])
        }

        var isNonImmediatePlan: Bool {
            let hasLeaveTakingPhrase = containsAny([
                "i gotta go", "i ve gotta go", "i have gotta go", "i have to go",
                "i need to go", "we gotta go", "we have to go", "i need to leave",
                "i m leaving", "i am leaving", "i m heading out", "i am heading out",
                "i m gonna head out", "i am going to head out", "i m going to bed",
                "i am going to bed", "i m going to sleep", "i am going to sleep",
            ])
            guard hasLeaveTakingPhrase else { return false }

            let futureOnly = containsAny([
                "later", "later today", "later tonight", "later this week", "tomorrow",
                "next week", "next month", "eventually", "sometime later",
                "in a few hours", "after work", "after dinner", "after the movie",
            ])
            let explicitlyImmediate = containsAny([
                "right now", "gotta go now", "have to go now", "need to go now",
                "leaving now", "heading out now", "going to bed now", "going to sleep now",
            ])
            let laterIsFarewell = containsAny([
                "talk later", "talk to you later", "see you later", "see ya later",
                "catch you later",
            ])
            if futureOnly && !explicitlyImmediate && !laterIsFarewell { return true }

            // These are common non-leave-taking senses of "go". Destination
            // statements are allowed when they are clearly immediate; a
            // future destination such as "go to the store later" is rejected
            // by the future check above.
            return containsAny([
                "have to go over", "gotta go over", "need to go over",
                "have to go through", "gotta go through", "need to go through",
                "have to go into detail", "need to go into detail",
            ])
        }

        var matchesDirectFarewell: Bool {
            matchesClosingShape([
                "bye", "bye bye", "goodbye", "good bye", "bye for now",
                "goodbye for now", "so long", "farewell", "take care",
                "thanks bye", "thank you bye", "thanks goodbye", "thank you goodbye",
            ])
        }

        var matchesGoodNight: Bool {
            matchesClosingShape([
                "good night", "goodnight", "night", "night night", "have a good night",
                "sleep well", "i m going to bed", "i am going to bed", "i m off to bed",
                "i am off to bed", "i m going to sleep", "i am going to sleep",
                "i m off to sleep", "i am off to sleep", "time for bed",
            ])
        }

        var matchesSeeYou: Bool {
            matchesClosingShape([
                "see you", "see you later", "see you soon", "see you tomorrow",
                "see ya", "see ya later", "catch you later", "until next time",
            ])
        }

        var matchesTalkLater: Bool {
            matchesClosingShape([
                "talk later", "talk to you later", "we ll talk later", "we will talk later",
                "i ll talk to you later", "i will talk to you later", "talk soon",
                "we ll talk soon", "we will talk soon", "i ll talk to you soon",
                "i will talk to you soon",
            ])
        }

        var matchesHeadingOut: Bool {
            matchesClosingShape([
                "i m heading out", "i am heading out", "i m gonna head out",
                "i am going to head out", "i need to head out", "i have to head out",
                "we re heading out", "we are heading out", "i should get going",
                "i better get going", "i d better get going",
            ])
        }

        var matchesLeavingNow: Bool {
            matchesClosingShape([
                "i gotta go", "i ve gotta go", "i have gotta go", "i have to go",
                "i need to go", "i must go", "we gotta go", "we ve gotta go",
                "we have to go", "i need to leave", "i have to leave", "i m leaving",
                "i am leaving", "we re leaving", "we are leaving",
                "i gotta run", "i have to run", "i need to run", "gotta run",
                "i think i gotta go", "i think i have to go", "i guess i gotta go",
                "i guess i have to go",
            ])
        }

        private func matchesClosingShape(_ phrases: [String]) -> Bool {
            if matchesClosingCandidate(core, phrases: phrases) {
                return true
            }

            // A closing may be followed by a small courtesy ("bye, love you"),
            // but a substantive continuation or retraction means the owner is
            // still talking. Looking at the remaining clauses prevents an
            // early "bye" from winning over "actually, wait, one more thing."
            for (index, clause) in closingClauses.enumerated()
            where matchesClosingCandidate(clause, phrases: phrases) {
                let following = closingClauses.dropFirst(index + 1)
                guard !following.isEmpty else { return true }
                if following.allSatisfy(isCourtesyTail) { return true }
            }
            return false
        }

        private func matchesClosingCandidate(_ candidate: String, phrases: [String]) -> Bool {
            phrases.contains { phrase in
                candidate == phrase
                    || candidate == phrase + " now"
                    || candidate == phrase + " for now"
            }
        }

        private func isCourtesyTail(_ clause: String) -> Bool {
            let courtesies: Set<String> = [
                "and thanks", "appreciate it", "aurora", "be safe", "bye", "goodbye",
                "good night", "goodnight", "have a good day", "have a good evening",
                "have a good night", "have a good one", "i love you", "love you",
                "night", "see you", "see you later", "see you soon", "sleep well",
                "sorry", "sweet dreams", "take care", "talk later", "talk soon",
                "thank you", "thanks",
            ]
            return courtesies.contains(clause)
        }

        private func containsAny(_ phrases: [String]) -> Bool {
            phrases.contains { normalized.containsPhrase($0) }
        }

        private static func normalize(_ value: String) -> String {
            value
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        private static func stripConversationalFillers(from value: String) -> String {
            var words = value.split(separator: " ").map(String.init)
            while words.count > 1, let first = words.first, leadingFillers.contains(first) {
                words.removeFirst()
            }
            while words.count > 1, let last = words.last, trailingFillers.contains(last) {
                words.removeLast()
            }
            return words.joined(separator: " ")
        }
    }
}

private extension String {
    func containsPhrase(_ phrase: String) -> Bool {
        let padded = " " + self + " "
        return padded.contains(" " + phrase + " ")
    }
}
