import AppKit
import MacParakeetViewModels
import SwiftUI

private final class MeetingRecordingClickablePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Custom content view that forwards right-click for context menu.
private class PillContentView: NSView {
    var onRightClick: ((NSEvent) -> Void)?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {}

    private var activePillRect: NSRect {
        let height = min(bounds.height, 86)
        return NSRect(
            x: bounds.minX,
            y: bounds.midY - height / 2,
            width: bounds.width,
            height: height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        activePillRect.contains(point) ? super.hitTest(point) : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard activePillRect.contains(point) else { return }
        onRightClick?(event)
    }
}

/// Menu delegate that handles context menu item actions via target-action.
private class PillMenuDelegate: NSObject {
    let onStop: () -> Void
    let onOpen: () -> Void
    let onCancel: () -> Void
    let onPauseToggle: () -> Void

    init(
        onStop: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onPauseToggle: @escaping () -> Void
    ) {
        self.onStop = onStop
        self.onOpen = onOpen
        self.onCancel = onCancel
        self.onPauseToggle = onPauseToggle
    }

    @objc func menuAction(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "stop": onStop()
        case "open": onOpen()
        case "cancel": onCancel()
        case "pauseToggle": onPauseToggle()
        default: break
        }
    }
}

@MainActor
final class MeetingRecordingPillController {
    private var panel: NSPanel?
    private var preservedFrameForNextShow: NSRect?
    private weak var pillView: MeetingRecordingAppKitPillView?
    private let pillViewModel: MeetingRecordingPillViewModel
    var onClick: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onOpenApp: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    var isVisible: Bool { panel != nil }

    init(viewModel: MeetingRecordingPillViewModel) {
        self.pillViewModel = viewModel
    }

    func show() {
        if let panel {
            panel.orderFront(nil)
            // Back-to-back recordings can reuse the saved-completion pill; push
            // the fresh state now instead of waiting for the 1 s view tick.
            pillView?.refresh()
            return
        }

        let view = MeetingRecordingAppKitPillView(
            viewModel: pillViewModel,
            onTap: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.onClick?()
                }
            }
        )

        let panelWidth = MeetingRecordingAppKitPillView.panelSize.width
        let panelHeight = MeetingRecordingAppKitPillView.panelSize.height

        // Content view with right-click support
        let contentView = PillContentView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        contentView.autoresizingMask = [.width, .height]
        contentView.onRightClick = { [weak self] event in
            self?.showContextMenu(with: event)
        }

        view.frame = contentView.bounds
        view.autoresizingMask = [.width, .height]
        contentView.addSubview(view)
        self.pillView = view

        let panel = MeetingRecordingClickablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentView = contentView

        if let preservedFrame = preservedFrameForNextShow {
            panel.setFrame(preservedFrame, display: false)
            preservedFrameForNextShow = nil
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.maxX - panelWidth
            let y = frame.midY - panelHeight / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel
    }

    func hide(preserveFrameForNextShow: Bool = false) {
        if preserveFrameForNextShow {
            if let frame = panel?.frame {
                preservedFrameForNextShow = frame
            }
        } else {
            preservedFrameForNextShow = nil
        }
        panel?.orderOut(nil)
        panel = nil
        pillView = nil
    }

    /// Forwards the coordinator's fast (~30 fps) audio level to the pill so the
    /// parakeet's head bop tracks speech live. No-op once the pill is hidden.
    func updateLiveAudioLevel(_ level: Float) {
        pillView?.updateLiveAudioLevel(level)
    }

    /// Push a view-model state change to the pill immediately, so the
    /// recording → completing → transcribing → completed faces switch on the
    /// transition rather than on the pill's next 1 s tick. No-op once hidden.
    func refreshState() {
        pillView?.refresh()
    }

    // MARK: - Context Menu

    private func showContextMenu(with event: NSEvent) {
        guard let contentView = panel?.contentView else { return }

        // The menu must read honestly in every pill face: the recording menu's
        // items (pause, End & Transcribe, Discard) are silent no-ops once the
        // flow has moved past recording, so post-stop states get their own
        // menus.
        switch pillViewModel.state {
        case .completing, .transcribing:
            showTranscribingContextMenu(with: event, for: contentView)
            return
        case .completed, .error, .idle:
            showInertContextMenu(with: event, for: contentView)
            return
        case .starting, .recording, .paused:
            break
        }

        let menu = NSMenu()

        let delegate = PillMenuDelegate(
            onStop: { [weak self] in
                Task { @MainActor [weak self] in self?.onStopRecording?() }
            },
            onOpen: { [weak self] in
                Task { @MainActor [weak self] in self?.onOpenApp?() }
            },
            onCancel: { [weak self] in
                Task { @MainActor [weak self] in self?.onCancelRecording?() }
            },
            onPauseToggle: { [weak self] in
                Task { @MainActor [weak self] in self?.onPauseToggle?() }
            }
        )

        // Listening / Paused header — organic language matching the flower
        // metaphor; reflects the live state so the menu reads honestly when
        // opened mid-pause. Keeping the leaf symbol across both states
        // preserves the brand vocabulary (`leaf` / `leaf.fill` for active /
        // completing); a paused recording is still "the leaf, dormant".
        let isPaused = pillViewModel.isPaused
        let elapsed = pillViewModel.formattedElapsed
        let headerTitle =
            pillViewModel.state == .starting
            ? "Starting audio capture…"
            : (isPaused ? "Paused — \(elapsed)" : "Listening — \(elapsed)")
        let headerSymbol = "leaf"
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        if let headerImage = NSImage(systemSymbolName: headerSymbol, accessibilityDescription: nil) {
            headerItem.image = headerImage.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            headerItem.image?.isTemplate = true
        }
        menu.addItem(headerItem)

        menu.addItem(.separator())

        // Pause / Resume — issue #235. Sits above End & Transcribe so the
        // flow is "pause → think → resume" without leaving the menu.
        if pillViewModel.canTogglePause {
            let pauseItem = NSMenuItem(
                title: isPaused ? "Resume Recording" : "Pause Recording",
                action: #selector(PillMenuDelegate.menuAction(_:)),
                keyEquivalent: ""
            )
            pauseItem.representedObject = "pauseToggle"
            pauseItem.target = delegate
            if let pauseImage = NSImage(
                systemSymbolName: isPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
            {
                pauseItem.image = pauseImage.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
                pauseItem.image?.isTemplate = true
            }
            menu.addItem(pauseItem)
        }

        // End & Transcribe — the flower completes its cycle
        let stopItem = NSMenuItem(
            title: "End & Transcribe", action: #selector(PillMenuDelegate.menuAction(_:)), keyEquivalent: "")
        stopItem.representedObject = "stop"
        stopItem.target = delegate
        if let stopImage = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil) {
            stopItem.image = stopImage.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            stopItem.image?.isTemplate = true
        }
        menu.addItem(stopItem)

        let openItem = NSMenuItem(
            title: "Open PDX Edition", action: #selector(PillMenuDelegate.menuAction(_:)), keyEquivalent: "")
        openItem.representedObject = "open"
        openItem.target = delegate
        if let openImage = NSImage(systemSymbolName: "bird", accessibilityDescription: nil) {
            openItem.image = openImage.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            openItem.image?.isTemplate = true
        }
        menu.addItem(openItem)

        menu.addItem(.separator())

        // Discard — destructive, red
        let cancelItem = NSMenuItem(
            title: "Discard Recording", action: #selector(PillMenuDelegate.menuAction(_:)), keyEquivalent: "")
        cancelItem.representedObject = "cancel"
        cancelItem.target = delegate
        cancelItem.attributedTitle = NSAttributedString(
            string: "Discard Recording",
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        if let cancelImage = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                .applying(.init(paletteColors: [.systemRed]))
            cancelItem.image = cancelImage.withSymbolConfiguration(config)
        }
        menu.addItem(cancelItem)

        // Keep delegate alive while menu is open
        objc_setAssociatedObject(menu, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
    }

    /// Context menu shown during the brief transcribing pill state: an honest
    /// header plus Open. Final transcription now runs in the background queue
    /// after the durable stop boundary, so there is no in-flight abort action.
    private func showTranscribingContextMenu(with event: NSEvent, for contentView: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let delegate = PillMenuDelegate(
            onStop: {},
            onOpen: { [weak self] in
                Task { @MainActor [weak self] in self?.onOpenApp?() }
            },
            onCancel: {},
            onPauseToggle: {}
        )

        let headerItem = NSMenuItem(title: "Transcribing meeting", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        if let headerImage = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) {
            headerItem.image = headerImage.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            headerItem.image?.isTemplate = true
        }
        menu.addItem(headerItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Open PDX Edition", action: #selector(PillMenuDelegate.menuAction(_:)), keyEquivalent: "")
        openItem.representedObject = "open"
        openItem.target = delegate
        openItem.isEnabled = true
        if let openImage = NSImage(systemSymbolName: "bird", accessibilityDescription: nil) {
            openItem.image = openImage.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            openItem.image?.isTemplate = true
        }
        menu.addItem(openItem)

        objc_setAssociatedObject(menu, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
    }

    /// Context menu for the settled faces (checkmark / error). Nothing is
    /// actionable on the recording itself anymore — just offer the app.
    private func showInertContextMenu(with event: NSEvent, for contentView: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let delegate = PillMenuDelegate(
            onStop: {},
            onOpen: { [weak self] in
                Task { @MainActor [weak self] in self?.onOpenApp?() }
            },
            onCancel: {},
            onPauseToggle: {}
        )

        let headerTitle: String
        switch pillViewModel.state {
        case .completed:
            headerTitle = "Saved to Library"
        case .error:
            headerTitle = "Recording interrupted"
        default:
            headerTitle = "MacParakeet"
        }
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Open PDX Edition", action: #selector(PillMenuDelegate.menuAction(_:)), keyEquivalent: "")
        openItem.representedObject = "open"
        openItem.target = delegate
        openItem.isEnabled = true
        if let openImage = NSImage(systemSymbolName: "bird", accessibilityDescription: nil) {
            openItem.image = openImage.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            openItem.image?.isTemplate = true
        }
        menu.addItem(openItem)

        objc_setAssociatedObject(menu, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
    }
}

private final class MeetingRecordingAppKitPillView: NSView {
    private let viewModel: MeetingRecordingPillViewModel
    private let onTap: () -> Void
    private let iconView = MerkabaPillIconView()
    private let backgroundLayer = CAShapeLayer()
    private let pauseLayer = CALayer()
    // Inline "Recording" / "Paused" title + running timer to the right of the
    // parakeet — the PDX horizontal pill (`MeetingRecordingPillView`'s
    // `sacredRecordingPill`), always visible rather than hover-only.
    private let titleLayer = CATextLayer()
    private let timerLayer = CATextLayer()
    /// 1 s ticker for the elapsed timer. A `@MainActor` `Task` rather than a
    /// `Timer` so (a) its body runs in-isolation (no nonisolated `@Sendable`
    /// hop to call `updateFromViewModel`) and (b) `Task` is `Sendable`, so the
    /// nonisolated `deinit` can cancel it — both Swift 6 language-mode clean.
    private var tickTask: Task<Void, Never>?
    private var completionCallbackScheduled = false
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var renderedState: MeetingRecordingPillViewModel.PillState?
    private var renderedHover: Bool?
    private var renderedReduceMotion: Bool?
    /// Side of the centered mark inside the circular surface (starting head,
    /// spinner/Metatron/check). `nil` = the mark sits in the capsule's leading
    /// slot next to the title + timer.
    private var compactIconSide: CGFloat?
    /// Recording/paused draw a wide horizontal capsule (mark + title + timer);
    /// the states without a label (starting, saving, saved) use a circle that
    /// hugs the mark — matching the prior SwiftUI pill's separate `iconPill`.
    /// The circle keeps the capsule's leading edge, so the collapse reads as the
    /// title and timer being absorbed into the parakeet.
    private var compactContainer = false

    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let timerFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let pillHeight: CGFloat = 50
    private static let edgeMargin: CGFloat = 20
    private static let horizontalPadding: CGFloat = 14
    private static let markSize: CGFloat = 30
    private static let markTextGap: CGFloat = 10
    private static let textLineGap: CGFloat = 1
    /// Centered mark sizes inside the circular surface.
    private static let compactIconSize: CGFloat = 35
    private static let headIconSize: CGFloat = 26
    private static let titleLineHeight = ceil(("Recording" as NSString).size(withAttributes: [.font: titleFont]).height)
    private static let timerLineHeight = ceil(("0:00" as NSString).size(withAttributes: [.font: timerFont]).height)
    /// Fixed text column so the capsule doesn't resize as the timer ticks or the
    /// title flips between "Recording" and "Paused". "000:00" leaves room for a
    /// meeting past 99 minutes (`formattedElapsed` doesn't roll into hours).
    private static let textColumnWidth: CGFloat = {
        let title = ("Recording" as NSString).size(withAttributes: [.font: titleFont]).width
        let timer = ("000:00" as NSString).size(withAttributes: [.font: timerFont]).width
        return ceil(max(title, timer))
    }()
    private static let wideWidth = horizontalPadding * 2 + markSize + markTextGap + textColumnWidth

    /// Size of the floating panel that hosts this view: the capsule, its margin
    /// from the screen edge, and a little slack so the hover stroke never clips.
    static let panelSize = CGSize(width: wideWidth + edgeMargin + 8, height: pillHeight + 16)

    /// System Settings → Accessibility → Display → Reduce Motion. The pill
    /// still shows (and tracks recording state via color/timer), it just stops
    /// spinning the rosette for vestibular-sensitive users — matching the
    /// `reduceMotion` gate the prior SwiftUI pill and every other animated
    /// surface honor.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override var isFlipped: Bool { true }

    init(viewModel: MeetingRecordingPillViewModel, onTap: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onTap = onTap
        super.init(frame: .zero)
        wantsLayer = true
        setupLayers()
        updateFromViewModel()
        // Drives the per-second elapsed badge text. State *transitions* are
        // pushed promptly by the coordinator via `refresh()` (see
        // `MeetingRecordingPillController.refreshState()`), so the stop →
        // collapse → spinner → checkmark sequence reacts immediately instead of
        // waiting up to a poll interval.
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                self?.updateFromViewModel()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reduceMotionDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        tickTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func reduceMotionDidChange() {
        updateFromViewModel()
    }

    /// Pull the latest view-model state immediately (pushed by the coordinator
    /// on a state transition, so animations don't wait for the 1 s timer).
    func refresh() {
        updateFromViewModel()
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        titleLayer.contentsScale = scale
        timerLayer.contentsScale = scale
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        onTap()
    }

    private func setupLayers() {
        guard let layer else { return }
        layer.masksToBounds = false
        backgroundLayer.fillColor = NSColor.black.withAlphaComponent(0.88).cgColor
        backgroundLayer.strokeColor = NSColor.white.withAlphaComponent(0.08).cgColor
        backgroundLayer.lineWidth = 0.5
        layer.addSublayer(backgroundLayer)

        // Head-only mark: the horizontal pill has no stem, so the icon view lays
        // the parakeet out in a square of `min(width, height)`.
        iconView.configure(showStem: false)
        addSubview(iconView)

        let leftBar = pauseBar()
        let rightBar = pauseBar()
        leftBar.frame.origin.x = 0
        rightBar.frame.origin.x = 7
        pauseLayer.addSublayer(leftBar)
        pauseLayer.addSublayer(rightBar)
        pauseLayer.isHidden = true
        layer.addSublayer(pauseLayer)

        setupLabels(in: layer)
    }

    private func setupLabels(in root: CALayer) {
        let scale = window?.backingScaleFactor ?? 2
        for (textLayer, font, alpha) in [
            (titleLayer, Self.titleFont, 0.92),
            (timerLayer, Self.timerFont, 0.6),
        ] {
            textLayer.font = font
            textLayer.fontSize = font.pointSize
            textLayer.foregroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
            textLayer.alignmentMode = .left
            textLayer.contentsScale = scale
            textLayer.isWrapped = false
            // Hidden until a recording/paused state supplies the text.
            textLayer.opacity = 0
            root.addSublayer(textLayer)
        }
    }

    private func pauseBar() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer.cornerRadius = 1.5
        layer.frame = CGRect(x: 0, y: 0, width: 3, height: 11)
        return layer
    }

    private func layoutLayers() {
        // The mark, pause bars and labels are positioned from the *wide* rect so
        // they stay put across the recording/completing cycle. Label-less compact
        // states center their mark inside the circular surface instead.
        let wideRect = containerRect(compact: false)
        let compactRect = containerRect(compact: true)
        backgroundLayer.path = backgroundPath(compact: compactContainer)

        let leadingMark = CGRect(
            x: wideRect.minX + Self.horizontalPadding,
            y: wideRect.midY - Self.markSize / 2,
            width: Self.markSize,
            height: Self.markSize
        )
        if let side = compactIconSide {
            iconView.frame = CGRect(
                x: compactRect.midX - side / 2,
                y: compactRect.midY - side / 2,
                width: side,
                height: side
            )
        } else {
            iconView.frame = leadingMark
        }
        pauseLayer.frame = CGRect(x: leadingMark.midX - 5, y: leadingMark.midY - 5.5, width: 10, height: 11)

        // Two-line stack (title over timer), vertically centered beside the mark.
        let textX = leadingMark.maxX + Self.markTextGap
        let stackHeight = Self.titleLineHeight + Self.textLineGap + Self.timerLineHeight
        let stackTop = wideRect.midY - stackHeight / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.frame = CGRect(
            x: textX, y: stackTop, width: Self.textColumnWidth + 1, height: Self.titleLineHeight)
        timerLayer.frame = CGRect(
            x: textX, y: stackTop + Self.titleLineHeight + Self.textLineGap,
            width: Self.textColumnWidth + 1, height: Self.timerLineHeight)
        CATransaction.commit()
    }

    /// The capsule rect for a given state. Both shapes share the same leading
    /// edge and vertical center; the compact circle just stops at `pillHeight`
    /// wide, so the trailing end pulls in toward the parakeet.
    private func containerRect(compact: Bool) -> CGRect {
        let width = compact ? Self.pillHeight : Self.wideWidth
        return CGRect(
            x: bounds.maxX - Self.edgeMargin - Self.wideWidth,
            y: bounds.midY - Self.pillHeight / 2,
            width: width,
            height: Self.pillHeight
        )
    }

    private func backgroundPath(compact: Bool) -> CGPath {
        // cornerRadius = pillHeight/2 → stadium when wide, perfect circle when compact.
        CGPath(
            roundedRect: containerRect(compact: compact),
            cornerWidth: Self.pillHeight / 2,
            cornerHeight: Self.pillHeight / 2,
            transform: nil
        )
    }

    /// Switch the capsule between wide and circular. When `animated`, the path
    /// interpolates from its current presentation — slowly on the stop →
    /// collapse (the title and timer are absorbed as the parakeet flies off),
    /// quickly on starting → recording (the capsule grows out to make room for
    /// them); otherwise it snaps (fresh layout).
    private func applyContainer(compact: Bool, animated: Bool) {
        compactContainer = compact
        let newPath = backgroundPath(compact: compact)
        if animated {
            let resize = CABasicAnimation(keyPath: "path")
            resize.fromValue = backgroundLayer.presentation()?.path ?? backgroundLayer.path
            resize.toValue = newPath
            if compact {
                resize.duration = reduceMotion ? 0.4 : 0.85
            } else {
                resize.duration = reduceMotion ? 0.15 : 0.3
            }
            resize.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            backgroundLayer.add(resize, forKey: "containerResize")
        } else {
            // Snap: drop any in-flight collapse resize so a back-to-back
            // recording that starts mid-collapse doesn't keep shrinking to a
            // circle before settling on the capsule.
            backgroundLayer.removeAnimation(forKey: "containerResize")
        }
        backgroundLayer.path = newPath
    }

    /// Inline title + running timer beside the parakeet. Visible for recording
    /// and paused; every other state fades them out. The timer text refreshes
    /// on the 1 s tick.
    private func updateLabels() {
        let title: String?
        switch viewModel.state {
        case .recording: title = "Recording"
        case .paused: title = "Paused"
        default: title = nil
        }

        if let title {
            // Update the text without implicit animation so digits change crisply;
            // the fade in/out below is driven separately by opacity.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if (titleLayer.string as? String) != title {
                titleLayer.string = title
            }
            let elapsed = viewModel.formattedElapsed
            if (timerLayer.string as? String) != elapsed {
                timerLayer.string = elapsed
            }
            CATransaction.commit()
        }

        let target: Float = title == nil ? 0 : 1
        if titleLayer.opacity != target {
            titleLayer.opacity = target
            timerLayer.opacity = target
        }
    }

    /// Live audio level pushed from the coordinator's fast (~30 fps) channel.
    /// Drives only the parakeet's head bop/chirp (routed through the icon's own
    /// `@Observable` state, so only the mark re-renders) — never the pill view
    /// model — so the head tracks speech without the per-tick relayout that the
    /// 1 s state poll would cause.
    func updateLiveAudioLevel(_ level: Float) {
        iconView.setLiveGlow(level: level)
    }

    /// Place the mark: `nil` = the capsule's leading slot beside the title and
    /// timer; a side length = centered in the circular surface at that size.
    private func setCompactIconSide(_ side: CGFloat?) {
        guard compactIconSide != side else { return }
        compactIconSide = side
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func updateFromViewModel() {
        let state = viewModel.state
        let reduceMotion = self.reduceMotion

        // The elapsed time ticks every second even when state is unchanged
        // (e.g. silence), so refresh the timer before the render-skip.
        updateLabels()

        if renderedState == state, renderedReduceMotion == reduceMotion {
            updateBackgroundIfNeeded()
            return
        }

        renderedState = state
        renderedReduceMotion = reduceMotion
        setAccessibilityLabel(state == .starting ? "Starting meeting audio capture" : nil)

        switch state {
        case .starting:
            completionCallbackScheduled = false
            pauseLayer.isHidden = true
            iconView.alphaValue = 0.45
            setCompactIconSide(Self.headIconSize)
            applyContainer(compact: true, animated: false)
            iconView.update(isAnimating: false, audioLevel: 0)
        case .recording:
            // Re-arm the one-shot collapse callback for a fresh recording cycle.
            // A back-to-back meeting can reuse this pill view if the previous
            // saved-completion celebration hasn't torn it down yet; without this
            // reset, the next `.completing` would skip the collapse and the pill
            // would hang (its `onCompletionAnimationFinished` never fires).
            completionCallbackScheduled = false
            pauseLayer.isHidden = true
            iconView.alphaValue = 1.0
            setCompactIconSide(nil)
            // Grow out of the starting circle (or a collapse a back-to-back
            // meeting interrupted); a fresh view already draws the capsule.
            applyContainer(compact: false, animated: compactContainer && backgroundLayer.path != nil)
            // The bob/chirp is driven live by updateLiveAudioLevel; this sets the
            // resting base + starts the idle bob.
            iconView.update(isAnimating: !reduceMotion, audioLevel: 0)
        case .paused:
            pauseLayer.isHidden = false
            iconView.alphaValue = 0.45
            setCompactIconSide(nil)
            applyContainer(compact: false, animated: false)
            iconView.update(isAnimating: false, audioLevel: 0)
        case .completing:
            pauseLayer.isHidden = true
            iconView.alphaValue = 1.0
            setCompactIconSide(nil)
            // Pull the capsule in to a circle as the parakeet flies off.
            applyContainer(compact: true, animated: true)
            playCompletionIfNeeded(reduceMotion: reduceMotion)
        case .transcribing:
            pauseLayer.isHidden = true
            iconView.alphaValue = 1.0
            setCompactIconSide(Self.compactIconSize)
            applyContainer(compact: true, animated: false)
            // The post-collapse "saving" state: the Metatron's Cube blooms and
            // holds (CA-driven) until the recording is durably queued, when the
            // coordinator advances to `.completed` and the cube resolves to the check.
            iconView.showMetatron(animated: !reduceMotion)
        case .completed:
            pauseLayer.isHidden = true
            iconView.alphaValue = 1.0
            setCompactIconSide(Self.compactIconSize)
            applyContainer(compact: true, animated: false)
            iconView.showCheckmark(animated: !reduceMotion)
        case .idle, .error:
            pauseLayer.isHidden = true
            iconView.alphaValue = 1.0
            setCompactIconSide(Self.headIconSize)
            applyContainer(compact: true, animated: false)
            iconView.update(isAnimating: false, audioLevel: 0)
        }
        updateBackgroundIfNeeded()
    }

    /// The merkaba collapse plays once; its completion (~1 s, or a quick fade
    /// under Reduce Motion) advances the flow to the spinner/checkmark.
    private func playCompletionIfNeeded(reduceMotion: Bool) {
        guard !completionCallbackScheduled else { return }
        completionCallbackScheduled = true
        iconView.playCompletion(reduceMotion: reduceMotion) { [weak self] in
            self?.viewModel.onCompletionAnimationFinished?()
        }
    }

    private func updateBackground() {
        renderedHover = nil
        updateBackgroundIfNeeded()
    }

    private func updateBackgroundIfNeeded() {
        guard renderedHover != isHovered else { return }
        renderedHover = isHovered
        backgroundLayer.fillColor = NSColor.black.withAlphaComponent(isHovered ? 0.90 : 0.88).cgColor
        backgroundLayer.strokeColor = NSColor.white.withAlphaComponent(isHovered ? 0.15 : 0.08).cgColor
    }
}
