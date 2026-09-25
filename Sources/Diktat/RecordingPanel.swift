import AppKit
import SwiftUI

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RecordingPanel {
    private let panel: NSPanel
    private weak var controller: SessionController?
    private var hideTask: Task<Void, Never>?
    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?

    init(controller: SessionController) {
        self.controller = controller
        panel = PassivePanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 64),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: RecordingView(controller: controller))
    }

    func show() {
        hideTask?.cancel()
        monitorEscape()
        panel.setContentSize(size)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 48))
        }
        panel.orderFrontRegardless()
    }

    private var size: NSSize {
        if controller?.phase == .failed { return NSSize(width: 360, height: 160) }
        if controller?.confirmingDiscard == true { return NSSize(width: 360, height: 64) }
        return NSSize(width: 200, height: 64)
    }

    // Resize in place, keeping the panel centred where the user left it.
    func refresh() {
        guard panel.isVisible else { return }
        let frame = panel.frame
        let target = size
        let next = NSRect(x: frame.midX - target.width / 2, y: frame.minY, width: target.width, height: target.height)
        // The hosted view fills the panel, so the capsule grows with the frame.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(next, display: true)
        }
    }

    func hide() {
        hideTask?.cancel()
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        globalEscapeMonitor = nil
        localEscapeMonitor = nil
        panel.orderOut(nil)
    }

    private func monitorEscape() {
        guard globalEscapeMonitor == nil, localEscapeMonitor == nil else { return }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return }
            Task { @MainActor [weak self] in self?.controller?.dismissPanel() }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            // AppKit invokes event monitors on the main thread.
            MainActor.assumeIsolated { self?.controller?.dismissPanel() }
            return nil
        }
    }

    func hide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.hide()
        }
    }
}

private struct RecordingView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        Group {
            if controller.phase == .failed {
                VStack(spacing: 8) {
                    Text(controller.message).font(.caption)
                    if !controller.text.isEmpty {
                        Button("Kopier tilgjengelig tekst") { controller.copyRecovery() }
                    }
                    Button("Lukk") { controller.panel.hide() }
                }
            } else if controller.confirmingDiscard {
                HStack(spacing: 10) {
                    Text("Forkaste opptaket?").font(.callout).lineLimit(1).fixedSize()
                    ChoiceButton(title: "Fortsett", fill: .white.opacity(0.18)) { controller.keepRecording() }
                    ChoiceButton(title: "Forkast", fill: .red.opacity(0.85)) { controller.cancel() }
                }
                .fixedSize()
                .transition(.opacity)
            } else if controller.isListening {
                ZStack {
                    if controller.showBars {
                        LevelBars(level: controller.audioLevel)
                            .transition(.opacity)
                    } else {
                        MicrophoneBadge(device: controller.inputDevice)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: controller.showBars)
            } else if [.preparing, .finishing, .delivering, .cancelling].contains(controller.phase) {
                if controller.showProgress && [.finishing, .delivering].contains(controller.phase) {
                    Text("\(controller.progress) %")
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: false))
                        .animation(.linear(duration: 0.05), value: controller.progress)
                        .accessibilityLabel("Behandlet lyd: \(controller.progress) prosent")
                } else {
                    ProcessingDots()
                }
            } else {
                LevelBars(level: controller.audioLevel)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, controller.confirmingDiscard ? 24 : 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: controller.confirmingDiscard)
        .animation(.easeInOut(duration: 0.25), value: controller.buttonsVisible)
        .overlay(alignment: .leading) {
            if controller.phase != .failed && !controller.confirmingDiscard && controller.buttonsVisible {
                PanelButton(symbol: "xmark",
                            label: controller.canCancel ? "Avbryt diktasjon" : "Lukk") { controller.dismissPanel() }
                    .help(controller.canCancel ? "Avbryt diktasjon (Esc)" : "Lukk (Esc)")
                    .padding(.leading, 10)
            }
        }
        .overlay(alignment: .trailing) {
            if controller.phase == .recording && !controller.confirmingDiscard && controller.buttonsVisible {
                PanelButton(symbol: "stop.fill", label: "Stopp og sett inn tekst") { controller.toggle() }
                    .help("Stopp og sett inn tekst")
                    .padding(.trailing, 10)
            }
        }
        .foregroundStyle(.white)
        .background {
            if controller.phase == .failed {
                RoundedRectangle(cornerRadius: 18).fill(.black)
            } else {
                Capsule().fill(.black)
                    .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
            }
        }
    }
}

private struct PanelButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(hovering ? 0.2 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(label)
    }
}

private struct ChoiceButton: View {
    let title: String
    let fill: Color
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(fill).brightness(hovering ? 0.12 : 0))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// Shown until the microphone delivers real sound, so it is clear which one is
// used and when it is safe to speak.
private struct MicrophoneBadge: View {
    let device: InputDevice?
    // Before the microphone reports itself, show the one used last time.
    private var symbol: String { device?.symbol ?? AudioDevices.lastSymbol }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .frame(height: 36)
            .accessibilityLabel("Starter \(device?.name ?? "mikrofonen") …")
            .help(device?.name ?? "Mikrofon")
    }
}

private struct LevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<7) { index in
                let distance = abs(index - 3)
                let envelope = 1 - Double(distance) * 0.26
                Capsule()
                    .fill(.white)
                    .frame(width: 4, height: 4 + 28 * envelope * Double(level))
            }
        }
        .frame(height: 36)
        .animation(.easeOut(duration: 0.09), value: level)
        .accessibilityLabel("Lydnivå fra mikrofonen")
    }
}

private struct ProcessingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
            HStack(spacing: 7) {
                ForEach(0..<3) { index in
                    let phase = context.date.timeIntervalSinceReferenceDate * 5 - Double(index) * 0.9
                    Circle()
                        .frame(width: 6, height: 6)
                        .opacity(reduceMotion ? 0.7 : 0.3 + 0.7 * (sin(phase) + 1) / 2)
                }
            }
        }
        .accessibilityLabel("Behandler …")
    }
}
