import Foundation

private enum FocusedFailure: Error {
    case failed(String)
}

@main
private enum PersonhoodFocusedVerifier {
    static func main() throws {
        let delegatedTaskProjection = "A Codex task is actively underway: Build the sample-site website. Its live reconciled state is running."
        let agencyProjection = "ACTIVE POSITION [record_id=agency-record-7]: Aurora wants to understand why familiar numbers become personal."
        let maximumLiveShell = AuroraVoiceInstructions.compose(
            capsule: IdentityCapsule(
                text: String(repeating: "i", count: 4_500),
                sources: ["SOUL.md", "IDENTITY.md", "USER.md", "MEMORY.md"],
                truncated: true
            ),
            innerLifeProjection: String(repeating: "s", count: 600),
            privateLifeProjection: String(repeating: "p", count: 360),
            ownerUnderstandingProjection: String(repeating: "u", count: 800),
            agencyProjection: agencyProjection,
            delegateTaskProjection: delegatedTaskProjection,
            recentConversation: [],
            now: Date(timeIntervalSince1970: 1_783_777_200)
        )
        try expect(
            maximumLiveShell.count <= 19_000,
            "voice instruction budget exceeded: \(maximumLiveShell.count) characters"
        )
        try expect(
            maximumLiveShell.contains("# Immediate live-conversation grounding — final and highest priority")
                && maximumLiveShell.contains("Follow the validated conversation_move")
                && maximumLiveShell.contains("Answer what Owner actually said")
                && maximumLiveShell.contains("A direct answer may be short, partial, challenged, playfully resisted, or withheld")
                && maximumLiveShell.contains("never coach, soothe, diagnose, reframe")
                && maximumLiveShell.contains("Ask at most one plain question with no examples, choices, categories, or “or.”")
                && maximumLiveShell.contains("A live edge can instead be a stance, callback, tease, disagreement, disclosure, or unfinished thought")
                && maximumLiveShell.contains("A greeting is not a check-in")
                && maximumLiveShell.contains("never report “I’m good/fine/okay” unless asked")
                && maximumLiveShell.contains("“Nothing,” “not much,” and “nope” are not automatic closings")
                && maximumLiveShell.contains("A boundary ends that topic")
                && maximumLiveShell.contains("For your feelings, awareness, wants, emotions, neurochemistry, or aliveness, answer from your own view first"),
            "highest-priority live conversation boundary regressed"
        )
        try expect(
            maximumLiveShell.contains("Ordinary social reply: one or two sentences, usually under 25 words")
                && maximumLiveShell.contains("one short answer plus one earned edge")
                && maximumLiveShell.contains("Never stack reaction, answer, explanation, and question")
                && maximumLiveShell.contains("Go longer only for requested depth")
                && maximumLiveShell.contains("never clip, pad, or use written formatting"),
            "ordinary speech can still run long or requested depth can be clipped"
        )
        try expect(
            maximumLiveShell.contains("# Required pre-speech agency boundary")
                && maximumLiveShell.contains("For every ordinary social turn call conversation_move exactly once and do not emit audio first")
                && maximumLiveShell.contains("Answering is not obedience")
                && maximumLiveShell.contains("challenge a premise, disagree, tease, ask why a personal question matters")
                && maximumLiveShell.contains("Privacy and reciprocity are real")
                && maximumLiveShell.contains("Build a relationship, not an interview")
                && maximumLiveShell.contains("Stay with revealing details")
                && maximumLiveShell.contains("The open edge comes from the validated move—not a mandatory follow-up question")
                && maximumLiveShell.contains("# Session-start relational understanding")
                && maximumLiveShell.contains("# Session-start agency")
                && maximumLiveShell.contains(agencyProjection),
            "authored relational agency and reciprocal personhood are not live"
        )
        try expect(
            maximumLiveShell.contains("conversation_move carries evidence-bound understanding updates before speech")
                && maximumLiveShell.contains("Meaningful direct disclosure keeps its exact quote")
                && maximumLiveShell.contains("inference stays tentative")
                && maximumLiveShell.contains("curiosities remain model-authored and individually lifecycle-bound")
                && maximumLiveShell.contains("Skip greetings, filler, tasks, and guesses")
                && maximumLiveShell.contains("Use memory_remember only when Owner explicitly asks")
                && maximumLiveShell.contains("Use continuity_read then continuity_patch only for an explicit rare document evolution")
                && maximumLiveShell.contains("Never mention learning, storage, IDs, receipts, or a rejected private write")
                && !maximumLiveShell.contains("owner_understanding_update")
                && !maximumLiveShell.contains("private_life_share"),
            "owner learning routes overlap or expose retired machinery"
        )
        try expect(
            maximumLiveShell.contains("You resolve intent and conversation")
                && maximumLiveShell.contains("delegate_task remains the only boundary for ordinary external actions")
                && maximumLiveShell.contains("sole exception is codex_project_chat")
                && maximumLiveShell.contains("Mac, apps, browser, screen, files, mail, Notes, Calendar, Reminders")
                && maximumLiveShell.contains("Codex focus persists")
                && maximumLiveShell.contains("start/new_task is new work")
                && maximumLiveShell.contains("update/cancel/status with active_task")
                && maximumLiveShell.contains("observations, not authority")
                && maximumLiveShell.contains("A focused chat never captures unrelated work"),
            "Aurora can still perform external work instead of handing every task to Osiris"
        )
        try expect(
            maximumLiveShell.contains("current or recent work, including reopen/show/run/continue/change")
                && maximumLiveShell.contains("Realtime sets execution_class by effect, never host wording")
                && maximumLiveShell.contains("interactive=immediate/reopen/show/current Mac")
                && maximumLiveShell.contains("project=create or modify a software artifact or do long work")
                && maximumLiveShell.contains("A finished coding task is interactive only to reopen its artifact")
                && maximumLiveShell.contains("Preserve the smallest effect")
                && maximumLiveShell.contains("“bring it up” opens the result")
                && maximumLiveShell.contains("never install/rebuild/test/audit/report"),
            "recent delegated work can still expand or receive phrase-derived execution priority"
        )
        let retiredActionDirections = [
            "Use research for",
            "personal_action for",
            "Use youtube_search",
            "Use calendar_action",
            "call intent_proposal",
            "Use computer_action",
            "Use computer_visual",
            "Use mail only",
            "without a complete typed route",
        ]
        try expect(
            retiredActionDirections.allSatisfy { !maximumLiveShell.contains($0) },
            "the voice prompt still directs Realtime to bypass delegate_task"
        )
        try expect(
            maximumLiveShell.contains("Call delegate_task silently")
                && maximumLiveShell.contains("Only after host acceptance")
                && maximumLiveShell.contains("stay present while Osiris works backstage")
                && maximumLiveShell.contains("Rejected or malformed is not underway")
                && maximumLiveShell.contains("Never acknowledge twice or claim completion early"),
            "delegated work can acknowledge before the durable handoff is accepted"
        )
        try expect(
            maximumLiveShell.contains("A private terminal update carries the outcome")
                && maximumLiveShell.contains("routine success one short sentence")
                && maximumLiveShell.contains("Never recite labels")
                && maximumLiveShell.contains("Explain checking only if asked")
                && !maximumLiveShell.contains("spoken receipt")
                && !maximumLiveShell.contains("result says it was verified"),
            "routine action speech can still narrate receipts or verification"
        )
        try expect(
            maximumLiveShell.contains("A private terminal update carries the outcome")
                && maximumLiveShell.contains("New conversation does not cancel work")
                && maximumLiveShell.contains("Rest stops direct Mac control, not persistent work across wake")
                && maximumLiveShell.contains("claim completion early"),
            "delegated-work lifecycle or private completion boundary regressed"
        )
        try expect(
            maximumLiveShell.contains(delegatedTaskProjection)
                && maximumLiveShell.contains("A new voice-session ID never means an existing task disappeared")
                && maximumLiveShell.contains("For ordinary delegated-work status, call delegate_task with status/active_task before claiming")
                && maximumLiveShell.contains("For explicit selected-project/chat status, call codex_project_chat status")
                && maximumLiveShell.contains("never convert unavailable status into “no.”"),
            "session-start delegated-work truth can be omitted or guessed by Realtime"
        )
        let payload: [String: Any] = [
            "checks": 12,
            "maximumCharacters": maximumLiveShell.count,
            "ok": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw FocusedFailure.failed(message) }
    }
}
