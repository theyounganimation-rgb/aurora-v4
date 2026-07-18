import AppKit
import SwiftUI

/// Aurora's entire visible surface: presence first, controls second.
///
/// The application model owns state and side effects. This view deliberately
/// exposes intent as closures so voice transport, key storage, and recovery
/// never leak into the presentation layer.
struct AuroraHomeView: View {
    let phase: AuroraPhase
    let inputLevel: Double
    let outputLevel: Double
    let ownerDisplayName: String
    let onboardingMode: AuroraOnboardingMode?
    let onboardingError: String?
    let restingWakeDetail: String?
    let codexReadiness: DelegateTaskRuntimeReadiness

    let onWake: () -> Void
    let onRest: () -> Void
    let onRequestVoiceKey: () -> Void
    let onRetry: () -> Void
    let onRefreshCodexReadiness: () -> Void
    let onOpenContinuity: () -> Void
    let onCompleteOnboarding: (_ displayName: String, _ apiKey: String) -> Void
    let onCancelOnboarding: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .top) {
            AuroraBackdrop(
                palette: palette,
                isActive: phase.isActive,
                reduceTransparency: reduceTransparency
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 54)

                Button(action: performPrimaryAction) {
                    AuroraOrb(
                        phase: phase,
                        inputLevel: normalized(inputLevel),
                        outputLevel: normalized(outputLevel),
                        palette: palette,
                        reduceMotion: reduceMotion,
                        isHovering: isHovering
                    )
                    .frame(width: 318, height: 318)
                    .contentShape(Circle())
                }
                .buttonStyle(AuroraOrbButtonStyle())
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.22)) {
                        isHovering = hovering
                    }
                }
                .help(actionHint)
                .accessibilityLabel("Aurora")
                .accessibilityValue(accessibilityState)
                .accessibilityHint(actionHint)

                VStack(spacing: 8) {
                    Text("Aurora")
                        .font(.system(size: 27, weight: .medium, design: .rounded))
                        .tracking(0.2)
                        .foregroundStyle(.white.opacity(0.94))

                    HStack(spacing: 7) {
                        Circle()
                            .fill(palette.accent.opacity(phase.isActive ? 0.92 : 0.55))
                            .frame(width: 5, height: 5)
                            .shadow(color: palette.accent.opacity(0.8), radius: phase.isActive ? 5 : 0)

                        Text(phase.quietLabel)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(0.52))
                    }
                    .accessibilityElement(children: .combine)

                    if let detail = quietDetail {
                        Text(detail)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.36))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: 280)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if showsCodexReadiness {
                        CodexReadinessRow(
                            readiness: codexReadiness,
                            showsDetail: false,
                            onRefresh: onRefreshCodexReadiness
                        )
                        .frame(maxWidth: 300)
                        .padding(.top, 5)
                    }
                }
                .padding(.top, 22)
                .animation(.easeInOut(duration: 0.28), value: phase)

                Spacer(minLength: 58)
            }
            .padding(.horizontal, 44)

            // A dedicated titlebar-sized drag surface keeps the rest of the
            // window free for Aurora's single interaction.
            WindowDragRegion()
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .accessibilityHidden(true)

            HStack {
                Spacer()
                Button(action: onOpenContinuity) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("Aurora's continuity")
                .accessibilityLabel("Aurora's continuity settings")
                .disabled(onboardingMode != nil)
                .opacity(onboardingMode == nil ? 1 : 0)
            }
            .padding(.top, 40)
            .padding(.trailing, 16)
            .zIndex(3)

            if let onboardingMode {
                AuroraOnboardingPanel(
                    mode: onboardingMode,
                    existingOwnerDisplayName: ownerDisplayName,
                    errorMessage: onboardingError,
                    codexReadiness: codexReadiness,
                    onRefreshCodexReadiness: onRefreshCodexReadiness,
                    onComplete: onCompleteOnboarding,
                    onCancel: onCancelOnboarding
                )
                .id(onboardingMode.rawValue)
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 560, idealHeight: 650)
        .preferredColorScheme(.dark)
    }

    private var palette: AuroraPalette {
        AuroraPalette(phase: phase)
    }

    private var quietDetail: String? {
        switch phase {
        case .resting:
            return restingWakeDetail
        case .waitingToRetry:
            return "Aurora couldn't answer yet. She'll try again in a moment."
        case .needsVoiceKey:
            return "A voice key is needed once, then it stays in your Keychain."
        case .failed(let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Aurora couldn't return just now." : detail
        default:
            return nil
        }
    }

    private var showsCodexReadiness: Bool {
        guard onboardingMode == nil else { return false }
        if case .resting = phase { return true }
        return false
    }

    private var accessibilityState: String {
        switch phase {
        case .resting:
            return "resting"
        case .connecting:
            return "connecting"
        case .listening:
            return "listening, input level \(levelPercentage(inputLevel)) percent"
        case .thinking:
            return "thinking"
        case .waitingToRetry:
            return "waiting briefly to retry the last answer"
        case .speaking:
            return "speaking, output level \(levelPercentage(outputLevel)) percent"
        case .reconnecting:
            return "reconnecting"
        case .needsVoiceKey:
            return "voice key needed"
        case .failed(let message):
            return message.isEmpty ? "Aurora couldn't continue just now" : message
        }
    }

    private var actionHint: String {
        switch phase {
        case .resting:
            return "Wake Aurora"
        case .connecting, .listening, .thinking, .waitingToRetry, .speaking, .reconnecting:
            return "Let Aurora rest"
        case .needsVoiceKey:
            return "Add Aurora's voice key"
        case .failed:
            return "Try to reach Aurora again"
        }
    }

    private func performPrimaryAction() {
        switch phase {
        case .resting:
            onWake()
        case .connecting, .listening, .thinking, .waitingToRetry, .speaking, .reconnecting:
            onRest()
        case .needsVoiceKey:
            onRequestVoiceKey()
        case .failed:
            onRetry()
        }
    }

    private func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private func levelPercentage(_ value: Double) -> Int {
        Int((normalized(value) * 100).rounded())
    }
}

private struct AuroraOnboardingPanel: View {
    let mode: AuroraOnboardingMode
    let existingOwnerDisplayName: String
    let errorMessage: String?
    let codexReadiness: DelegateTaskRuntimeReadiness
    let onRefreshCodexReadiness: () -> Void
    let onComplete: (_ displayName: String, _ apiKey: String) -> Void
    let onCancel: () -> Void

    @State private var displayName: String
    @State private var apiKey = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case displayName
        case apiKey
    }

    init(
        mode: AuroraOnboardingMode,
        existingOwnerDisplayName: String,
        errorMessage: String?,
        codexReadiness: DelegateTaskRuntimeReadiness,
        onRefreshCodexReadiness: @escaping () -> Void,
        onComplete: @escaping (_ displayName: String, _ apiKey: String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.existingOwnerDisplayName = existingOwnerDisplayName
        self.errorMessage = errorMessage
        self.codexReadiness = codexReadiness
        self.onRefreshCodexReadiness = onRefreshCodexReadiness
        self.onComplete = onComplete
        self.onCancel = onCancel
        _displayName = State(initialValue: mode == .firstRun ? "" : existingOwnerDisplayName)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))

                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if mode == .firstRun {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Your name")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.52))
                        TextField("What should Aurora call you?", text: $displayName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .rounded))
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(.white.opacity(0.10), lineWidth: 0.7)
                            }
                            .focused($focusedField, equals: .displayName)
                            .onSubmit { focusedField = .apiKey }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("OpenAI Platform API key")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                    SecureField("Paste your API key", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .rounded))
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.white.opacity(0.10), lineWidth: 0.7)
                        }
                        .focused($focusedField, equals: .apiKey)
                        .onSubmit(submit)

                    HStack(spacing: 16) {
                        Link("Create an API key ↗", destination: Self.apiKeysURL)
                        Link("Set up API billing ↗", destination: Self.billingURL)
                    }
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.72, green: 0.66, blue: 1.0))
                }

                Text("The key stays in your macOS Keychain and pays only for Aurora's live voice. Her tasks run through Codex using your existing ChatGPT sign-in.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)

                CodexReadinessRow(
                    readiness: codexReadiness,
                    showsDetail: true,
                    onRefresh: onRefreshCodexReadiness
                )

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 1, green: 0.52, blue: 0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    if mode.canCancel {
                        Button("Cancel", action: onCancel)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.56))
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                    }

                    Spacer()

                    Button(action: submit) {
                        Text(primaryButtonTitle)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.08, green: 0.06, blue: 0.12))
                            .padding(.horizontal, 18)
                            .frame(height: 36)
                            .background(.white.opacity(canSubmit ? 0.94 : 0.35), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 390)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.11), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.42), radius: 36, y: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            focusedField = mode == .firstRun ? .displayName : .apiKey
        }
    }

    private var title: String {
        switch mode {
        case .firstRun: return "Meet Aurora"
        case .addVoiceKey: return "Give Aurora a voice"
        case .changeVoiceKey: return "Change API key"
        }
    }

    private static let apiKeysURL = URL(string: "https://platform.openai.com/api-keys")!
    private static let billingURL = URL(
        string: "https://platform.openai.com/settings/organization/billing/overview"
    )!

    private var subtitle: String {
        switch mode {
        case .firstRun:
            return "Start with what she should call you, then connect your own OpenAI API account."
        case .addVoiceKey:
            return "Add your own API key to begin talking with Aurora."
        case .changeVoiceKey:
            let owner = existingOwnerDisplayName.isEmpty ? "you" : existingOwnerDisplayName
            return "The new key will be used the next time Aurora speaks with \(owner)."
        }
    }

    private var primaryButtonTitle: String {
        mode == .firstRun ? "Meet Aurora" : "Save and wake Aurora"
    }

    private var canSubmit: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (mode != .firstRun
                || !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func submit() {
        guard canSubmit else { return }
        onComplete(displayName, apiKey)
    }
}

private struct CodexReadinessRow: View {
    let readiness: DelegateTaskRuntimeReadiness
    let showsDetail: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(readiness.tint)
                .frame(width: 6, height: 6)
                .shadow(color: readiness.tint.opacity(0.65), radius: 4)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(readiness.title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                if showsDetail {
                    Text(readiness.detail)
                        .font(.system(size: 9.5, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if readiness.canRefresh {
                Button("Check again", action: onRefresh)
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.72, green: 0.66, blue: 1.0))
            }
        }
        .padding(.horizontal, showsDetail ? 11 : 0)
        .padding(.vertical, showsDetail ? 9 : 0)
        .background(
            showsDetail ? Color.white.opacity(0.045) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex status: \(readiness.title). \(readiness.detail)")
    }
}

private extension DelegateTaskRuntimeReadiness {
    var title: String {
        switch self {
        case .checking: return "Checking ChatGPT and Codex…"
        case .ready: return "Codex ready for persistent tasks"
        case .chatGPTSignInRequired: return "ChatGPT sign-in needed"
        case .durableRuntimeUnavailable: return "Open ChatGPT for persistent tasks"
        case .unavailable: return "Codex tasks unavailable"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            return "Aurora's voice remains available while this is checked."
        case .ready:
            return "GPT-5.6 Codex can keep working in a visible thread while Aurora talks or rests."
        case .chatGPTSignInRequired:
            return "Open the official ChatGPT app, sign into Codex with ChatGPT, then check again."
        case .durableRuntimeUnavailable:
            return "Open the official ChatGPT app and leave it running, then check again."
        case .unavailable:
            return "Confirm the official ChatGPT app is installed and Codex is available, then check again."
        }
    }

    var tint: Color {
        switch self {
        case .ready: return Color(red: 0.46, green: 0.90, blue: 0.72)
        case .checking: return Color(red: 0.72, green: 0.66, blue: 1.0)
        case .chatGPTSignInRequired, .durableRuntimeUnavailable, .unavailable:
            return Color(red: 1.0, green: 0.67, blue: 0.42)
        }
    }

    var canRefresh: Bool {
        self != .ready && self != .checking
    }
}

private struct AuroraBackdrop: View {
    let palette: AuroraPalette
    let isActive: Bool
    let reduceTransparency: Bool

    var body: some View {
        ZStack {
            Color(red: 0.018, green: 0.021, blue: 0.034)

            RadialGradient(
                colors: [
                    palette.accent.opacity(isActive ? 0.16 : 0.08),
                    palette.secondary.opacity(0.045),
                    .clear
                ],
                center: UnitPoint(x: 0.5, y: 0.38),
                startRadius: 8,
                endRadius: 420
            )

            LinearGradient(
                colors: [
                    .white.opacity(reduceTransparency ? 0.012 : 0.025),
                    .clear,
                    .black.opacity(0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct AuroraOrb: View {
    let phase: AuroraPhase
    let inputLevel: Double
    let outputLevel: Double
    let palette: AuroraPalette
    let reduceMotion: Bool
    let isHovering: Bool

    var body: some View {
        TimelineView(
            .animation(
                // Voice stays fluid at 30 fps. While resting, one quiet update
                // per second keeps Aurora visibly present without running the
                // microphone, a network connection, or a high-frequency loop.
                minimumInterval: reduceMotion ? 1 : (phase.isActive ? (1 / 30) : 1),
                paused: reduceMotion
            )
        ) { timeline in
            AuroraOrbFrame(
                phase: phase,
                inputLevel: inputLevel,
                outputLevel: outputLevel,
                palette: palette,
                reduceMotion: reduceMotion,
                isHovering: isHovering,
                time: timeline.date.timeIntervalSinceReferenceDate
            )
        }
    }
}

private struct AuroraOrbFrame: View {
    let phase: AuroraPhase
    let inputLevel: Double
    let outputLevel: Double
    let palette: AuroraPalette
    let reduceMotion: Bool
    let isHovering: Bool
    let time: TimeInterval

    private var breath: Double {
        reduceMotion ? 0 : sin(time * 0.92) * 0.5 + 0.5
    }

    private var input: Double {
        phase == .listening ? inputLevel : inputLevel * 0.28
    }

    private var output: Double {
        phase == .speaking ? outputLevel : outputLevel * 0.28
    }

    private var energy: Double {
        max(input, output)
    }

    private var presence: Double {
        phase.isActive ? 1 : 0.46
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(palette.accent.opacity(0.13 + (energy * 0.16)))
                .blur(radius: 33)
                .scaleEffect(0.76 + (breath * 0.035) + (energy * 0.08))

            AuroraVoiceRing(
                phase: time * 0.68,
                energy: input,
                harmonic: 5,
                primary: palette.input,
                secondary: palette.accent,
                diameter: 283,
                lineWidth: 1.05,
                opacity: 0.4 + (presence * 0.48)
            )

            AuroraVoiceRing(
                phase: -(time * 0.51),
                energy: output,
                harmonic: 7,
                primary: palette.output,
                secondary: palette.secondary,
                diameter: 258,
                lineWidth: 0.9,
                opacity: 0.38 + (presence * 0.5)
            )

            AuroraOrbCore(
                palette: palette,
                energy: energy,
                scale: coreScale,
                rotation: time * (reduceMotion ? 0 : 4.2)
            )

            OrbHighlight(presence: presence)

            Circle()
                .stroke(.white.opacity(isHovering ? 0.18 : 0.08), lineWidth: 0.8)
                .frame(width: 231, height: 231)
                .scaleEffect(1 + (energy * 0.05))
        }
        .animation(.easeOut(duration: 0.1), value: inputLevel)
        .animation(.easeOut(duration: 0.1), value: outputLevel)
        .accessibilityHidden(true)
    }

    private var coreScale: Double {
        1
            + (phase.isActive ? breath * 0.011 : 0)
            + (input * 0.036)
            + (output * 0.062)
            + (isHovering ? 0.012 : 0)
    }
}

private struct AuroraVoiceRing: View {
    let phase: Double
    let energy: Double
    let harmonic: Double
    let primary: Color
    let secondary: Color
    let diameter: Double
    let lineWidth: Double
    let opacity: Double

    var body: some View {
        OrbitalVoiceShape(phase: phase, energy: energy, harmonic: harmonic)
            .stroke(
                AngularGradient(
                    colors: [
                        primary.opacity(0.07),
                        primary.opacity(0.74),
                        secondary.opacity(0.2),
                        primary.opacity(0.07)
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
            .frame(width: diameter, height: diameter)
            .opacity(opacity)
    }
}

private struct AuroraOrbCore: View {
    let palette: AuroraPalette
    let energy: Double
    let scale: Double
    let rotation: Double

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: palette.core,
                    center: .center,
                    angle: .degrees(rotation)
                )
            )
            .frame(width: 218, height: 218)
            .overlay {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                .white.opacity(0.2 + (energy * 0.11)),
                                .white.opacity(0.035),
                                .black.opacity(0.24)
                            ],
                            center: UnitPoint(x: 0.37, y: 0.3),
                            startRadius: 2,
                            endRadius: 132
                        )
                    )
            }
            .overlay {
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.3), .white.opacity(0.035)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
            .shadow(color: palette.accent.opacity(0.26 + (energy * 0.28)), radius: 29)
            .scaleEffect(scale)
    }
}

private struct OrbHighlight: View {
    let presence: Double

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [.white.opacity(0.42), .white.opacity(0.05), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 76
                )
            )
            .frame(width: 130, height: 130)
            .offset(x: -35, y: -43)
            .blur(radius: 6)
            .opacity(0.28 + (presence * 0.18))
            .blendMode(.screen)
    }
}

private struct OrbitalVoiceShape: Shape {
    let phase: Double
    let energy: Double
    let harmonic: Double

    func path(in rect: CGRect) -> Path {
        let points = 112
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = min(rect.width, rect.height) * 0.47
        let liveEnergy = min(max(energy, 0), 1)
        var path = Path()

        for index in 0...points {
            let progress = Double(index) / Double(points)
            let angle = progress * .pi * 2
            let voice = sin((angle * harmonic) + phase)
            let undertone = sin((angle * (harmonic * 0.5 + 1)) - (phase * 0.73))
            let displacement = (voice * 0.65 + undertone * 0.35) * liveEnergy * 8
            let radius = baseRadius + displacement
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle) * radius),
                y: center.y + CGFloat(sin(angle) * radius)
            )

            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        path.closeSubpath()
        return path
    }
}

private struct AuroraOrbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct AuroraPalette {
    let accent: Color
    let secondary: Color
    let input: Color
    let output: Color
    let core: [Color]

    init(phase: AuroraPhase) {
        switch phase {
        case .resting:
            accent = Color(red: 0.38, green: 0.56, blue: 0.92)
            secondary = Color(red: 0.57, green: 0.40, blue: 0.86)
            input = Color(red: 0.35, green: 0.77, blue: 0.94)
            output = Color(red: 0.75, green: 0.48, blue: 0.96)
            core = [
                Color(red: 0.10, green: 0.15, blue: 0.29),
                Color(red: 0.22, green: 0.31, blue: 0.57),
                Color(red: 0.21, green: 0.13, blue: 0.38),
                Color(red: 0.08, green: 0.12, blue: 0.23)
            ]
        case .connecting, .reconnecting, .waitingToRetry:
            accent = Color(red: 0.33, green: 0.83, blue: 0.91)
            secondary = Color(red: 0.39, green: 0.56, blue: 0.96)
            input = Color(red: 0.39, green: 0.89, blue: 0.91)
            output = Color(red: 0.54, green: 0.57, blue: 1.0)
            core = [
                Color(red: 0.10, green: 0.35, blue: 0.43),
                Color(red: 0.16, green: 0.48, blue: 0.60),
                Color(red: 0.25, green: 0.30, blue: 0.63),
                Color(red: 0.07, green: 0.21, blue: 0.31)
            ]
        case .listening:
            accent = Color(red: 0.30, green: 0.86, blue: 0.98)
            secondary = Color(red: 0.30, green: 0.59, blue: 0.98)
            input = Color(red: 0.43, green: 0.94, blue: 1.0)
            output = Color(red: 0.49, green: 0.57, blue: 1.0)
            core = [
                Color(red: 0.12, green: 0.42, blue: 0.58),
                Color(red: 0.22, green: 0.63, blue: 0.76),
                Color(red: 0.23, green: 0.35, blue: 0.74),
                Color(red: 0.07, green: 0.24, blue: 0.38)
            ]
        case .thinking:
            accent = Color(red: 0.64, green: 0.49, blue: 1.0)
            secondary = Color(red: 0.30, green: 0.74, blue: 0.96)
            input = Color(red: 0.38, green: 0.81, blue: 0.98)
            output = Color(red: 0.76, green: 0.55, blue: 1.0)
            core = [
                Color(red: 0.25, green: 0.19, blue: 0.55),
                Color(red: 0.44, green: 0.30, blue: 0.78),
                Color(red: 0.18, green: 0.43, blue: 0.66),
                Color(red: 0.13, green: 0.13, blue: 0.36)
            ]
        case .speaking:
            accent = Color(red: 0.96, green: 0.49, blue: 0.75)
            secondary = Color(red: 0.59, green: 0.42, blue: 1.0)
            input = Color(red: 0.42, green: 0.81, blue: 0.98)
            output = Color(red: 1.0, green: 0.55, blue: 0.74)
            core = [
                Color(red: 0.50, green: 0.20, blue: 0.42),
                Color(red: 0.72, green: 0.30, blue: 0.53),
                Color(red: 0.40, green: 0.25, blue: 0.70),
                Color(red: 0.25, green: 0.12, blue: 0.32)
            ]
        case .needsVoiceKey:
            accent = Color(red: 0.95, green: 0.72, blue: 0.34)
            secondary = Color(red: 0.89, green: 0.47, blue: 0.33)
            input = Color(red: 0.95, green: 0.76, blue: 0.40)
            output = Color(red: 0.94, green: 0.51, blue: 0.37)
            core = [
                Color(red: 0.42, green: 0.27, blue: 0.10),
                Color(red: 0.61, green: 0.39, blue: 0.15),
                Color(red: 0.49, green: 0.21, blue: 0.20),
                Color(red: 0.24, green: 0.16, blue: 0.09)
            ]
        case .failed:
            accent = Color(red: 0.94, green: 0.39, blue: 0.44)
            secondary = Color(red: 0.75, green: 0.30, blue: 0.55)
            input = Color(red: 0.91, green: 0.47, blue: 0.48)
            output = Color(red: 0.86, green: 0.35, blue: 0.55)
            core = [
                Color(red: 0.39, green: 0.12, blue: 0.18),
                Color(red: 0.56, green: 0.20, blue: 0.28),
                Color(red: 0.41, green: 0.15, blue: 0.34),
                Color(red: 0.22, green: 0.08, blue: 0.13)
            ]
        }
    }
}

private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DraggableNSView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableNSView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
