import Foundation

/// A deterministic, privacy-preserving routing decision made from the
/// finalized owner transcript before any broad visual-computer task starts.
///
/// This is intentionally a small intent gate rather than a language model. It
/// only claims utterances whose wording clearly identifies a supported path;
/// ordinary conversation remains `.none` and stays with Aurora's voice model.
public enum NativeCapabilityRouteKind: String, Codable, Sendable, Equatable, CaseIterable {
    case reminder
    case currentWebResearch = "current_web_research"
    case directOpen = "direct_open"
    case mail
    case textEditWrite = "textedit_write"
    case deterministicDesktopAction = "deterministic_desktop_action"
    case sightOnlyVisual = "sight_only_visual"
    case visualComputerTask = "visual_computer_task"
    case none
}

/// Stable tool/action names that the tool registry and regression checks can
/// consume without duplicating the router's language heuristics.
public struct NativeCapabilityRoute: Codable, Sendable, Equatable {
    public let kind: NativeCapabilityRouteKind
    public let preferredToolName: String?
    public let preferredAction: String?
    public let preferredTarget: String?

    public init(
        kind: NativeCapabilityRouteKind,
        preferredToolName: String?,
        preferredAction: String? = nil,
        preferredTarget: String? = nil
    ) {
        self.kind = kind
        self.preferredToolName = preferredToolName
        self.preferredAction = preferredAction
        self.preferredTarget = preferredTarget
    }

    public static let reminder = NativeCapabilityRoute(
        kind: .reminder,
        preferredToolName: "personal_action",
        preferredAction: "create_reminder"
    )

    public static let currentWebResearch = NativeCapabilityRoute(
        kind: .currentWebResearch,
        preferredToolName: "research"
    )

    public static func directOpen(_ target: String) -> NativeCapabilityRoute {
        NativeCapabilityRoute(
            kind: .directOpen,
            preferredToolName: "computer_open",
            preferredTarget: target
        )
    }

    public static let mail = NativeCapabilityRoute(
        kind: .mail,
        preferredToolName: "mail"
    )

    public static let textEditWrite = NativeCapabilityRoute(
        kind: .textEditWrite,
        preferredToolName: "computer_action",
        preferredAction: "write_textedit_document"
    )

    public static let sightOnlyVisual = NativeCapabilityRoute(
        kind: .sightOnlyVisual,
        preferredToolName: "computer_visual",
        preferredAction: "look"
    )

    public static let visualComputerTask = NativeCapabilityRoute(
        kind: .visualComputerTask,
        preferredToolName: "computer_task",
        preferredAction: "start"
    )

    public static let none = NativeCapabilityRoute(
        kind: .none,
        preferredToolName: nil
    )

    public static func desktop(
        _ action: NativeDesktopAction,
        target: String? = nil
    ) -> NativeCapabilityRoute {
        NativeCapabilityRoute(
            kind: .deterministicDesktopAction,
            preferredToolName: "computer_action",
            preferredAction: action.rawValue,
            preferredTarget: target
        )
    }

    public var isDirectDomainCapability: Bool {
        switch kind {
        case .reminder, .currentWebResearch, .directOpen, .mail:
            return true
        default:
            return false
        }
    }
}

public enum NativeCapabilityRouter {
    /// True only when the owner's words are a present-tense command or a
    /// direct request to perform an action. Informational and retrospective
    /// questions such as "Did you close it?" must never authorize a second
    /// side effect merely because they contain an action verb.
    public static func isDirectActionRequest(_ transcript: String) -> Bool {
        Evidence(transcript).isDirectActionRequest
    }

    /// Narrows a direct request to its leading action family. This prevents an
    /// informational request beginning with "show" or "check" from borrowing
    /// a consequential verb that appears later in the sentence.
    public static func isDirectActionRequest(
        _ transcript: String,
        leadingWith actions: [String]
    ) -> Bool {
        let evidence = Evidence(transcript)
        return evidence.isDirectActionRequest
            && !evidence.isHypothetical
            && evidence.commandStartsWithAny(actions)
    }

    /// True when the finalized words themselves explicitly rule out an
    /// immediate side effect. Transport-level audio recovery must never
    /// override these cases, even if a model mistakenly proposes a tool.
    public static func explicitlyRejectsImmediateAction(_ transcript: String) -> Bool {
        let evidence = Evidence(transcript)
        return evidence.isStandaloneCancellation
            || evidence.isNegatedCommand
            || evidence.withdrawsDirectActionInSameTurn
            || evidence.isHypothetical
            || (evidence.isDirectActionRequest && evidence.hasDeferredActionTiming)
    }

    /// Fixed routing priority:
    /// reminder -> current web research -> mail -> direct TextEdit writing
    /// -> compound visual sequence -> direct web destination -> deterministic macOS action
    /// -> sight-only visual context -> visual computer task -> conversation.
    public static func route(finalizedOwnerTranscript transcript: String) -> NativeCapabilityRoute {
        let evidence = Evidence(transcript)
        guard !evidence.normalized.isEmpty,
              !evidence.isStandaloneCancellation,
              !evidence.isNegatedCommand,
              !evidence.withdrawsDirectActionInSameTurn else {
            return .none
        }

        if reminderIntent(in: evidence) {
            return .reminder
        }
        // Aurora has no delayed desktop-job scheduler. A future-qualified
        // command must remain conversational instead of happening immediately.
        if evidence.isDirectActionRequest, evidence.hasDeferredActionTiming {
            return .none
        }
        if currentWebResearchIntent(in: evidence) {
            return .currentWebResearch
        }
        if mailIntent(in: evidence) {
            return .mail
        }
        if textEditWriteIntent(in: evidence) {
            return .textEditWrite
        }
        if compoundVisualComputerTaskIntent(in: evidence) {
            return .visualComputerTask
        }
        // The asynchronous transcript has repeatedly rendered “Open
        // YouTube” as “Hope on YouTube” even though Realtime's native audio
        // understanding selected the correct bounded target. Repair only
        // this narrow supported-destination shape; ordinary conversational
        // uses of “hope” remain conversation.
        if let target = narrowlyRepairedDirectOpenTarget(in: evidence) {
            return .directOpen(target)
        }
        if let target = directOpenTarget(in: evidence) {
            return .directOpen(target)
        }
        if let route = simpleApplicationControlRoute(in: evidence) {
            return route
        }
        if let action = deterministicDesktopAction(in: evidence) {
            return .desktop(action)
        }
        if sightOnlyIntent(in: evidence) {
            return .sightOnlyVisual
        }
        if visualComputerTaskIntent(in: evidence) {
            return .visualComputerTask
        }
        return .none
    }

    /// Returns only narrow domain capabilities that should categorically win
    /// over visual computer use.
    public static func directCapability(
        for finalizedOwnerTranscript: String
    ) -> NativeCapabilityRoute? {
        let decision = route(finalizedOwnerTranscript: finalizedOwnerTranscript)
        return decision.isDirectDomainCapability ? decision : nil
    }

    /// Advisory optimization for `computer_task`: every narrower route is
    /// returned, including a deterministic macOS action or sight-only request.
    /// ToolRegistry may try this path first, but a trusted owner-audio-bound
    /// visual task is not denied merely because this parser prefers another
    /// route or recognizes none.
    public static func preferredAlternativeToComputerTask(
        for finalizedOwnerTranscript: String
    ) -> NativeCapabilityRoute? {
        let decision = route(finalizedOwnerTranscript: finalizedOwnerTranscript)
        switch decision.kind {
        case .visualComputerTask, .none:
            return nil
        default:
            return decision
        }
    }

    /// Resolves the one native desktop action authorized by the finalized
    /// owner turn. ToolRegistry deliberately treats this as the sole desktop
    /// action authority: a model-proposed neighboring action can be corrected
    /// here, but it can never widen a conversational or negated turn into an
    /// actuation.
    public static func resolvedDesktopAction(
        for finalizedOwnerTranscript: String
    ) -> NativeDesktopAction? {
        let decision = route(finalizedOwnerTranscript: finalizedOwnerTranscript)
        switch decision.kind {
        case .deterministicDesktopAction, .textEditWrite:
            return decision.preferredAction.flatMap(NativeDesktopAction.init(rawValue:))
        default:
            return nil
        }
    }

    /// Returns a fixed, non-executable application display name only when the
    /// same owner transcript deterministically resolves to app activation.
    /// This lets a misrouted computer task remain fully native without trusting
    /// a model-invented application argument.
    public static func resolvedDesktopApplicationName(
        for finalizedOwnerTranscript: String
    ) -> String? {
        guard resolvedDesktopAction(for: finalizedOwnerTranscript) == .activateApplication else {
            return nil
        }
        return resolvedDesktopTargetApplicationName(for: finalizedOwnerTranscript)
    }

    /// Resolves an explicitly named application for any deterministic desktop
    /// request, not just app activation. Browser shortcuts therefore stay
    /// bound to "Chrome" or "Safari" in the owner's words even if focus moves
    /// or the model proposes a different application argument.
    public static func resolvedDesktopTargetApplicationName(
        for finalizedOwnerTranscript: String
    ) -> String? {
        let decision = route(
            finalizedOwnerTranscript: finalizedOwnerTranscript
        )
        guard let action = decision.preferredAction.flatMap(
            NativeDesktopAction.init(rawValue:)
        ) else {
            return nil
        }
        if let preferredTarget = decision.preferredTarget,
           !preferredTarget.isEmpty {
            return preferredTarget
        }
        return Evidence(finalizedOwnerTranscript).targetApplicationName(for: action)
    }

    /// Returns a fixed destination only for a clearly requested, supported
    /// owner-facing web surface. No model-proposed URL participates in this
    /// decision.
    public static func resolvedOpenTarget(
        for finalizedOwnerTranscript: String
    ) -> String? {
        let decision = route(finalizedOwnerTranscript: finalizedOwnerTranscript)
        guard decision.kind == .directOpen else { return nil }
        return decision.preferredTarget
    }

    private static func directOpenTarget(in evidence: Evidence) -> String? {
        guard evidence.isDirectActionRequest,
              !evidence.isHypothetical,
              !evidence.containsAny([
                "do not open", "don t open", "dont open", "never open",
                "not yet", "maybe later", "open that video", "open the video",
                "open that link", "open the link", "play that video", "play the video",
                "show me if", "show me whether",
              ]) else { return nil }

        let openLanguage = ["open", "open up", "go to", "bring up", "launch", "show"]
        guard evidence.commandStartsWithAny(openLanguage) else { return nil }

        if evidence.contains("youtube") {
            return "https://www.youtube.com/"
        }
        if evidence.contains("gmail") {
            return "https://mail.google.com/"
        }
        if evidence.containsAny(["outlook", "hotmail"]) {
            return "https://outlook.office.com/mail/"
        }
        return nil
    }

    private static func narrowlyRepairedDirectOpenTarget(
        in evidence: Evidence
    ) -> String? {
        let words = evidence.normalized.split(separator: " ").map(String.init)
        guard words.count >= 3,
              words.count <= 6,
              words[0] == "hope",
              ["on", "up"].contains(words[1]) else { return nil }
        if words.dropFirst(2).contains("youtube") {
            return "https://www.youtube.com/"
        }
        if words.dropFirst(2).contains("gmail") {
            return "https://mail.google.com/"
        }
        if words.dropFirst(2).contains(where: { ["outlook", "hotmail"].contains($0) }) {
            return "https://outlook.office.com/mail/"
        }
        return nil
    }

    /// A single explicitly named application does not require pixels or a
    /// model-driven screen loop. Preserve the owner's bounded app name as the
    /// native target. Compound requests were already claimed by the visual
    /// route above, so “open Figma and click New” remains closed-loop visual.
    private static func simpleApplicationControlRoute(
        in evidence: Evidence
    ) -> NativeCapabilityRoute? {
        guard evidence.isDirectActionRequest,
              !evidence.isHypothetical,
              !evidence.containsKnownApplication else { return nil }
        var words = evidence.requestStem.split(separator: " ").map(String.init)
        let commands: [([String], NativeDesktopAction)] = [
            (["switch", "to"], .activateApplication),
            (["bring", "up"], .activateApplication),
            (["open", "up"], .activateApplication),
            (["open"], .activateApplication),
            (["launch"], .activateApplication),
            (["activate"], .activateApplication),
            (["hide"], .hideFrontApplication),
            (["minimize"], .minimizeAllWindows),
            (["minimise"], .minimizeAllWindows),
            (["close"], .closeAllWindows),
        ]
        guard let match = commands.first(where: { command, _ in
            words.starts(with: command)
        }) else { return nil }
        words.removeFirst(match.0.count)

        let trailingModifiers: Set<String> = [
            "please", "now", "right", "for", "me", "app", "application",
        ]
        while let last = words.last,
              trailingModifiers.contains(last) {
            words.removeLast()
        }
        while let first = words.first,
              ["a", "an", "the", "my"].contains(first) {
            words.removeFirst()
        }
        let disallowedTargets: Set<String> = [
            "all", "everything", "window", "windows", "tab", "tabs",
            "desktop", "settings", "system", "page", "website", "browser",
            "file", "files", "folder", "folders", "document", "documents",
            "video", "link", "door", "heart", "mind", "conversation",
            "discussion", "gmail", "outlook", "youtube",
            // Apple Notes is migrated to Realtime's typed intent proposal and
            // must never fall back to this natural-language grammar.
            "notes",
            "this", "that", "current", "front",
        ]
        guard (1...4).contains(words.count),
              !words.contains(where: disallowedTargets.contains),
              !evidence.containsAny([
                " and ", " then ", "after that", "click", "tap", "press",
                "type", "enter", "scroll", "drag", "search", "play",
              ]) else { return nil }
        return .desktop(
            match.1,
            target: words.joined(separator: " ")
        )
    }

    private static func compoundVisualComputerTaskIntent(in evidence: Evidence) -> Bool {
        guard evidence.isDirectActionRequest,
              !evidence.isHypothetical,
              evidence.containsAny(["and", "then", "after that", "and then"]),
              !evidence.containsAny([
                "do not", "don t", "dont", "never", "not yet", "maybe later",
              ]) else { return false }

        let beginsUICommand = evidence.commandStartsWithAny([
            "open", "open up", "launch", "go to", "bring up", "switch to", "show",
            "close", "shut", "exit", "get rid", "x out", "pause", "resume",
            "unpause", "minimize", "minimise", "hide", "move", "resize",
            "click", "tap", "press", "select", "choose", "pick", "type",
            "enter", "scroll", "change", "set", "turn", "enable", "disable",
        ])
        let explicitlyNamesUISurface = evidence.containsAny([
            "youtube", "gmail", "outlook", "chrome", "safari", "browser",
            "settings", "system settings", "wallpaper", "desktop", "app", "application",
        ]) || evidence.containsKnownApplication
        // A short proper-name target such as "Figma" is still an application
        // even though it is not in Aurora's fixed native-app allowlist. The
        // following UI mutation keeps the route visual instead of truncating
        // the request to a best-effort app activation.
        let stemWords = evidence.requestStem.split(separator: " ").map(String.init)
        let hasShortNamedOpenTarget = evidence.commandStartsWithAny([
            "open", "open up", "launch", "go to", "bring up", "switch to", "show",
        ])
            && stemWords.count >= 2
            && !["a", "an", "the", "my", "this", "that", "your"].contains(stemWords[1])
            && !evidence.containsAny([
                "open the door", "open your heart", "open your mind",
                "open a conversation", "open the discussion",
            ])
        let opensUISurface = beginsUICommand
            && (explicitlyNamesUISurface || hasShortNamedOpenTarget)
        let followsWithUIChange = evidence.containsAny([
            "and click", "then click", "and tap", "then tap", "and press", "then press",
            "and select", "then select", "and choose", "then choose", "and pick", "then pick",
            "and play", "then play", "and search", "then search", "and type", "then type",
            "and enter", "then enter", "and scroll", "then scroll", "and change", "then change",
            "and set", "then set", "and edit", "then edit", "and move", "then move",
            "and drag", "then drag", "and open", "then open", "and launch", "then launch",
            "and close", "then close", "and minimize", "then minimize",
            "and minimise", "then minimise", "and hide", "then hide",
            "and pause", "then pause", "and resume", "then resume",
            "after that click", "after that tap", "after that press",
            "after that select", "after that choose", "after that pick",
            "after that play", "after that search", "after that type",
            "after that enter", "after that scroll", "after that change",
            "after that set", "after that edit", "after that move",
            "after that drag", "after that open", "after that launch",
            "after that close", "after that minimize", "after that minimise",
            "after that hide", "after that pause", "after that resume",
        ])
        let singlePreservationAction = evidence.contains("gmail")
            && evidence.contains("close")
            && evidence.contains("tabs")
            && evidence.containsAny(["keep gmail", "leave gmail", "except gmail", "except for gmail"])
        return !singlePreservationAction && opensUISurface && followsWithUIChange
    }

    private static func reminderIntent(in evidence: Evidence) -> Bool {
        guard evidence.isDirectActionRequest,
              !evidence.isHypothetical,
              evidence.commandStartsWithAny([
                "set", "create", "add", "make", "put", "remind",
              ]),
              !evidence.containsAny([
            "do not remind", "don t remind", "dont remind", "never remind",
            "do not set a reminder", "don t set a reminder", "dont set a reminder",
            "cancel the reminder", "cancel my reminder", "delete the reminder",
            "remove the reminder", "i do not want a reminder", "i don t want a reminder",
            "i dont want a reminder", "not asking you to remind", "how to set a reminder",
            "how do i set a reminder", "how can i set a reminder",
            "explain how to set a reminder", "tell me how to set a reminder",
        ]) else { return false }

        if evidence.containsAny(["reminder", "reminders"])
            && evidence.containsAny(["set", "create", "add", "make", "put"]) {
            return evidence.isRequestLike
        }

        // "Remind me what I said" is a memory question, not a scheduled
        // reminder. Scheduling language must include a task or time boundary.
        return evidence.contains("remind me")
            && evidence.containsAny([
                "remind me to", "remind me at", "remind me on", "remind me in",
                "remind me today", "remind me tomorrow", "remind me tonight",
                "remind me this morning", "remind me this afternoon",
                "remind me this evening", "remind me when",
            ])
            && evidence.isRequestLike
    }

    private static func currentWebResearchIntent(in evidence: Evidence) -> Bool {
        guard evidence.isRequestLike,
              !evidence.containsAny([
                "do not search", "don t search", "dont search", "never search",
                "do not look up", "don t look up", "dont look up",
                "stop searching", "cancel the search", "not asking you to search",
            ]) else { return false }

        let explicitlyAboutLocalMail = evidence.containsAny([
            "search my email", "search my emails", "search my inbox", "search gmail",
            "search my gmail", "search outlook", "search my outlook", "find an email",
            "find the email", "look through my email", "look through my inbox",
        ])
        let hasMailReference = evidence.containsAny([
            "email", "emails", "gmail", "inbox", "mailbox", "outlook", "hotmail",
            "mail account", "mail connection", "email connection", "email draft",
        ])
        let explicitlyAboutLocalFiles = evidence.containsAny([
            "search my files", "search my computer", "search my mac", "find the file",
            "find a file", "look through my files", "search this folder",
        ])
        let explicitlyLocalComputerAction = evidence.containsAny([
            "close", "minimize", "minimise", "hide", "refresh", "reload",
            "reopen", "go back", "go forward", "new tab", "show desktop",
            "move", "resize", "maximize", "maximise", "full screen", "fullscreen",
            "copy", "paste", "save", "rename", "delete", "volume", "mute",
            "brightness", "toggle", "turn on", "turn off", "enable", "disable",
            "install", "download", "upload",
        ]) && evidence.containsAny([
            "tab", "tabs", "window", "windows", "browser", "chrome", "safari",
            "app", "application", "desktop", "mac", "screen", "file", "folder",
            "item", "finder", "system settings", "settings", "control", "toggle",
            "volume", "brightness", "wifi", "wi fi", "bluetooth", "website", "web page",
        ])
        if explicitlyLocalComputerAction { return false }
        if evidence.contains("youtube"),
           evidence.commandStartsWith("search")
                || evidence.containsAny(["search for", "find on youtube"]) {
            return false
        }

        let unmistakablyWebResearch = evidence.containsAny([
            "search the web", "search online", "search the internet", "web search",
            "google this", "google that", "google for", "find out online", "check online",
        ])
        let genericResearchRequest = evidence.containsAny([
            "look it up", "look this up", "look that up", "look up",
            "research this", "research that", "research the",
            "search for", "search about", "find out",
        ]) && !hasMailReference
            && !explicitlyAboutLocalMail
            && !explicitlyAboutLocalFiles
        let explicitWebResearch = unmistakablyWebResearch || genericResearchRequest
        if explicitWebResearch { return true }
        if hasMailReference || explicitlyAboutLocalFiles { return false }

        // Temporal words do not by themselves make a request web research.
        // Aurora's present inner state and the owner's live screen remain in
        // the voice/vision paths even when the owner says “right now”.
        if evidence.containsAny([
            "how are you", "how do you feel", "how are you feeling",
            "what are you feeling", "what are you thinking",
            "what do you see", "what is on my screen", "what s on my screen",
            "whats on my screen", "on the screen right now",
            "can you see my screen", "look at my screen", "read my screen",
        ]) {
            return false
        }

        let currentInformation = evidence.containsAny([
            "latest", "newest", "news", "headlines", "top stories", "breaking",
            "up to date", "up to the minute",
            "recent update", "recent updates", "still available",
            "weather", "forecast", "score", "standings", "stock price", "share price",
        ])
        if currentInformation { return true }

        // Present-tense event questions often omit words such as "news" or
        // "latest" (for example, "Why is Apple suing OpenAI?"). Keep this list
        // about externally changing events rather than routing static trivia.
        let eventLanguage = evidence.containsAny([
            "suing", "lawsuit", "announced", "launching", "released", "releasing",
            "acquired", "buying", "bought", "merger", "resigned", "stepped down",
            "elected", "charged", "indicted", "banned", "recall", "recalled",
            "shutdown", "shut down", "outage", "strike", "protest",
        ])
        let eventQuestion = evidence.containsAny([
            "why is", "why are", "why did", "what is", "what are", "what did",
            "who is", "who are", "when is", "when did", "how is", "how did",
            "did", "does", "has", "have", "is", "are", "tell me about",
        ])
        return eventLanguage && eventQuestion
    }

    private static func mailIntent(in evidence: Evidence) -> Bool {
        guard evidence.isRequestLike,
              !evidence.isHypothetical,
              !evidence.containsAny([
                "do not send", "don t send", "dont send", "never send",
                "do not check my email", "don t check my email", "dont check my email",
                "do not read", "don t read", "dont read", "stop checking my email",
                "cancel the email", "delete the reminder email",
            ]) else { return false }

        let hasMailReference = evidence.containsAny([
            "email", "emails", "gmail", "inbox", "mail", "mailbox", "outlook", "hotmail",
            "mail account", "mail connection", "email connection", "email draft",
        ])
        guard hasMailReference else {
            return evidence.isDirectActionRequest && evidence.containsAny([
                "send the draft", "send that draft", "send this draft",
                "go ahead and send the draft",
            ])
        }

        let personalMailboxContext = evidence.containsAny([
            "my email", "my emails", "my inbox", "my mail", "my mailbox",
            "gmail", "outlook", "hotmail", "that email", "this email",
            "the email", "an email from", "emails from", "latest email",
            "recent email", "new email", "new emails", "email account",
            "mail account", "email connection", "mail connection",
        ])

        if evidence.contains("send") {
            return evidence.commandStartsWithAny(["send"])
        }
        if evidence.containsAny(["compose", "draft", "reply", "respond", "write"]) {
            return evidence.commandStartsWithAny([
                "compose", "draft", "reply", "respond", "write",
            ])
        }

        return personalMailboxContext && evidence.containsAny([
            "check", "search", "find", "look for", "show", "read", "open the email",
            "open that email", "summarize", "tell me what", "do i have", "any new",
            "latest email", "recent email", "from", "compose", "draft", "reply",
            "respond", "write", "send", "connection", "connected", "connect",
            "available", "access", "status", "configured", "linked",
        ])
    }

    private static func textEditWriteIntent(in evidence: Evidence) -> Bool {
        guard evidence.isDirectActionRequest,
              !evidence.isHypothetical,
              evidence.containsAny([
                "textedit", "text edit", "blank text document", "blank document",
              ]),
              evidence.containsAny(["type", "write", "enter", "put"]),
              !evidence.containsAny([
                "do not type", "don t type", "dont type",
                "do not write", "don t write", "dont write",
                "never type", "never write", "not yet", "maybe later",
              ]) else { return false }

        // A direct native write is only appropriate when the owner actually
        // dictated content. Requests that merely open TextEdit remain ordinary
        // app-open actions, and ambiguous writing requests stay conversational.
        let words = evidence.requestStem.split(separator: " ").map(String.init)
        let commandWords: Set<String> = ["type", "write", "enter", "put"]
        let fillerWords: Set<String> = [
            "a", "an", "the", "this", "that", "it", "in", "into", "on",
            "text", "edit", "textedit", "document", "file", "words", "phrase",
            "message", "saying", "says", "and", "then", "please",
        ]
        return words.indices.contains { index in
            commandWords.contains(words[index])
                && words.dropFirst(index + 1).contains { !fillerWords.contains($0) }
        }
    }

    private static func deterministicDesktopAction(in evidence: Evidence) -> NativeDesktopAction? {
        guard evidence.isDirectActionRequest,
              !evidence.isHypothetical else { return nil }

        let mediaContext = evidence.containsAny([
            "video", "youtube", "playback", "what i m watching",
            "what im watching", "the player", "this player",
        ])
        if mediaContext,
           evidence.commandStartsWithAny(["pause"]),
           !evidence.containsAny([
               "do not pause", "don t pause", "dont pause", "never pause",
               "not yet", "maybe later",
           ]),
           evidence.containsAny([
               "pause the video", "pause this video", "pause my video",
               "pause youtube", "pause playback", "pause what i m watching",
               "pause what im watching", "pause it",
           ]) {
            return .pauseCurrentMedia
        }
        if mediaContext,
           evidence.commandStartsWithAny(["resume", "unpause", "continue"]),
           !evidence.containsAny([
               "do not resume", "don t resume", "dont resume",
               "do not unpause", "don t unpause", "dont unpause",
               "not yet", "maybe later",
           ]),
           evidence.containsAny([
               "resume the video", "resume this video", "resume my video",
               "resume youtube", "resume the youtube video", "resume playback", "unpause the video",
               "unpause this video", "continue the video", "continue playback",
           ]) {
            return .resumeCurrentMedia
        }

        let negatesCloseOtherTabs = evidence.containsAny([
            "do not close the other", "don t close the other", "dont close the other",
            "do not close other", "don t close other", "dont close other",
            "do not close all tabs", "don t close all tabs", "dont close all tabs",
        ])
        let preservesGmail = evidence.containsAny([
                "except gmail", "except for gmail", "except my gmail",
                "except for my gmail", "besides gmail", "but gmail",
                "keep gmail", "leave gmail", "gmail open", "do not close gmail",
                "don t close gmail", "dont close gmail",
            ])
        let asksToCloseOtherTabs = !negatesCloseOtherTabs
            && evidence.commandStartsWithAny(["close", "shut", "exit", "get rid", "x out", "keep"])
            && evidence.contains("close")
            && evidence.containsAny(["tab", "tabs"])
            && preservesGmail
        let explicitlyNamedBrowser = evidence.targetApplicationName(
            for: .closeOtherTabsExceptGmail
        )
        if asksToCloseOtherTabs,
           explicitlyNamedBrowser == nil || explicitlyNamedBrowser == "Google Chrome" {
            return .closeOtherTabsExceptGmail
        }

        guard !evidence.containsAny([
            "do not minimize", "don t minimize", "dont minimize",
            "do not close", "don t close", "dont close", "never close",
            "do not hide", "don t hide", "dont hide",
            "do not open", "don t open", "dont open",
            "do not refresh", "don t refresh", "dont refresh",
            "not yet", "maybe later", "what if", "should i", "should we",
        ]) else { return nil }

        if evidence.commandStartsWithAny(["show", "go", "get"]),
           evidence.containsAny(["show desktop", "show my desktop", "go to desktop", "get to desktop"]) {
            return .showDesktop
        }

        let asksToMinimize = evidence.commandStartsWithAny(["minimize", "minimise"])
            && evidence.containsAny(["minimize", "minimise"])
        if asksToMinimize {
            if evidence.hasBroadExclusion { return nil }
            let explicitlyCurrentApplication = evidence.containsAny([
                "this app", "current app", "this application", "current application",
                "this browser", "current browser", "chrome window", "chrome windows",
                "chrome tab", "chrome tabs", "safari window", "safari windows",
                "safari tab", "safari tabs", "in chrome", "in safari",
            ])
            let broadScope = evidence.containsAny([
                "everything", "all windows", "all my windows", "all the windows",
                "every window", "all tabs", "all my tabs", "all the tabs", "every tab",
                "all chrome tabs", "all the chrome tabs", "every chrome tab",
                "all safari tabs", "all the safari tabs", "every safari tab",
                "all apps", "every app", "on my mac", "see my wallpaper", "show my wallpaper",
            ])
            if broadScope && !explicitlyCurrentApplication {
                return .minimizeEverything
            }
            if broadScope {
                return .minimizeAllWindows
            }
            return .minimizeFrontWindow
        }

        if evidence.commandStartsWithAny(["reopen", "bring"]),
           evidence.containsAny(["reopen tab", "reopen the tab", "reopen closed tab", "bring that tab back"]) {
            return .reopenClosedTab
        }
        if evidence.commandStartsWithAny(["new", "open"]),
           evidence.containsAny(["new tab", "open a tab", "open another tab"]) {
            return .newTab
        }
        if evidence.requestsClosingCurrentTab {
            return .closeTab
        }
        if evidence.commandStartsWithAny(["close", "shut", "exit"]),
           evidence.contains("close"),
           evidence.containsAny(["all windows", "all the windows", "every window"]),
           !evidence.hasBroadExclusion,
           evidence.targetApplicationName(for: .closeAllWindows) != nil {
            return .closeAllWindows
        }
        if evidence.requestsClosingCurrentWindow {
            return .closeFrontWindow
        }
        if evidence.commandStartsWithAny(["hide", "get"])
            && (evidence.containsAny(["hide this app", "hide the app", "hide current app", "get this out of the way"])
                || (evidence.contains("hide") && evidence.containsKnownApplication)) {
            return .hideFrontApplication
        }
        if evidence.commandStartsWithAny(["open", "show", "go", "bring"]),
           evidence.containsAny(["open settings", "open system settings", "show settings", "show system settings", "go to settings", "bring up settings"]) {
            return .openSettings
        }
        if evidence.commandStartsWithAny(["go"]),
           evidence.containsAny(["go back", "previous page"]) {
            return .back
        }
        if evidence.commandStartsWithAny(["go"]),
           evidence.containsAny(["go forward", "next page"]) {
            return .forward
        }
        if evidence.commandStartsWithAny(["refresh", "reload"]),
           evidence.containsAny(["refresh", "reload the page", "reload this page", "reload current page"]) {
            return .refresh
        }
        if evidence.containsAny([
            "switch to", "bring up", "activate", "launch",
            "open the app", "open the application",
        ])
            || (evidence.commandStartsWith("open") && evidence.containsKnownApplication) {
            return .activateApplication
        }
        return nil
    }

    private static func sightOnlyIntent(in evidence: Evidence) -> Bool {
        guard evidence.isRequestLike,
              !evidence.containsAny([
                "do not look", "don t look", "dont look", "do not read the screen",
                "don t read the screen", "dont read the screen", "stop looking",
            ]),
              !evidence.containsAny(Evidence.visualInteractionPhrases) else {
            return false
        }

        return evidence.containsAny([
            "what do you see", "tell me what you see", "what is on my screen",
            "what s on my screen", "whats on my screen", "what is on the screen",
            "what s on the screen", "whats on the screen", "can you see this",
            "can you see that", "can you see my screen", "do you see this",
            "do you see that", "look at my screen", "look at the screen",
            "look at this screen", "look at this page", "look at the page",
            "read my screen", "read the screen", "read this page", "read the page",
            "what does this page say", "what does the screen say",
            "see what is on my screen", "see what s on my screen",
            "see whats on my screen", "see what is on the screen",
            "see what s on the screen", "see whats on the screen",
        ])
    }

    private static func visualComputerTaskIntent(in evidence: Evidence) -> Bool {
        guard evidence.isDirectActionRequest,
              !evidence.isHypothetical,
              !evidence.containsAny([
                "do not click", "don t click", "dont click", "never click",
                "do not tap", "don t tap", "dont tap", "do not press",
                "don t press", "dont press", "do not type", "don t type", "dont type",
                "do not drag", "don t drag", "dont drag", "do not scroll",
                "don t scroll", "dont scroll", "stop clicking", "stop the task",
                "do not move", "don t move", "dont move",
                "do not resize", "don t resize", "dont resize",
                "do not maximize", "don t maximize", "dont maximize",
                "do not copy", "don t copy", "dont copy",
                "do not paste", "don t paste", "dont paste",
                "do not save", "don t save", "dont save",
                "do not rename", "don t rename", "dont rename",
                "do not delete", "don t delete", "dont delete",
                "do not install", "don t install", "dont install",
                "do not download", "don t download", "dont download",
                "do not upload", "don t upload", "dont upload",
              ]) else { return false }

        if evidence.contains("youtube"),
           evidence.commandStartsWith("search")
                || evidence.containsAny(["search for", "find on youtube"]) {
            return true
        }
        if evidence.commandStartsWithAny(["close", "shut", "exit", "get rid", "x out"]),
           evidence.contains("close"), evidence.contains("tabs"),
           evidence.containsAny(["all", "every", "the tabs"])
            && evidence.containsAny(["chrome", "safari", "browser"]) {
            return true
        }
        let broadWindowMutation = evidence.commandStartsWithAny([
            "close", "shut", "exit", "minimize", "minimise",
        ]) && evidence.containsAny([
            "all windows", "all the windows", "every window", "everything",
        ])
        if broadWindowMutation { return true }

        let directPixelInteraction = evidence.containsAny([
            "click", "double click", "right click", "tap", "drag", "scroll",
            "press the button", "press that button", "press this button",
            "select the button", "select that", "choose that", "choose the",
            "type into", "type in the", "enter into", "fill out", "fill in",
        ])
        if directPixelInteraction,
           evidence.commandStartsWithAny([
            "click", "double click", "right click", "tap", "drag", "scroll",
            "press", "select", "choose", "type", "enter", "fill",
           ]) {
            return true
        }

        let typesIntoVisibleInterface = evidence.containsAny(["type", "write", "enter"])
            && evidence.containsAny([
                "website", "web page", "page", "form", "search box", "search bar", "text field",
                "input", "browser", "chat box", "message box",
            ])
        if typesIntoVisibleInterface,
           evidence.commandStartsWithAny(["type", "write", "enter", "fill"]) {
            return true
        }

        let explicitMacUI = evidence.containsAny([
            "on my mac", "on the mac", "app", "application", "system settings",
            "wallpaper", "desktop", "browser", "window", "menu", "dock",
        ])
        let words = evidence.requestStem.split(separator: " ").map(String.init)
        let immediateOpenModifiers: Set<String> = [
            "right", "now", "please", "for", "me", "at", "once",
        ]
        let shortNamedOpenTarget = words.count >= 2
            && !["a", "an", "the", "my", "this", "that", "your"].contains(words[1])
            && words.dropFirst(2).allSatisfy(immediateOpenModifiers.contains)
        let launchesUnknownApplication = evidence.commandStartsWithAny([
            "launch", "switch to", "bring up",
        ])
        let opensUnknownApplication = evidence.commandStartsWith("open")
            && (explicitMacUI || shortNamedOpenTarget)
            && !evidence.containsAny([
                "door", "window in the room", "your heart", "your mind", "up about",
                "report", "document", "file", "folder", "pdf", "photo", "picture",
                "email", "message", "conversation", "discussion",
            ])
        let changesMacInterface = evidence.containsAny([
            "change my wallpaper", "change the wallpaper", "set my wallpaper",
            "change desktop background", "set desktop background",
        ])
        if launchesUnknownApplication
            || opensUnknownApplication
            || (changesMacInterface && evidence.commandStartsWithAny(["change", "set"])) {
            return true
        }

        // Catch the remaining ordinary Mac interactions that require seeing
        // and manipulating the current UI. These gates deliberately require
        // a visible-computer noun for ambiguous verbs, so conversational uses
        // such as "move the couch" or "delete that thought" stay with Aurora.
        let visibleMacContext = evidence.containsAny([
            "on my mac", "on the mac", "my mac", "on my screen", "on the screen",
            "this window", "that window", "the window", "current window",
            "this app", "that app", "the app", "current app", "application",
            "system settings", "settings pane", "settings page", "desktop", "finder",
            "this file", "that file", "the file", "selected file", "visible file",
            "this item", "that item", "the item", "selected item", "visible item",
            "this folder", "that folder", "the folder", "selected folder",
            "this button", "that button", "this control", "that control", "the toggle",
            "menu bar", "dock", "browser", "web page", "website",
        ])
        let windowGeometryRequest = evidence.commandStartsWithAny([
            "move", "resize", "maximize", "maximise", "make", "put",
            "full screen", "fullscreen",
        ])
            && (evidence.containsAny([
                "window", "this window", "that window", "current window",
                "gmail", "outlook", "chrome", "safari", "browser", "app", "application",
            ]) || evidence.containsKnownApplication)
            && evidence.containsAny([
                "move", "resize", "maximize", "maximise", "full screen", "fullscreen",
                "left side", "right side", "top half", "bottom half",
            ])
        let visibleItemMutation = visibleMacContext
            && evidence.commandStartsWithAny([
                "copy", "paste", "save", "rename", "delete", "remove", "move",
            ])
            && evidence.containsAny([
                "copy", "paste", "save", "save as", "rename", "delete", "move",
            ])
        let systemControlRequest = evidence.commandStartsWithAny([
            "volume", "turn", "increase", "lower", "mute", "unmute",
        ]) && evidence.containsAny([
            "volume up", "turn the volume up", "increase the volume",
            "volume down", "turn the volume down", "lower the volume",
            "mute my mac", "mute the mac", "mute the volume", "unmute my mac",
            "turn the brightness up", "increase the brightness", "brightness up",
            "turn the brightness down", "lower the brightness", "brightness down",
        ])
        let explicitToggleRequest = visibleMacContext
            && evidence.commandStartsWithAny(["toggle", "turn", "enable", "disable"])
            && (evidence.containsAny(["toggle", "turn on", "turn off", "enable", "disable"])
                || (evidence.contains("turn") && evidence.containsAny(["on", "off"])))
            && evidence.containsAny([
                "setting", "control", "toggle", "wifi", "wi fi", "bluetooth",
                "airplane mode", "focus mode", "dark mode", "night shift",
            ])
        let visibleTransferOrInstall = evidence.commandStartsWithAny([
            "install", "download", "upload",
        ]) && evidence.containsAny([
            "install", "download", "upload",
        ]) && (visibleMacContext || evidence.containsKnownApplication)
        if windowGeometryRequest
            || visibleItemMutation
            || systemControlRequest
            || explicitToggleRequest
            || visibleTransferOrInstall {
            return true
        }

        return evidence.commandStartsWithAny([
            "open", "play", "pick", "choose", "use", "navigate", "interact",
        ]) && evidence.containsAny([
            "open that video", "open the video", "play that video", "play the video",
            "pick a video", "choose a video", "open that link", "open the link",
            "use the menu", "navigate through", "interact with the page",
        ])
    }
}

private extension NativeCapabilityRouter {
    struct Evidence {
        static let visualInteractionPhrases = [
            "click", "double click", "right click", "tap", "drag", "scroll",
            "press", "select", "choose", "type into", "type in", "enter into",
            "fill out", "fill in", "open that video", "open the video",
            "play that video", "play the video", "open that link", "open the link",
        ]

        let normalized: String
        let requestStem: String
        let isRequestLike: Bool

        init(_ transcript: String) {
            let bounded = String(transcript.prefix(4_000))
            let normalizedTranscript = bounded
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            normalized = normalizedTranscript

            let padded = " " + normalizedTranscript + " "
            let requestLeadIns = [
                " can you ", " could you ", " would you ", " will you ",
                " would you mind ", " please ", " i want you to ", " i need you to ",
                " i d like you to ", " go ahead and ", " aurora can you ",
                " aurora could you ", " aurora please ",
            ]
            let imperativeOrQuestionPrefixes = [
                "set", "create", "add", "make", "put", "remind", "search", "look",
                "research", "google", "find", "check", "show", "read", "open", "tell",
                "summarize", "compose", "draft", "reply", "respond", "write", "send",
                "minimize", "minimise", "close", "shut", "exit", "get", "x",
                "hide", "switch", "bring", "activate", "keep",
                "go", "refresh", "reload", "reopen", "click", "tap", "drag", "scroll",
                "press", "select", "choose", "type", "enter", "fill", "play", "pause",
                "resume", "unpause", "continue", "pick",
                "move", "resize", "maximize", "maximise", "fullscreen", "copy",
                "paste", "save", "rename", "delete", "remove", "volume", "mute",
                "unmute", "increase", "lower", "toggle", "turn", "enable", "disable",
                "install", "download", "upload",
                "navigate", "interact", "what", "whats", "why", "who", "when", "where",
                "how", "is", "are", "did", "does", "has", "have", "do",
            ]
            var requestStemWords = normalizedTranscript.split(separator: " ").map(String.init)
            let conversationalLeadIns: Set<String> = [
                "okay", "ok", "yeah", "yep", "yes", "so", "now", "aurora", "hey",
                "awesome", "alright", "cool", "great", "perfect", "well", "um", "uh",
            ]
            while let first = requestStemWords.first,
                  conversationalLeadIns.contains(first),
                  requestStemWords.count > 1 {
                requestStemWords.removeFirst()
            }
            let politeCommandPrefixes: [[String]] = [
                ["would", "you", "mind"], ["can", "you"], ["could", "you"],
                ["would", "you"], ["will", "you"], ["please"],
                ["i", "want", "you", "to"], ["i", "need", "you", "to"],
                ["i", "d", "like", "you", "to"], ["go", "ahead", "and"],
                ["i", "was", "wondering", "if", "you", "could"],
                ["would", "it", "be", "possible", "to"],
                ["do", "me", "a", "favor", "and"],
            ]
            let politeModifiers: Set<String> = [
                "please", "just", "kindly", "actually", "um", "uh",
            ]
            // A leading "no" can be a complete withdrawal or the natural
            // opening of a replacement command. Strip it only for the narrow
            // "No, <new imperative> instead" shape; standalone no/don't/leave
            // requests remain non-actuating.
            let replacementActionPrefixes: Set<String> = [
                "set", "create", "add", "make", "put", "remind",
                "compose", "draft", "reply", "respond", "write", "send",
                "minimize", "minimise", "close", "shut", "exit", "get",
                "hide", "switch", "bring", "activate", "open", "show",
                "go", "refresh", "reload", "reopen", "click", "tap", "drag",
                "scroll", "press", "select", "choose", "type", "enter", "fill",
                "play", "pause", "resume", "unpause", "continue", "pick",
                "move", "resize", "maximize", "maximise", "fullscreen", "copy",
                "paste", "save", "rename", "delete", "remove", "volume", "mute",
                "unmute", "increase", "lower", "toggle", "turn", "enable", "disable",
                "install", "download", "upload", "search", "find", "change",
                "navigate", "interact", "use",
            ]
            if requestStemWords.count >= 3,
               requestStemWords.first == "no",
               requestStemWords.contains("instead"),
               replacementActionPrefixes.contains(requestStemWords[1]) {
                requestStemWords.removeFirst()
            }
            // Spoken UI requests do not always put the action verb first.
            // “In the YouTube search bar, can you type in OpenAI?” is still a
            // direct visual-computer request, but the old leading-verb parser
            // treated it as conversation and later vetoed Realtime's correct
            // computer_task call. Rotate only a bounded, visibly locative
            // request into its embedded UI command. This does not rewrite
            // general clauses such as “In your opinion, can you tell me…”.
            let locativeOpenings: Set<String> = [
                "at", "in", "inside", "on", "within",
            ]
            let visibleUILocationWords: Set<String> = [
                "app", "application", "bar", "box", "browser", "button",
                "chat", "chrome", "control", "desktop", "dialog", "dock",
                "field", "finder", "form", "gmail", "input", "menu",
                "outlook", "page", "safari", "screen", "settings", "tab",
                "text", "website", "window", "youtube",
            ]
            let embeddedUIActions: Set<String> = [
                "change", "choose", "click", "drag", "enter", "fill",
                "move", "open", "pick", "play", "press", "resize",
                "scroll", "search", "select", "set", "tap", "toggle",
                "turn", "type", "write",
            ]
            let embeddedRequestLeadIns: [[String]] = [
                ["can", "you"], ["could", "you"], ["would", "you"],
                ["will", "you"], ["would", "you", "mind"], ["please"],
            ]
            if let first = requestStemWords.first,
               locativeOpenings.contains(first) {
                for leadIn in embeddedRequestLeadIns {
                    guard let leadInIndex = requestStemWords.indices.first(where: { index in
                        index > requestStemWords.startIndex
                            && requestStemWords.distance(
                                from: index,
                                to: requestStemWords.endIndex
                            ) > leadIn.count
                            && Array(
                                requestStemWords[index..<(index + leadIn.count)]
                            ) == leadIn
                    }) else { continue }
                    let locationWords = requestStemWords[..<leadInIndex]
                    let actionIndex = leadInIndex + leadIn.count
                    guard locationWords.contains(where: visibleUILocationWords.contains),
                          embeddedUIActions.contains(requestStemWords[actionIndex]) else {
                        continue
                    }
                    requestStemWords = Array(requestStemWords[actionIndex...])
                    break
                }
            }
            // Natural spoken requests commonly stack politeness markers:
            // “Could you please go ahead and close…”, or use a gerund after
            // “would you mind”. Peel those bounded markers repeatedly, then
            // normalize only the leading command word. This is intentionally
            // not a general language rewrite; it just makes equivalent owner
            // imperatives share one deterministic authorization shape.
            var removedLeadIn = true
            while removedLeadIn, requestStemWords.count > 1 {
                removedLeadIn = false
                if let prefix = politeCommandPrefixes.first(where: { prefix in
                    requestStemWords.count >= prefix.count
                        && Array(requestStemWords.prefix(prefix.count)) == prefix
                }) {
                    requestStemWords.removeFirst(prefix.count)
                    removedLeadIn = true
                }
                while let first = requestStemWords.first,
                      politeModifiers.contains(first),
                      requestStemWords.count > 1 {
                    requestStemWords.removeFirst()
                    removedLeadIn = true
                }
                if requestStemWords.starts(with: ["try", "to"]) {
                    requestStemWords.removeFirst(2)
                    removedLeadIn = true
                }
            }
            if let first = requestStemWords.first {
                let normalizedLeadingCommands = [
                    "closing": "close", "opening": "open",
                    "minimizing": "minimize", "minimising": "minimise",
                    "hiding": "hide", "pausing": "pause",
                    "resuming": "resume", "clicking": "click",
                    "typing": "type", "scrolling": "scroll",
                    "sending": "send", "writing": "write",
                    "setting": "set", "creating": "create", "adding": "add",
                    "refreshing": "refresh", "reloading": "reload",
                    "switching": "switch", "bringing": "bring",
                    "activating": "activate", "selecting": "select",
                    "choosing": "choose", "reopening": "reopen",
                    "launching": "launch", "entering": "enter",
                    "filling": "fill", "moving": "move", "resizing": "resize",
                    "deleting": "delete", "renaming": "rename",
                ]
                if let command = normalizedLeadingCommands[first] {
                    requestStemWords[0] = command
                }
            }
            let stem = requestStemWords.joined(separator: " ")
            requestStem = stem
            isRequestLike = requestLeadIns.contains(where: padded.contains)
                || imperativeOrQuestionPrefixes.contains(where: { prefix in
                    stem == prefix || stem.hasPrefix(prefix + " ")
                })
        }

        var isHypothetical: Bool {
            containsAny([
                "what if", "should i", "should we", "would you ever", "could you ever",
                "theoretically", "hypothetically", "how would you", "how could you",
                "can you explain how", "could you explain how", "tell me how to",
                "show me how", "show me where",
                "remind me how", "search how to", "explain how to",
                "walk me through how", "help me understand how",
            ])
        }

        var isDirectActionRequest: Bool {
            let actionPrefixes = [
                "set", "create", "add", "make", "put", "remind",
                "compose", "draft", "reply", "respond", "write", "send",
                "minimize", "minimise", "close", "shut", "exit", "get rid",
                "x out", "hide", "switch", "bring", "activate", "open", "show",
                "go", "refresh", "reload", "reopen", "click", "tap", "drag",
                "scroll", "press", "select", "choose", "type", "enter", "fill",
                "play", "pause", "resume", "unpause", "continue", "pick", "keep",
                "move", "resize", "maximize", "maximise", "fullscreen", "copy",
                "paste", "save", "rename", "delete", "remove", "volume", "mute",
                "unmute", "increase", "lower", "toggle", "turn", "enable", "disable",
                "install", "download", "upload", "search", "find", "change",
                "navigate", "interact", "use",
            ]
            return actionPrefixes.contains(where: commandStartsWith)
        }

        var isStandaloneCancellation: Bool {
            let exact = [
                "stop", "stop that", "cancel", "cancel that", "never mind", "nevermind",
                "forget it", "leave it", "don t do that", "dont do that", "do not do that",
                "no thanks", "wait", "hold on",
            ]
            if exact.contains(normalized) { return true }

            let cancellationPrefixes = [
                "never mind", "nevermind", "cancel that", "forget it", "leave it",
                "stop that", "do not do that", "don t do that", "dont do that",
            ]
            let startsWithCancellation = cancellationPrefixes.contains(where: {
                normalized.hasPrefix($0 + " ")
            })
            let introducesReplacement = containsAny([
                "instead", "actually", "but set", "but create", "but search",
                "but check", "but open", "then",
            ])
            return startsWithCancellation && !introducesReplacement
        }

        var isNegatedCommand: Bool {
            commandStartsWithAny(["not", "do not", "don t", "dont", "never"])
        }

        /// A finalized utterance can withdraw its own leading command. The
        /// later correction wins: Aurora must not execute the first clause and
        /// pretend the owner's "no" arrived as a separate turn. Keep these
        /// phrases narrow so harmless immediacy such as "no need to ask" does
        /// not disable an otherwise direct request.
        var withdrawsDirectActionInSameTurn: Bool {
            guard isDirectActionRequest else { return false }
            if containsAny([
                "no don t", "no dont", "no do not",
                "wait don t", "wait dont", "wait do not",
                "actually don t", "actually dont", "actually do not",
                "no keep it open", "no leave it open",
                "actually keep it open", "actually leave it open",
                "never mind", "nevermind", "scratch that", "cancel that",
                "forget it", "no wait", "wait no", "on second thought",
                "changed my mind", "change my mind",
            ]) {
                return true
            }

            let words = requestStem.split(separator: " ").map(String.init)
            if let last = words.last,
               ["no", "wait", "stop", "cancel"].contains(last) {
                return true
            }
            if requestStem.hasSuffix(" don t")
                || requestStem.hasSuffix(" dont")
                || requestStem.hasSuffix(" do not") {
                return true
            }
            let laterActionWords: Set<String> = [
                "open", "close", "hide", "show", "minimize", "minimise",
                "pause", "resume", "send", "draft", "click", "select",
                "type", "write", "move", "delete", "search", "find",
            ]
            let replacesLeadingAction = words.dropFirst().contains(where: laterActionWords.contains)
            return replacesLeadingAction
                && (words.contains("actually") || words.contains("instead"))
        }

        /// Recognizes a clearly singular tab-close request structurally rather
        /// than requiring browser modifiers to appear in one fixed phrase.
        /// “Close out the Chrome tab” and “get rid of this browser tab” are the
        /// same current-tab intent; plural or broad scopes remain separate.
        var requestsClosingCurrentTab: Bool {
            requestsClosingSingleSurface("tab", plural: "tabs")
        }

        var requestsClosingCurrentWindow: Bool {
            requestsClosingSingleSurface("window", plural: "windows")
        }

        private func requestsClosingSingleSurface(
            _ singular: String,
            plural: String
        ) -> Bool {
            guard commandStartsWithAny(["close", "shut", "exit", "get rid", "x out"]),
                  contains(singular),
                  !contains(plural),
                  containsAny(["close", "shut", "exit", "get rid of", "x out"]),
                  !containsAny([
                    "all \(singular)", "all the \(singular)",
                    "every \(singular)", "each \(singular)",
                    "other \(singular)", "every other \(singular)",
                    "do not close", "don t close", "dont close", "not close",
                    "never close", "leave the \(singular) open",
                    "leave this \(singular) open", "keep the \(singular) open",
                    "keep this \(singular) open",
                    "except this \(singular)", "except the \(singular)",
                    "except that \(singular)", "except current \(singular)",
                    "but not this \(singular)", "but not the \(singular)",
                    "but not that \(singular)", "but not current \(singular)",
                    "anything other than this \(singular)",
                    "everything other than this \(singular)",
                  ]) else { return false }
            return true
        }

        var containsKnownApplication: Bool {
            knownApplicationName != nil
        }

        var hasBroadExclusion: Bool {
            containsAny([
                "except", "except for", "but not", "other than",
                "anything besides", "everything besides",
            ])
        }

        var hasDeferredActionTiming: Bool {
            let immediateAfterThatActions = [
                "after that click", "after that tap", "after that press",
                "after that select", "after that choose", "after that pick",
                "after that play", "after that search", "after that type",
                "after that enter", "after that scroll", "after that change",
                "after that set", "after that edit", "after that move",
                "after that drag", "after that open", "after that launch",
                "after that close", "after that minimize", "after that minimise",
                "after that hide", "after that pause", "after that resume",
            ]
            if containsAny([
                "later", "tomorrow", "tonight", "next week", "next month",
                "after i", "after we", "after you", "after it", "after he",
                "after she", "after they", "after the", "after this",
                "after my", "after your", "when i", "when we", "when you",
                "when it", "when he", "when she", "when they", "when the",
                "when this", "when that", "when my", "when your", "when i m",
                "when im", "when i am", "once i", "once we", "before i leave",
                "after i m done", "after im done", "if i", "if we", "if you",
                "if it", "if he", "if she", "if they", "if the", "if this",
                "if that", "if my", "if your", "if needed", "if necessary",
                "this morning", "this afternoon", "this evening",
                "at noon", "at midnight", "in a little while", "on monday",
                "on tuesday", "on wednesday", "on thursday", "on friday",
                "on saturday", "on sunday", "next monday", "next tuesday",
                "next wednesday", "next thursday", "next friday", "next saturday",
                "next sunday",
            ]) {
                return true
            }
            // “Open YouTube and after that click…” is one immediate visual
            // sequence. A bare “close Chrome after that” still refers to a
            // future conversational event Aurora cannot schedule.
            if contains("after that"), !containsAny(immediateAfterThatActions) {
                return true
            }
            let words = normalized.split(separator: " ").map(String.init)
            if let atIndex = words.firstIndex(of: "at"), atIndex + 1 < words.count {
                let next = words[atIndex + 1]
                if Int(next) != nil || ["noon", "midnight"].contains(next) {
                    return true
                }
                let spokenClockHours: Set<String> = [
                    "one", "two", "three", "four", "five", "six",
                    "seven", "eight", "nine", "ten", "eleven", "twelve",
                ]
                if spokenClockHours.contains(next) {
                    let following = words.indices.contains(atIndex + 2)
                        ? words[atIndex + 2]
                        : nil
                    let afterFollowing = words.indices.contains(atIndex + 3)
                        ? words[atIndex + 3]
                        : nil
                    let clockQualifiers: Set<String> = [
                        "am", "pm", "a", "p", "o", "today", "tonight",
                        "tomorrow", "sharp", "ish",
                    ]
                    let spokenMinutes: Set<String> = [
                        "oh", "five", "ten", "fifteen", "twenty", "thirty",
                        "forty", "fifty",
                    ]
                    // "at three" and "at three p.m." are clock times. "click
                    // at three visible points" is not, so a following noun
                    // does not turn the command into a scheduled action.
                    if following == nil || following.map(clockQualifiers.contains) == true {
                        return true
                    }
                    if let following, spokenMinutes.contains(following),
                       afterFollowing == nil
                        || afterFollowing.map(clockQualifiers.contains) == true {
                        return true
                    }
                    if following == "in",
                       afterFollowing == "the",
                       words.indices.contains(atIndex + 4),
                       ["morning", "afternoon", "evening"].contains(words[atIndex + 4]) {
                        return true
                    }
                }
            }
            guard let index = words.firstIndex(of: "in"), index + 2 < words.count else {
                return false
            }
            let numberWords: Set<String> = [
                "a", "an", "one", "two", "three", "four", "five", "six",
                "seven", "eight", "nine", "ten", "fifteen", "twenty", "thirty",
            ]
            let unitWords: Set<String> = [
                "second", "seconds", "minute", "minutes", "hour", "hours",
                "day", "days",
            ]
            return (Int(words[index + 1]) != nil || numberWords.contains(words[index + 1]))
                && unitWords.contains(words[index + 2])
        }

        var knownApplicationName: String? {
            knownApplicationName(in: normalized)
        }

        func targetApplicationName(for action: NativeDesktopAction) -> String? {
            let clause = actionClause
            switch action {
            case .activateApplication:
                return knownApplicationName(in: clause)
            case .back, .forward, .refresh, .newTab, .closeTab, .reopenClosedTab,
                 .pauseCurrentMedia, .resumeCurrentMedia:
                return knownBrowserName(in: clause)
            case .closeOtherTabsExceptGmail:
                return knownBrowserName(in: clause) ?? "Google Chrome"
            case .minimizeFrontWindow, .minimizeAllWindows,
                 .closeFrontWindow, .closeAllWindows, .hideFrontApplication:
                return knownApplicationName(in: clause)
                    ?? arbitraryWindowApplicationName(in: clause, action: action)
            case .minimizeEverything, .showDesktop, .openSettings,
                 .writeTextEditDocument:
                return nil
            }
        }

        private var actionClause: String {
            let padded = " " + requestStem + " "
            let boundaries = [
                " so i can ", " so that ", " because ", " and then ",
                " after that ", " then ", " and open ", " and launch ",
                " and switch ", " and check ", " and go ", " before ",
                " while ", " to see ", " to get to ", " for me to ",
                " in order to ",
            ]
            let firstBoundary = boundaries.compactMap { padded.range(of: $0)?.lowerBound }
                .min()
            guard let firstBoundary else { return requestStem }
            return String(padded[..<firstBoundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func knownApplicationName(in text: String) -> String? {
            let names: [(phrases: [String], name: String)] = [
                (["google chrome canary", "chrome canary"], "Google Chrome Canary"),
                (["google chrome beta", "chrome beta"], "Google Chrome Beta"),
                (["google chrome", "chrome"], "Google Chrome"),
                (["microsoft edge canary", "edge canary"], "Microsoft Edge Canary"),
                (["microsoft edge beta", "edge beta"], "Microsoft Edge Beta"),
                (["microsoft edge", "edge"], "Microsoft Edge"),
                (["brave browser", "brave"], "Brave Browser"),
                (["arc browser", "arc"], "Arc"),
                (["firefox developer edition", "firefox developer"], "Firefox Developer Edition"),
                (["firefox nightly"], "Firefox Nightly"),
                (["mozilla firefox", "firefox"], "Firefox"),
                (["opera"], "Opera"),
                (["vivaldi"], "Vivaldi"),
                (["safari"], "Safari"),
                (["finder"], "Finder"),
                (["terminal"], "Terminal"),
                (["messages"], "Messages"),
                (["mail app", "open mail"], "Mail"),
                (["calendar"], "Calendar"),
                (["reminders"], "Reminders"),
                (["music"], "Music"),
                (["photos"], "Photos"),
                (["facetime"], "FaceTime"),
                (["preview"], "Preview"),
                (["slack"], "Slack"),
                (["discord"], "Discord"),
                (["spotify"], "Spotify"),
                (["zoom"], "zoom.us"),
                (["xcode"], "Xcode"),
                (["codex"], "Codex"),
                (["calculator"], "Calculator"),
                (["text edit", "textedit"], "TextEdit"),
            ]
            let padded = " " + text + " "
            return names.first(where: { entry in
                entry.phrases.contains { padded.contains(" " + $0 + " ") }
            })?.name
        }

        private func knownBrowserName(in text: String) -> String? {
            let names: [(phrases: [String], name: String)] = [
                (["google chrome canary", "chrome canary"], "Google Chrome Canary"),
                (["google chrome beta", "chrome beta"], "Google Chrome Beta"),
                (["google chrome", "chrome"], "Google Chrome"),
                (["microsoft edge canary", "edge canary"], "Microsoft Edge Canary"),
                (["microsoft edge beta", "edge beta"], "Microsoft Edge Beta"),
                (["microsoft edge", "edge"], "Microsoft Edge"),
                (["brave browser", "brave"], "Brave Browser"),
                (["arc browser", "arc"], "Arc"),
                (["firefox developer edition", "firefox developer"], "Firefox Developer Edition"),
                (["firefox nightly"], "Firefox Nightly"),
                (["mozilla firefox", "firefox"], "Firefox"),
                (["opera"], "Opera"),
                (["vivaldi"], "Vivaldi"),
                (["safari"], "Safari"),
            ]
            let padded = " " + text + " "
            return names.first(where: { entry in
                entry.phrases.contains { padded.contains(" " + $0 + " ") }
            })?.name
        }

        private func arbitraryWindowApplicationName(
            in clause: String,
            action: NativeDesktopAction
        ) -> String? {
            var words = clause.split(separator: " ").map(String.init)
            let commandPrefixes = [
                ["minimize"], ["minimise"], ["close"], ["shut"], ["exit"],
                ["get", "rid", "of"], ["x", "out"], ["hide"],
            ]
            if let prefix = commandPrefixes.first(where: { words.starts(with: $0) }) {
                words.removeFirst(prefix.count)
            }
            let ignored: Set<String> = [
                "a", "an", "the", "my", "this", "that", "current", "front",
                "frontmost", "active", "all", "every", "window", "windows",
                "tab", "tabs", "browser", "app", "application", "please",
                "in", "on", "s",
            ]
            words.removeAll(where: ignored.contains)
            guard !words.isEmpty, words.count <= 4 else { return nil }
            if action == .hideFrontApplication || clause.contains(" window") {
                return words.map { word in
                    word.prefix(1).uppercased() + word.dropFirst()
                }.joined(separator: " ")
            }
            return nil
        }

        func contains(_ phrase: String) -> Bool {
            containsAny([phrase])
        }

        func containsAny(_ phrases: [String]) -> Bool {
            let padded = " " + normalized + " "
            return phrases.contains { phrase in
                padded.contains(" " + phrase + " ")
            }
        }

        func startsWith(_ phrase: String) -> Bool {
            normalized == phrase || normalized.hasPrefix(phrase + " ")
        }

        func startsWithAny(_ phrases: [String]) -> Bool {
            phrases.contains(where: startsWith)
        }

        func commandStartsWith(_ phrase: String) -> Bool {
            requestStem == phrase || requestStem.hasPrefix(phrase + " ")
        }

        func commandStartsWithAny(_ phrases: [String]) -> Bool {
            phrases.contains(where: commandStartsWith)
        }
    }
}
