import AppKit

extension Notification.Name {
    static let auroraWindowWillClose = Notification.Name("ai.aurora.voice.window-will-close")
}

final class AuroraAppDelegate: NSObject, NSApplicationDelegate {
    typealias TerminationHandler = @MainActor @Sendable () async -> Void

    private enum TerminationState {
        case idle
        case waitingForCleanup
        case replied
    }

    private var terminationHandler: TerminationHandler?
    private var terminationState: TerminationState = .idle

    @MainActor
    func installTerminationHandler(_ handler: @escaping TerminationHandler) {
        terminationHandler = handler
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if AURORA_LEGACY_MOTOR
        if AuroraLaunchMode.closeTabEffectSelfTest {
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task.detached {
                let report = await InstalledCloseTabEffectSelfTest.run()
                InstalledCloseTabEffectSelfTest.emit(report)
                await MainActor.run { NSApp.terminate(nil) }
            }
            return
        }
        if AuroraLaunchMode.mediaControlSelfTest {
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task.detached {
                let report = await InstalledMediaControlSelfTest.run()
                InstalledMediaControlSelfTest.emit(report)
                await MainActor.run { NSApp.terminate(nil) }
            }
            return
        }
        if AuroraLaunchMode.textEditWriteSelfTest {
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task.detached {
                let report = await InstalledTextEditWriteSelfTest.run()
                InstalledTextEditWriteSelfTest.emit(report)
                await MainActor.run { NSApp.terminate(nil) }
            }
            return
        }
        if AuroraLaunchMode.wallpaperClearSelfTest {
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task.detached {
                let report = await InstalledWallpaperClearSelfTest.run()
                InstalledWallpaperClearSelfTest.emit(report)
                await MainActor.run { NSApp.terminate(nil) }
            }
            return
        }
        if AuroraLaunchMode.youtubeLiveComputerUseSelfTest {
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task.detached {
                let report = await InstalledYouTubeComputerUseSelfTest.run()
                InstalledYouTubeComputerUseSelfTest.emit(report)
                await MainActor.run { NSApp.terminate(nil) }
            }
            return
        }
        if AuroraLaunchMode.chromeTabControlSelfTest {
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task.detached {
                let report = await InstalledChromeTabControlSelfTest.run()
                InstalledChromeTabControlSelfTest.emit(report)
                await MainActor.run { NSApp.terminate(nil) }
            }
            return
        }
        if AuroraLaunchMode.computerUseEndToEndSelfTest {
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task.detached {
                let report = await InstalledComputerUseEndToEndSelfTest.run()
                InstalledComputerUseEndToEndSelfTest.emit(report)
                await MainActor.run { NSApp.terminate(nil) }
            }
            return
        }
        if AuroraLaunchMode.computerUseAPISelfTest {
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task.detached {
                let report = await InstalledComputerUseAPISelfTest.run()
                InstalledComputerUseAPISelfTest.emit(report)
                await MainActor.run { NSApp.terminate(nil) }
            }
            return
        }
        if AuroraLaunchMode.screenControlSelfTest {
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task.detached {
                let report = await InstalledScreenControlSelfTest.run()
                InstalledScreenControlSelfTest.emit(report)
                await MainActor.run { NSApp.terminate(nil) }
            }
            return
        }
#endif
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AuroraApplicationIcon.make()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        DispatchQueue.main.async {
            self.prepareWindows()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch terminationState {
        case .waitingForCleanup:
            // AppKit may ask again while the original request is pending. The
            // one in-flight cleanup task owns the eventual reply.
            return .terminateLater
        case .replied:
            // `reply(toApplicationShouldTerminate:)` may re-enter this
            // delegate on some termination paths. Never start cleanup twice.
            return .terminateNow
        case .idle:
            guard let terminationHandler else {
                // Do not leave the application permanently stuck if startup
                // failed before SwiftUI installed its model-owned handler.
                return .terminateNow
            }
            terminationState = .waitingForCleanup
            Task { @MainActor [weak self, weak sender] in
                await terminationHandler()
                guard let self,
                      self.terminationState == .waitingForCleanup else { return }
                self.terminationState = .replied
                sender?.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first(where: { !($0 is NSPanel) && $0.title == "Aurora" })?
                .makeKeyAndOrderFront(nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    private func prepareWindows() {
        for window in NSApp.windows {
            window.title = "Aurora"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.setContentSize(NSSize(width: 560, height: 650))
            window.minSize = NSSize(width: 480, height: 560)
            window.center()
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !(window is NSPanel),
              window.parent == nil,
              window.title == "Aurora" else { return }
        NotificationCenter.default.post(name: .auroraWindowWillClose, object: nil)
    }
}

private enum AuroraApplicationIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let tile = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 116, yRadius: 116)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.025, green: 0.03, blue: 0.055, alpha: 1),
            NSColor(calibratedRed: 0.08, green: 0.035, blue: 0.15, alpha: 1),
        ])?.draw(in: tile, angle: -45)

        let glowRect = NSRect(x: 82, y: 82, width: 348, height: 348)
        let glow = NSBezierPath(ovalIn: glowRect)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.95, green: 0.36, blue: 0.72, alpha: 0.92),
            NSColor(calibratedRed: 0.37, green: 0.44, blue: 1, alpha: 0.8),
        ])?.draw(in: glow, relativeCenterPosition: NSPoint(x: -0.18, y: 0.2))

        NSColor.white.withAlphaComponent(0.42).setStroke()
        let orbit = NSBezierPath(ovalIn: NSRect(x: 112, y: 112, width: 288, height: 288))
        orbit.lineWidth = 5
        orbit.stroke()

        NSColor.white.withAlphaComponent(0.72).setFill()
        NSBezierPath(ovalIn: NSRect(x: 226, y: 226, width: 60, height: 60)).fill()

        return image
    }
}
