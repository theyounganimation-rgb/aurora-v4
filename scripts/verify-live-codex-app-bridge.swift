import Darwin
import Foundation
import Security

// This standalone verifier compiles only the app-server bridge files, so it
// mirrors the production validator's exact path, file-mode, bundle, team, and
// code-signature checks instead of weakening the trust boundary for a live run.
struct OpenAICodexExecutableValidator {
  static let expectedExecutableURL = URL(
    fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex",
    isDirectory: false
  )
  private static let expectedAppURL = URL(
    fileURLWithPath: "/Applications/ChatGPT.app",
    isDirectory: true
  )
  private static let expectedTeamID = "2DC432GLL2"
  private static let expectedBundleID = "com.openai.codex"

  func validate(executableURL: URL) throws {
    guard
      executableURL.standardizedFileURL
        == Self.expectedExecutableURL.standardizedFileURL
    else { throw LiveBridgeVerificationError.unsafeExecutable }
    try validateSafePath(executableURL, requireDirectory: false)
    try validateSafePath(Self.expectedAppURL, requireDirectory: true)
    guard Bundle(url: Self.expectedAppURL)?.bundleIdentifier == Self.expectedBundleID else {
      throw LiveBridgeVerificationError.unsafeExecutable
    }
    try validateSignature(at: Self.expectedAppURL, expectedIdentifier: Self.expectedBundleID)
    try validateSignature(at: executableURL, expectedIdentifier: nil)
  }

  private func validateSafePath(_ url: URL, requireDirectory: Bool) throws {
    var status = stat()
    guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
      throw LiveBridgeVerificationError.unsafeExecutable
    }
    let type = status.st_mode & S_IFMT
    guard type == (requireDirectory ? S_IFDIR : S_IFREG),
      (status.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else { throw LiveBridgeVerificationError.unsafeExecutable }
    let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values?.isSymbolicLink != true else {
      throw LiveBridgeVerificationError.unsafeExecutable
    }
  }

  private func validateSignature(at url: URL, expectedIdentifier: String?) throws {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else { throw LiveBridgeVerificationError.unsafeExecutable }
    var requirement: SecRequirement?
    let requirementText =
      "anchor apple generic and certificate leaf[subject.OU] = \"\(Self.expectedTeamID)\""
    guard
      SecRequirementCreateWithString(
        requirementText as CFString,
        [],
        &requirement
      ) == errSecSuccess,
      let requirement
    else { throw LiveBridgeVerificationError.unsafeExecutable }
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
    guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
      throw LiveBridgeVerificationError.unsafeExecutable
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let dictionary = information as? [String: Any],
      dictionary[kSecCodeInfoTeamIdentifier as String] as? String == Self.expectedTeamID
    else { throw LiveBridgeVerificationError.unsafeExecutable }
    if let expectedIdentifier,
      dictionary[kSecCodeInfoIdentifier as String] as? String != expectedIdentifier
    {
      throw LiveBridgeVerificationError.unsafeExecutable
    }
  }
}

private enum LiveBridgeVerificationError: LocalizedError {
  case explicitOptInRequired
  case sharedDaemonRequired
  case unsafeExecutable
  case activeThreadNotVisible
  case turnDidNotTerminate
  case turnIdentityChanged
  case unsafeArchiveAvoided
  case archivedThreadNotVisible
  case cleanupFailed(primary: String, cleanup: String)

  var errorDescription: String? {
    switch self {
    case .explicitOptInRequired:
      return "Set AURORA_VERIFY_LIVE_CODEX_APP_BRIDGE=1 to run the signed-in live bridge check."
    case .sharedDaemonRequired:
      return "The live bridge did not attach to Codex Desktop's shared daemon."
    case .unsafeExecutable:
      return "The ChatGPT-bundled Codex executable failed its production trust checks."
    case .activeThreadNotVisible:
      return "The completed protocol-only Codex thread was not visible in the active task list."
    case .turnDidNotTerminate:
      return "The protocol-only Codex turn did not reach a terminal state."
    case .turnIdentityChanged:
      return "A different Codex turn replaced the exact protocol-only turn under test."
    case .unsafeArchiveAvoided:
      return "The second turn's acceptance was unknown, so the verifier left the test thread visible instead of archiving potentially active work."
    case .archivedThreadNotVisible:
      return "The protocol-only Codex thread was not visible in the archived task list."
    case .cleanupFailed(let primary, let cleanup):
      return "Live bridge check failed (\(primary)); cleanup could not be proven (\(cleanup))."
    }
  }
}

@main
private enum LiveCodexAppBridgeVerifier {
  static func main() async throws {
    guard
      ProcessInfo.processInfo.environment[
        "AURORA_VERIFY_LIVE_CODEX_APP_BRIDGE"
      ] == "1"
    else {
      throw LiveBridgeVerificationError.explicitOptInRequired
    }

    var runtime = CodexTaskRuntime()
    let taskID = "aurora-live-bridge-\(UUID().uuidString.lowercased())"
    var activeTaskID = taskID
    let verificationToken = "aurora-live-bridge-\(UUID().uuidString.lowercased())"
    var createdThreadID: String?
    var createdTurnID: String?
    var createdOptions: CodexTaskThreadOptions?
    var terminalConfirmed = false
    do {
      guard try await runtime.supportsDetachedTaskPersistence() else {
        throw LiveBridgeVerificationError.sharedDaemonRequired
      }

      let options = CodexTaskThreadOptions(
        model: "gpt-5.6-sol",
        reasoningEffort: .low,
        workingDirectory: URL(
          fileURLWithPath: FileManager.default.currentDirectoryPath,
          isDirectory: true
        ),
        approvalPolicy: .never,
        sandboxMode: .readOnly,
        developerInstructions: nil,
        dynamicTools: [],
        threadName: verificationToken,
        ephemeral: false,
        requiresDetachedPersistence: true
      )

      let handle = try await runtime.startRawProjectThread(
        taskID: taskID,
        input:
          "Confirm that this signed-in Codex app-server turn started. Make no external changes.",
        options: options
      )
      createdThreadID = handle.threadID
      createdTurnID = handle.turnID
      createdOptions = options
      // Exercise the production project-chat path. A just-started app-server
      // thread can be readable by ID before its first user event reaches the
      // Desktop index, while exact reconciliation deliberately accepts only
      // indexed persistent tasks. Establish that durability boundary first;
      // interrupting or reconciling before it exists tests startup timing, not
      // the bridge Aurora uses for selected project conversations.
      try await waitUntilThreadVisible(
        runtime: runtime,
        threadID: handle.threadID,
        searchTerm: verificationToken,
        archived: false,
        timeout: .seconds(45),
        failure: .activeThreadNotVisible
      )
      try await waitForExactProjectTerminal(
        runtime: runtime,
        taskID: taskID,
        threadID: handle.threadID,
        turnID: handle.turnID,
        workingDirectory: options.workingDirectory!,
        timeout: .seconds(45)
      )
      terminalConfirmed = true

      try await runtime.renameThread(
        threadID: handle.threadID,
        name: verificationToken
      )

      // Reconnect before the second message so this is a genuine append to a
      // pre-existing Desktop chat, not merely another turn on an in-memory
      // runtime. This is the same boundary Aurora crosses after selecting an
      // older project chat by name.
      await runtime.shutdown()
      runtime = CodexTaskRuntime()
      guard try await runtime.supportsDetachedTaskPersistence() else {
        throw LiveBridgeVerificationError.sharedDaemonRequired
      }
      let continuedTaskID = "\(taskID)-existing"
      activeTaskID = continuedTaskID
      createdTurnID = nil
      terminalConfirmed = false
      let continued = try await runtime.sendExactMessage(
        taskID: continuedTaskID,
        threadID: handle.threadID,
        input: "Confirm this exact existing Codex chat accepted a second message. Make no external changes.",
        expectedWorkingDirectory: options.workingDirectory!
      )
      createdTurnID = continued.turnID
      try await waitForExactProjectTerminal(
        runtime: runtime,
        taskID: continuedTaskID,
        threadID: continued.threadID,
        turnID: continued.turnID,
        workingDirectory: options.workingDirectory!,
        timeout: .seconds(45)
      )
      terminalConfirmed = true

      try await archiveAndConfirm(
        runtime: runtime,
        threadID: handle.threadID,
        searchTerm: verificationToken,
        timeout: .seconds(4)
      )

      let payload: [String: Any] = [
        "ok": true,
        "authentication": "chatgpt",
        "sharedDaemon": true,
        "rawProjectChat": true,
        "threadCreated": true,
        "turnCreated": true,
        "existingThreadContinuedAfterReconnect": true,
        "threadArchived": true,
        "realModelCalls": 2,
      ]
      let data = try JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]
      )
      print(String(decoding: data, as: UTF8.self))
    } catch {
      let primaryError = error
      if createdThreadID == nil {
        createdThreadID = await runtime.threadID(forTaskID: taskID)
      }
      if let createdThreadID {
        do {
          try? await runtime.interruptTask(taskID: activeTaskID)
          if !terminalConfirmed {
            guard let turnID = createdTurnID,
              let workingDirectory = createdOptions?.workingDirectory
            else {
              throw LiveBridgeVerificationError.unsafeArchiveAvoided
            }
            // If the turn remains active, prove that exact turn is terminal
            // before hiding its thread from the user's task list.
            try await waitForExactProjectTerminal(
              runtime: runtime,
              taskID: activeTaskID,
              threadID: createdThreadID,
              turnID: turnID,
              workingDirectory: workingDirectory,
              timeout: .seconds(15)
            )
          }
          try await archiveAndConfirm(
            runtime: runtime,
            threadID: createdThreadID,
            searchTerm: nil,
            timeout: .seconds(4)
          )
        } catch {
          await runtime.shutdown()
          throw LiveBridgeVerificationError.cleanupFailed(
            primary: primaryError.localizedDescription,
            cleanup: error.localizedDescription
          )
        }
      }
      await runtime.shutdown()
      throw primaryError
    }
    await runtime.shutdown()
  }

  private static func waitForExactProjectTerminal(
    runtime: CodexTaskRuntime,
    taskID: String,
    threadID: String,
    turnID: String,
    workingDirectory: URL,
    timeout: Duration
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var observedExpectedTurn = false
    repeat {
      let observation = try await runtime.reconcileExactProjectThread(
        taskID: taskID,
        threadID: threadID,
        expectedWorkingDirectory: workingDirectory
      )
      if observedExpectedTurn, observation.latestTurnID != turnID {
        throw LiveBridgeVerificationError.turnIdentityChanged
      }
      if observation.latestTurnID == turnID {
        observedExpectedTurn = true
        if let status = observation.status, status != .running {
          return
        }
      }
      try await Task.sleep(for: .milliseconds(100))
    } while clock.now < deadline
    throw LiveBridgeVerificationError.turnDidNotTerminate
  }

  private static func archiveAndConfirm(
    runtime: CodexTaskRuntime,
    threadID: String,
    searchTerm: String?,
    timeout: Duration
  ) async throws {
    if try await threadIsVisible(
      runtime: runtime,
      threadID: threadID,
      searchTerm: searchTerm,
      archived: true
    ) {
      return
    }
    try await runtime.archiveThread(threadID: threadID)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    repeat {
      if try await threadIsVisible(
        runtime: runtime,
        threadID: threadID,
        searchTerm: searchTerm,
        archived: true
      ) {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    } while clock.now < deadline
    throw LiveBridgeVerificationError.archivedThreadNotVisible
  }

  private static func waitUntilThreadVisible(
    runtime: CodexTaskRuntime,
    threadID: String,
    searchTerm: String?,
    archived: Bool,
    timeout: Duration,
    failure: LiveBridgeVerificationError
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    repeat {
      if try await threadIsVisible(
        runtime: runtime,
        threadID: threadID,
        searchTerm: searchTerm,
        archived: archived
      ) {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    } while clock.now < deadline
    throw failure
  }

  private static func threadIsVisible(
    runtime: CodexTaskRuntime,
    threadID: String,
    searchTerm: String?,
    archived: Bool
  ) async throws -> Bool {
    if let searchTerm {
      let searched = try await runtime.listThreads(
        query: AuroraCodexThreadQuery(
          searchTerm: searchTerm,
          limit: 100,
          archived: archived
        ))
      if searched.threads.contains(where: { $0.threadID == threadID }) { return true }
    }
    // Search targets extracted titles, which may lag a just-written name. The
    // exact ID in the recent page is the authoritative visibility check.
    let recent = try await runtime.listThreads(
      query: AuroraCodexThreadQuery(limit: 100, archived: archived)
    )
    return recent.threads.contains(where: { $0.threadID == threadID })
  }
}
