import SwiftUI

@MainActor
final class AuroraContinuitySettingsModel: ObservableObject {
    @Published private(set) var snapshots: [ContinuityDocumentSnapshot] = []
    @Published private(set) var versions: [ContinuityDocumentVersion] = []
    @Published private(set) var selectedDocument: ContinuityDocument = .soul
    @Published var draft = ""
    @Published private(set) var savedContent = ""
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var statusMessage: String?

    private let store: ContinuityDocumentStore
    private let ownerDisplayName: String
    private let onSaved: (ContinuityDocumentSnapshot) -> Void

    init(
        store: ContinuityDocumentStore,
        ownerDisplayName: String,
        onSaved: @escaping (ContinuityDocumentSnapshot) -> Void
    ) {
        self.store = store
        self.ownerDisplayName = ownerDisplayName
        self.onSaved = onSaved
    }

    var hasUnsavedChanges: Bool { draft != savedContent }

    var selectedSnapshot: ContinuityDocumentSnapshot? {
        snapshots.first { $0.document == selectedDocument }
    }

    func load() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await store.prepare(ownerDisplayName: ownerDisplayName)
            snapshots = try await store.list()
            try await loadSelection(selectedDocument)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ document: ContinuityDocument) async {
        guard document != selectedDocument else { return }
        guard !hasUnsavedChanges else {
            statusMessage = "Save or revert this file before opening another one."
            return
        }
        selectedDocument = document
        await reloadSelection()
    }

    func save() async {
        guard let current = selectedSnapshot, hasUnsavedChanges, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let saved = try await store.write(
                selectedDocument,
                content: draft,
                expectedRevision: current.revision
            )
            replaceSnapshot(saved)
            savedContent = saved.content
            draft = saved.content
            versions = try await store.history(selectedDocument)
            statusMessage = "Saved. Aurora will carry this forward."
            errorMessage = nil
            onSaved(saved)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revertDraft() {
        draft = savedContent
        statusMessage = nil
    }

    func reloadSelection() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            snapshots = try await store.list()
            try await loadSelection(selectedDocument)
            statusMessage = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore(_ version: ContinuityDocumentVersion) async {
        guard let current = selectedSnapshot, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let restored = try await store.restore(
                selectedDocument,
                revision: version.revision,
                expectedRevision: current.revision
            )
            replaceSnapshot(restored)
            draft = restored.content
            savedContent = restored.content
            versions = try await store.history(selectedDocument)
            statusMessage = "Previous version restored."
            errorMessage = nil
            onSaved(restored)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSelection(_ document: ContinuityDocument) async throws {
        let snapshot = try await store.read(document)
        replaceSnapshot(snapshot)
        draft = snapshot.content
        savedContent = snapshot.content
        versions = try await store.history(document)
        statusMessage = nil
    }

    private func replaceSnapshot(_ snapshot: ContinuityDocumentSnapshot) {
        snapshots.removeAll { $0.document == snapshot.document }
        snapshots.append(snapshot)
    }
}

struct AuroraContinuitySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AuroraContinuitySettingsModel
    @State private var isShowingCloseConfirmation = false
    let companionPairingCode: String
    let companionStatus: String

    init(
        store: ContinuityDocumentStore,
        ownerDisplayName: String,
        companionPairingCode: String,
        companionStatus: String,
        onSaved: @escaping (ContinuityDocumentSnapshot) -> Void
    ) {
        self.companionPairingCode = companionPairingCode
        self.companionStatus = companionStatus
        _model = StateObject(wrappedValue: AuroraContinuitySettingsModel(
            store: store,
            ownerDisplayName: ownerDisplayName,
            onSaved: onSaved
        ))
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Aurora")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("The parts of her that persist.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 16)

                continuitySection("Core", documents: [.soul, .identity, .user, .memory])
                continuitySection("Advanced", documents: [.agents, .tools])
                Spacer(minLength: 12)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .background(.ultraThinMaterial)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.45)
                companionCard
                Divider().opacity(0.45)

                TextEditor(text: $model.draft)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(18)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
                    .disabled(model.isBusy)

                Divider().opacity(0.45)
                footer
            }
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 570, idealHeight: 640)
        .interactiveDismissDisabled(model.hasUnsavedChanges)
        .task { await model.load() }
        .alert(
            "Aurora couldn't change that file",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            if model.hasUnsavedChanges {
                Button("Discard & Reload", role: .destructive) {
                    model.revertDraft()
                    Task { await model.reloadSelection() }
                }
            } else {
                Button("Reload") { Task { await model.reloadSelection() } }
            }
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var companionCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.purple.opacity(0.9))
                .frame(width: 34, height: 34)
                .background(Color.purple.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Private iPhone companion prototype")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(companionStatus)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(companionPairingCode)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text(
                    AuroraCompanionProtocol.allowedTailscalePeerAddresses.isEmpty
                        ? "excluded from public release"
                        : "one-time pairing code"
                )
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
        .background(Color.white.opacity(0.025))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Private iPhone companion prototype, \(companionStatus), pairing code \(companionPairingCode)"
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectedDocument.displayName)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(model.selectedDocument.purpose)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let snapshot = model.selectedSnapshot {
                Text("\(snapshot.byteCount.formatted()) bytes  ·  \(snapshot.revision.prefix(8))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Button("Done") {
                if model.hasUnsavedChanges {
                    isShowingCloseConfirmation = true
                } else {
                    dismiss()
                }
            }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy)
                .alert("Save changes before closing?", isPresented: $isShowingCloseConfirmation) {
                    Button("Save") {
                        Task {
                            await model.save()
                            guard !model.hasUnsavedChanges, model.errorMessage == nil else { return }
                            dismiss()
                        }
                    }
                    Button("Discard", role: .destructive) {
                        model.revertDraft()
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your changes to \(model.selectedDocument.displayName) haven't been saved.")
                }
        }
        .padding(.horizontal, 20)
        .frame(height: 72)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(model.statusMessage ?? (model.hasUnsavedChanges ? "Unsaved changes" : "Changes here shape Aurora's live continuity."))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(model.hasUnsavedChanges ? .primary : .secondary)
                Spacer()
                Button("Revert") { model.revertDraft() }
                    .disabled(!model.hasUnsavedChanges || model.isBusy)
                Button("Save") { Task { await model.save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(!model.hasUnsavedChanges || model.isBusy)
            }

            if model.versions.count > 1 {
                DisclosureGroup("Version history") {
                    VStack(spacing: 5) {
                        ForEach(Array(model.versions.filter { !$0.isCurrent }.prefix(5).enumerated()), id: \.element.revision) { _, version in
                            HStack {
                                Text(version.storedAt.formatted(date: .abbreviated, time: .shortened))
                                Text(String(version.revision.prefix(8)))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Restore") { Task { await model.restore(version) } }
                                    .buttonStyle(.borderless)
                                    .disabled(model.hasUnsavedChanges || model.isBusy)
                            }
                            .font(.system(size: 11, design: .rounded))
                        }
                    }
                    .padding(.top, 7)
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func continuitySection(_ title: String, documents: [ContinuityDocument]) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 6)

        ForEach(documents, id: \.rawValue) { document in
            Button {
                Task { await model.select(document) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: document.symbolName)
                        .frame(width: 16)
                    Text(document.displayName)
                    Spacer()
                }
                .font(.system(size: 13, weight: model.selectedDocument == document ? .semibold : .regular, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(model.selectedDocument == document ? Color.white.opacity(0.11) : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 7)
        }
    }
}

private extension ContinuityDocument {
    var displayName: String {
        switch self {
        case .agents: return "Behavior"
        case .soul: return "Soul"
        case .identity: return "Identity"
        case .user: return "Owner"
        case .tools: return "Capabilities"
        case .memory: return "Memory"
        }
    }

    var purpose: String {
        switch self {
        case .agents: return "How Aurora approaches the world"
        case .soul: return "Values, temperament, and enduring voice"
        case .identity: return "Who Aurora understands herself to be"
        case .user: return "What Aurora knows about the owner"
        case .tools: return "How capabilities should be understood"
        case .memory: return "Curated facts carried across time"
        }
    }

    var symbolName: String {
        switch self {
        case .agents: return "sparkles"
        case .soul: return "heart"
        case .identity: return "person.crop.circle"
        case .user: return "person"
        case .tools: return "wrench.and.screwdriver"
        case .memory: return "clock.arrow.circlepath"
        }
    }
}
