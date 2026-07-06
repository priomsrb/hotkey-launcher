import Cocoa

/// Floating "Launching <App>…" bezel. A menu-bar-only launcher gives no
/// feedback between a cold-launch hotkey press and the app's first window
/// appearing, so this fills the gap. It also surfaces launch failures that
/// would otherwise be silent.
final class LaunchHUD {
    static let shared = LaunchHUD()

    private var panel: NSPanel?
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    /// Bundle ID the HUD is currently waiting on; nil when idle
    private var pendingBundleId: String?
    /// Bumped on every present() so stale timeouts and fade-out completions
    /// can't dismiss or hide a newer showing
    private var generation = 0
    private var timeoutTimer: Timer?

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
    }

    /// Show "Launching X…" until the app activates (or a timeout passes,
    /// in case the launch hangs). Safe to call from any thread.
    func showLaunching(bundleId: String, appName: String, icon: NSImage?) {
        DispatchQueue.main.async {
            self.present(text: "Launching \(appName)…", icon: icon, spinning: true)
            self.pendingBundleId = bundleId
            self.scheduleDismiss(after: 15)
        }
    }

    /// Show a launch failure briefly. Safe to call from any thread.
    func showLaunchFailed(appName: String, icon: NSImage?) {
        DispatchQueue.main.async {
            self.present(text: "Couldn't launch \(appName)", icon: icon, spinning: false)
            self.pendingBundleId = nil
            self.scheduleDismiss(after: 2.5)
        }
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard let pending = pendingBundleId,
              let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == pending else { return }
        pendingBundleId = nil
        waitForFirstWindow(pid: app.processIdentifier)
    }

    /// A cold-launching app activates before its first window is on screen,
    /// so fading on activation leaves a beat where nothing is visible. Hold
    /// the HUD until the app owns an onscreen window, bounded so an app that
    /// activates windowless can't pin the HUD forever.
    private func waitForFirstWindow(pid: pid_t, deadline: Date = Date().addingTimeInterval(5)) {
        if hasOnscreenWindow(pid: pid) || Date() >= deadline {
            fadeOut()
            return
        }
        let shownGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.generation == shownGeneration else { return }
            self.waitForFirstWindow(pid: pid, deadline: deadline)
        }
    }

    private func hasOnscreenWindow(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains { window in
            window[kCGWindowOwnerPID as String] as? Int == Int(pid)
                && window[kCGWindowLayer as String] as? Int == 0
        }
    }

    // MARK: - Presentation

    private func present(text: String, icon: NSImage?, spinning: Bool) {
        let panel = ensurePanel()
        generation += 1
        timeoutTimer?.invalidate()

        iconView.image = icon
        iconView.isHidden = (icon == nil)
        label.stringValue = text
        spinner.isHidden = !spinning
        if spinning {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        // Size to the new text and center on the screen the user is working on
        if let content = panel.contentView {
            content.layoutSubtreeIfNeeded()
            let size = content.fittingSize
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            let origin = NSPoint(x: visible.midX - size.width / 2,
                                 y: visible.minY + visible.height * 0.2)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        timeoutTimer?.invalidate()
        let shownGeneration = generation
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self = self, self.generation == shownGeneration else { return }
            self.pendingBundleId = nil
            self.fadeOut()
        }
    }

    private func fadeOut() {
        guard let panel = panel, panel.isVisible else { return }
        timeoutTimer?.invalidate()
        let shownGeneration = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.generation == shownGeneration else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.spinner.stopAnimation(nil)
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel = panel { return panel }

        // Non-activating so it never steals focus from the launching app,
        // statusBar level + canJoinAllSpaces/fullScreenAuxiliary so it shows
        // over everything, including fullscreen apps
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.appearance = NSAppearance(named: .vibrantDark)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true

        let stack = NSStackView(views: [iconView, label, spinner])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Pin edges with explicit constants: with .centerY alignment the
        // stack's own edgeInsets aren't enforced on the vertical axis
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])

        panel.contentView = effect
        self.panel = panel
        return panel
    }
}
