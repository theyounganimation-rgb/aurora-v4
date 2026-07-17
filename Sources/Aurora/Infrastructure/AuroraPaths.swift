import Foundation

enum AuroraPaths {
    static let openClawContinuityPreferenceKey = "continuity.use-openclaw-workspace"
    private static let identityDocumentNames = ["SOUL.md", "IDENTITY.md", "USER.md", "MEMORY.md"]

    static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var openClawWorkspace: URL {
        homeDirectory.appendingPathComponent(".openclaw/workspace", isDirectory: true)
    }

    /// OpenClaw continuity is an explicit local choice. Merely finding another
    /// persona's Markdown on a public user's Mac must never make Aurora ingest
    /// it. An established installation can enable this preference locally;
    /// fresh installs stay in Aurora's private application-support directory.
    static var continuityWorkspace: URL {
        resolveContinuityWorkspace(
            applicationSupportURL: applicationSupport,
            openClawWorkspaceURL: openClawWorkspace,
            useOpenClaw: UserDefaults.standard.bool(
                forKey: openClawContinuityPreferenceKey
            )
        )
    }

    static func resolveContinuityWorkspace(
        applicationSupportURL: URL,
        openClawWorkspaceURL: URL,
        useOpenClaw: Bool,
        fileManager: FileManager = .default
    ) -> URL {
        let native = applicationSupportURL.standardizedFileURL
            .appendingPathComponent("continuity", isDirectory: true)
        guard useOpenClaw else { return native }

        let candidate = openClawWorkspaceURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let rootValues = try? candidate.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            return native
        }

        let hasSafeIdentityDocument = identityDocumentNames.contains { name in
            let url = candidate.appendingPathComponent(name, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path),
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        return hasSafeIdentityDocument ? candidate : native
    }

    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Aurora", isDirectory: true)
    }

    static var eventJournalDirectory: URL {
        applicationSupport.appendingPathComponent("voice-events", isDirectory: true)
    }
}
