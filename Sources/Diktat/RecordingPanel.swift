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
        let failed = controller?.phase == .failed
        panel.setContentSize(NSSize(width: failed ? 360 : 160, height: failed ? 160 : 64))
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 48))
        }
        panel.orderFrontRegardless()
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
            } else if controller.phase == .finishing || controller.phase == .delivering {
                if controller.showProgress {
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
                HStack(spacing: 4) {
                    ForEach(0..<7) { index in
                        let distance = abs(index - 3)
                        let envelope = 1 - Double(distance) * 0.26
                        Capsule()
                            .fill(.white)
                            .frame(width: 4, height: 4 + 28 * envelope * Double(controller.audioLevel))
                    }
                }
                .frame(height: 36)
                .animation(.easeOut(duration: 0.09), value: controller.audioLevel)
                .accessibilityLabel("Lydnivå fra mikrofonen")
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 36)
        .frame(width: controller.phase == .failed ? 360 : 160,
               height: controller.phase == .failed ? 160 : 64)
        .overlay(alignment: .trailing) {
            Button { controller.dismissPanel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(controller.canCancel ? "Avbryt diktasjon (Esc)" : "Lukk (Esc)")
            .accessibilityLabel(controller.canCancel ? "Avbryt diktasjon" : "Lukk")
            .padding(.trailing, 10)
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
        .accessibilityLabel("Ferdigstiller diktasjon")
    }
}
