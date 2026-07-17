import SwiftUI

@main
struct AuroraDesktopApp: App {
    @NSApplicationDelegateAdaptor(AuroraAppDelegate.self) private var appDelegate
    @StateObject private var model: AuroraAppModel
    @State private var showingContinuity = false

    init() {
        let model = AuroraAppModel()
        _model = StateObject(wrappedValue: model)
        appDelegate.installTerminationHandler { [weak model] in
            await model?.prepareForApplicationTermination()
        }
    }

    var body: some Scene {
        Window("Aurora", id: "aurora-main") {
            AuroraHomeView(
                phase: model.phase,
                inputLevel: model.inputLevel,
                outputLevel: model.outputLevel,
                ownerDisplayName: model.ownerDisplayName,
                onboardingMode: model.onboardingMode,
                onboardingError: model.onboardingError,
                restingWakeDetail: model.restingWakeDetail,
                onWake: model.wake,
                onRest: model.rest,
                onRequestVoiceKey: model.requestVoiceKey,
                onRetry: model.retry,
                onOpenContinuity: {
                    model.refreshCompanionPairingCode()
                    showingContinuity = true
                },
                onCompleteOnboarding: model.completeOnboarding,
                onCancelOnboarding: model.cancelOnboarding
            )
            .frame(idealWidth: 560, idealHeight: 650)
            .sheet(isPresented: $showingContinuity) {
                AuroraContinuitySettingsView(
                    store: model.continuityDocumentStore,
                    ownerDisplayName: model.ownerDisplayName,
                    companionPairingCode: model.companionPairingCode,
                    companionStatus: model.companionStatus,
                    onSaved: model.continuityDocumentDidChange
                )
            }
        }
        .defaultSize(width: 560, height: 650)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appSettings) {
                Button("Change OpenAI API Key…") {
                    model.beginVoiceKeyChange()
                }
            }
        }
    }
}
