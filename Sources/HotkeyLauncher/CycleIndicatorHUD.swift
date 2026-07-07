import Cocoa

/// Watches for the moment a set of modifier keys stops being held down.
/// A global flagsChanged monitor gives a snappy reaction (it needs the
/// Accessibility trust the app already has for window control); a polling
/// fallback via CGEventSource needs no permission at all, so release is
/// detected even if the monitor never fires.
final class ModifierWatcher {
    private let required: CGEventFlags
    private let onRelease: () -> Void
    private var monitor: Any?
    private var pollTimer: Timer?
    private(set) var isHeld = true

    init(required: CGEventFlags, onRelease: @escaping () -> Void) {
        self.required = required
        self.onRelease = onRelease
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            self?.check()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    private func check() {
        guard isHeld else { return }
        let current = CGEventSource.flagsState(.combinedSessionState)
        if !current.contains(required) {
            isHeld = false
            stop()
            onRelease()
        }
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    deinit { stop() }
}

/// Floating window-cycling indicator. While the hotkey's modifiers are held,
/// shows the cycle session's windows as a vertical list with the currently
/// focused one highlighted, so repeated presses of the same hotkey show how
/// many windows there are and which one is up next.
final class CycleIndicatorHUD {
    static let shared = CycleIndicatorHUD()

    private var panel: NSPanel?
    private let rowsStack = NSStackView()
    /// Bumped on every show() so a stale fade-out completion can't hide a
    /// newer showing (same trick as LaunchHUD)
    private var generation = 0

    /// A quick press-and-release shouldn't flash the indicator, so the first
    /// appearance is delayed; once visible, updates are instant
    private let appearanceDelay: TimeInterval = 0.1
    private var pendingReveal: DispatchWorkItem?

    private init() {}

    /// Rebuild the list and show it centered on the screen the user is
    /// working on. The first appearance is delayed by `appearanceDelay`;
    /// further calls while visible (or while a reveal is already pending)
    /// update the content without restarting the delay. Must be called on
    /// the main thread.
    func show(appIcon: NSImage?, titles: [String], selectedIndex: Int) {
        let panel = ensurePanel()
        generation += 1

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, title) in titles.enumerated() {
            let row = makeRow(icon: appIcon, title: title, selected: index == selectedIndex)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }

        if panel.isVisible {
            reveal()
        } else if pendingReveal == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingReveal = nil
                self?.reveal()
            }
            pendingReveal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + appearanceDelay, execute: work)
        }
    }

    /// Size to the current content, position, and order front
    private func reveal() {
        guard let panel = panel else { return }
        if let content = panel.contentView {
            content.layoutSubtreeIfNeeded()
            let size = content.fittingSize
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            let origin = NSPoint(x: visible.midX - size.width / 2,
                                 y: visible.midY - size.height / 2)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Fade out quickly, cancelling any not-yet-revealed showing. Safe to
    /// call when not showing.
    func hide() {
        pendingReveal?.cancel()
        pendingReveal = nil
        guard let panel = panel, panel.isVisible else { return }
        let shownGeneration = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.generation == shownGeneration else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    // MARK: - View construction

    private func makeRow(icon: NSImage?, title: String, selected: Bool) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        if selected {
            container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        }

        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
        return container
    }

    private func ensurePanel() -> NSPanel {
        if let panel = panel { return panel }

        // Same presentation as LaunchHUD: non-activating so it never steals
        // focus, statusBar level + canJoinAllSpaces/fullScreenAuxiliary so it
        // shows over everything, including fullscreen apps
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
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.appearance = NSAppearance(named: .vibrantDark)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            rowsStack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            rowsStack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 8),
            rowsStack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
        ])

        panel.contentView = effect
        self.panel = panel
        return panel
    }
}
