import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct ScreenTarget: Sendable {
    let displayID: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int
}

private struct FrozenScreen: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let image: CGImage
}

@MainActor
final class ScreenshotCapture {
    private var panels: [NSPanel] = []
    private var cursorPushed = false
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var completion: ((Data?) -> Void)?
    private var preparationTask: Task<Void, Never>?

    private(set) var isActive = false

    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestPermission() -> Bool {
        guard !hasPermission else { return true }
        let granted = CGRequestScreenCaptureAccess()
        if !granted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return granted
    }

    func begin(completion: @escaping (Data?) -> Void) {
        guard !isActive else { return }
        isActive = true
        self.completion = completion

        let screens = NSScreen.screens
        let pointer = NSEvent.mouseLocation
        let activeScreen = screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        var windowsByDisplay: [CGDirectDisplayID: [CGRect]] = [:]
        let targets: [ScreenTarget] = screens.compactMap { screen in
            guard let id = Self.displayID(for: screen) else { return nil }
            windowsByDisplay[id] = Self.visibleWindowRects(for: id)
            let scale = max(1, screen.backingScaleFactor)
            return ScreenTarget(
                displayID: id,
                pixelWidth: max(1, Int((screen.frame.width * scale).rounded())),
                pixelHeight: max(1, Int((screen.frame.height * scale).rounded()))
            )
        }

        let capturedWindows = windowsByDisplay
        preparationTask = Task { [weak self] in
            guard let self else { return }
            let captured = await Self.captureAllScreens(targets: targets)
            guard self.isActive, !Task.isCancelled else { return }
            guard !captured.isEmpty else {
                self.finish(with: nil)
                return
            }
            var imagesByID: [CGDirectDisplayID: CGImage] = [:]
            for item in captured { imagesByID[item.displayID] = item.image }
            self.presentOverlay(screens: screens, images: imagesByID, windows: capturedWindows, activeScreen: activeScreen)
        }
    }

    func cancel() {
        guard isActive else { return }
        finish(with: nil)
    }

    private func presentOverlay(screens: [NSScreen], images: [CGDirectDisplayID: CGImage],
                                windows: [CGDirectDisplayID: [CGRect]], activeScreen: NSScreen?) {
        installEscapeMonitors()
        if !cursorPushed {
            NSCursor.crosshair.push()
            cursorPushed = true
        }

        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        let pointer = NSEvent.mouseLocation
        for screen in screens {
            guard let displayID = Self.displayID(for: screen), let image = images[displayID] else { continue }
            let panel = CapturePanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = level
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = true
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.setFrame(screen.frame, display: true)

            let showHint = activeScreen.map { Self.displayID(for: $0) == displayID } ?? false
            var initialHover: NSPoint?
            if screen.frame.contains(pointer) {
                initialHover = NSPoint(
                    x: pointer.x - screen.frame.minX,
                    y: screen.frame.maxY - pointer.y
                )
            }
            let view = CaptureSelectionView(
                frame: NSRect(origin: .zero, size: screen.frame.size),
                image: image,
                windowRects: windows[displayID] ?? [],
                initialHover: initialHover,
                showHint: showHint,
                onCompleteRegion: { [weak self] selection in
                    guard let self else { return }
                    let data = Self.renderAnnotatedCrop(
                        fullImage: image,
                        screenSize: screen.frame.size,
                        selection: selection
                    )
                    self.finish(with: data)
                },
                onCompleteWindow: { [weak self] windowRect in
                    guard let self else { return }
                    let data = Self.renderWindowCrop(
                        fullImage: image,
                        screenSize: screen.frame.size,
                        rect: windowRect
                    )
                    self.finish(with: data)
                },
                onCancel: { [weak self] in
                    self?.cancel()
                }
            )
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        if panels.isEmpty {
            finish(with: nil)
        }
    }

    private func finish(with data: Data?) {
        preparationTask?.cancel()
        preparationTask = nil
        removeEscapeMonitors()
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
        isActive = false
        let callback = completion
        completion = nil
        callback?(data)
    }

    private func installEscapeMonitors() {
        removeEscapeMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.cancel() }
            return nil
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func removeEscapeMonitors() {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        localKeyMonitor = nil
        globalKeyMonitor = nil
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    // Returns visible app window rects in top-left display-local points, front-to-back.
    private static func visibleWindowRects(for displayID: CGDirectDisplayID) -> [CGRect] {
        let displayBounds = CGDisplayBounds(displayID)
        guard displayBounds.width > 0, displayBounds.height > 0 else { return [] }
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let localScreen = CGRect(origin: .zero, size: displayBounds.size)
        var rects: [CGRect] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownPID { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let local = CGRect(
                x: cgRect.minX - displayBounds.minX,
                y: cgRect.minY - displayBounds.minY,
                width: cgRect.width,
                height: cgRect.height
            ).intersection(localScreen)
            if local.width >= 40, local.height >= 40 {
                rects.append(local)
            }
        }
        return rects
    }

    private nonisolated static func captureAllScreens(targets: [ScreenTarget]) async -> [FrozenScreen] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedApps = content.applications.filter { $0.processID == ownPID }

        var results: [FrozenScreen] = []
        for target in targets {
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else { continue }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
            let config = SCStreamConfiguration()
            config.width = target.pixelWidth
            config.height = target.pixelHeight
            config.showsCursor = false
            config.capturesAudio = false
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            ) else { continue }
            results.append(FrozenScreen(displayID: target.displayID, image: image))
        }
        return results
    }

    // Expands the user's selection with generous surrounding context, clamped to the screen.
    static func contextRect(for selection: CGRect, in bounds: CGRect) -> CGRect {
        let padX = min(max(selection.width * 0.65, 220), 420)
        let padY = min(max(selection.height * 0.65, 180), 340)
        return selection.insetBy(dx: -padX, dy: -padY).intersection(bounds)
    }

    static func renderAnnotatedCrop(fullImage: CGImage, screenSize: CGSize, selection: CGRect) -> Data? {
        guard screenSize.width > 0, screenSize.height > 0 else { return nil }
        let screenBounds = CGRect(origin: .zero, size: screenSize)
        let clampedSelection = selection.intersection(screenBounds)
        guard clampedSelection.width >= 4, clampedSelection.height >= 4 else { return nil }

        let context = contextRect(for: clampedSelection, in: screenBounds)
        let scaleX = CGFloat(fullImage.width) / screenSize.width
        let scaleY = CGFloat(fullImage.height) / screenSize.height
        let scale = (scaleX + scaleY) / 2

        let imageBounds = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
        let cropPixels = CGRect(
            x: context.minX * scaleX,
            y: context.minY * scaleY,
            width: context.width * scaleX,
            height: context.height * scaleY
        ).integral.intersection(imageBounds)

        guard cropPixels.width >= 4, cropPixels.height >= 4,
              let cropped = fullImage.cropping(to: cropPixels) else { return nil }

        let width = cropped.width
        let height = cropped.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cg = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        cg.interpolationQuality = .high
        cg.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Selection rectangle in CGContext coordinates (bottom-left origin).
        let selW = clampedSelection.width * scaleX
        let selH = clampedSelection.height * scaleY
        let selX = clampedSelection.minX * scaleX - cropPixels.minX
        let selYTop = clampedSelection.minY * scaleY - cropPixels.minY
        let selY = CGFloat(height) - selYTop - selH

        let lineWidth = max(3, 3.0 * scale)
        let rawBox = CGRect(x: selX, y: selY, width: selW, height: selH)
            .insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        let edgeMargin = lineWidth / 2 + scale
        let safeBounds = CGRect(
            x: edgeMargin,
            y: edgeMargin,
            width: max(1, CGFloat(width) - edgeMargin * 2),
            height: max(1, CGFloat(height) - edgeMargin * 2)
        )
        let box = rawBox.intersection(safeBounds)
        let cornerRadius = min(4.0 * scale, min(box.width, box.height) / 4)
        let path = CGPath(roundedRect: box, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // Subtle outer contrast halo so the red frame reads clearly against any background.
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 4 * scale, color: CGColor(gray: 0, alpha: 0.45))
        cg.setStrokeColor(CGColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0))
        cg.setLineWidth(lineWidth)
        cg.addPath(path)
        cg.strokePath()
        cg.restoreGState()

        guard let annotated = cg.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: annotated)
        return rep.representation(using: .png, properties: [:])
    }

    static func renderWindowCrop(fullImage: CGImage, screenSize: CGSize, rect: CGRect) -> Data? {
        guard screenSize.width > 0, screenSize.height > 0 else { return nil }
        let screenBounds = CGRect(origin: .zero, size: screenSize)
        let clamped = rect.intersection(screenBounds)
        guard clamped.width >= 4, clamped.height >= 4 else { return nil }

        let scaleX = CGFloat(fullImage.width) / screenSize.width
        let scaleY = CGFloat(fullImage.height) / screenSize.height
        let imageBounds = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
        let cropPixels = CGRect(
            x: clamped.minX * scaleX,
            y: clamped.minY * scaleY,
            width: clamped.width * scaleX,
            height: clamped.height * scaleY
        ).integral.intersection(imageBounds)

        guard cropPixels.width >= 4, cropPixels.height >= 4,
              let cropped = fullImage.cropping(to: cropPixels) else { return nil }

        let rep = NSBitmapImageRep(cgImage: cropped)
        return rep.representation(using: .png, properties: [:])
    }
}

private final class CaptureSelectionView: NSView {
    private let backgroundImage: NSImage
    private let windowRects: [CGRect]
    private let showHint: Bool
    private let onCompleteRegion: (CGRect) -> Void
    private let onCompleteWindow: (CGRect) -> Void
    private let onCancel: () -> Void
    private var hoverPoint: NSPoint?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, image: CGImage, windowRects: [CGRect], initialHover: NSPoint?, showHint: Bool,
         onCompleteRegion: @escaping (CGRect) -> Void, onCompleteWindow: @escaping (CGRect) -> Void,
         onCancel: @escaping () -> Void) {
        self.backgroundImage = NSImage(cgImage: image, size: frame.size)
        self.windowRects = windowRects
        self.hoverPoint = initialHover
        self.showHint = showHint
        self.onCompleteRegion = onCompleteRegion
        self.onCompleteWindow = onCompleteWindow
        self.onCancel = onCancel
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard dragStart == nil else { return }
        hoverPoint = nil
        needsDisplay = true
    }

    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let previousWindow = hoveredWindow
        hoverPoint = point
        if hoveredWindow != previousWindow {
            needsDisplay = true
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
            return
        }
        super.keyDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point
        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragCurrent = point
        let selection = currentSelection
        dragStart = nil
        dragCurrent = nil
        if let selection, selection.width >= 8, selection.height >= 8 {
            onCompleteRegion(selection)
        } else {
            let target = windowUnder(point) ?? bounds
            onCompleteWindow(target)
        }
    }

    private func windowUnder(_ point: NSPoint) -> CGRect? {
        windowRects.first { $0.contains(point) }
    }

    private var hoveredWindow: CGRect? {
        guard let hoverPoint else { return nil }
        return windowUnder(hoverPoint)
    }

    private var currentSelection: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        ).intersection(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundImage.draw(in: bounds)

        if let selection = currentSelection, selection.width >= 4, selection.height >= 4 {
            let context = ScreenshotCapture.contextRect(for: selection, in: bounds)

            // Dim everything outside the surrounding-context region so the user sees what is included.
            let dimPath = NSBezierPath(rect: bounds)
            dimPath.appendRect(context)
            dimPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.32).setFill()
            dimPath.fill()

            // Subtle dashed outline showing the surrounding-context crop edge.
            let contextPath = NSBezierPath(rect: context.insetBy(dx: 0.5, dy: 0.5))
            let dashes: [CGFloat] = [6, 4]
            contextPath.setLineDash(dashes, count: dashes.count, phase: 0)
            contextPath.lineWidth = 1
            NSColor.white.withAlphaComponent(0.7).setStroke()
            contextPath.stroke()

            // Crisp red box around the selected target region.
            let highlight = selection.insetBy(dx: -1.5, dy: -1.5)
            let boxPath = NSBezierPath(roundedRect: highlight, xRadius: 4, yRadius: 4)
            boxPath.lineWidth = 3
            NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0).setStroke()
            boxPath.stroke()
        } else if let hovered = hoveredWindow {
            // Spotlight the window under the pointer so single-click capture is obvious.
            let dimPath = NSBezierPath(rect: bounds)
            dimPath.appendRect(hovered)
            dimPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.30).setFill()
            dimPath.fill()

            let outline = NSBezierPath(roundedRect: hovered.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
            outline.lineWidth = 2.5
            NSColor.white.withAlphaComponent(0.85).setStroke()
            outline.stroke()

            if showHint {
                drawHintPill()
            }
        } else {
            NSColor.black.withAlphaComponent(0.22).setFill()
            bounds.fill()
            if showHint {
                drawHintPill()
            }
        }
    }

    private func drawHintPill() {
        let text = "Klikk for hele vinduet · Dra for område · Esc for å avbryte"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padX: CGFloat = 16
        let padY: CGFloat = 9
        let pill = CGRect(
            x: bounds.midX - (size.width + padX * 2) / 2,
            y: 44,
            width: size.width + padX * 2,
            height: size.height + padY * 2
        )
        let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        NSColor.black.withAlphaComponent(0.78).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        path.lineWidth = 1
        path.stroke()
        (text as NSString).draw(at: NSPoint(x: pill.minX + padX, y: pill.minY + padY), withAttributes: attributes)
    }
}
