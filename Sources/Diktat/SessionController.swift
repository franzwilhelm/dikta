import AppKit
import Combine
import UniformTypeIdentifiers
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation", initial: .init(.space, modifiers: [.control, .option]))
    static let cancelDictation = Self("cancelDictation", initial: .init(.escape, modifiers: [.control, .option]))
}

@MainActor
final class SessionController: ObservableObject {
    enum Phase { case idle, preparing, recording, finishing, delivering, cancelling, failed }
    @Published private(set) var phase: Phase = .idle {
        didSet {
            if phase == .recording, oldValue != .recording { recordingStartedAt = Date() }
            if phase != .recording, confirmingDiscard {
                confirmingDiscard = false
                panel.refresh()
            }
        }
    }
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var progress = 0
    @Published private(set) var showProgress = false
    // Discarding more than a few seconds of speech by accident is costly; ask first.
    @Published private(set) var confirmingDiscard = false
    private var recordingStartedAt: Date?
    // The microphone in use. Its icon shows briefly, and until real
    // sound arrives, before the panel switches to the sound bars.
    @Published private(set) var inputDevice: InputDevice?
    @Published private(set) var showBars = false
    private var hearing = false
    private var badgeUntil = Date.distantPast
    private var barsTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    @Published private(set) var text = ""
    @Published private(set) var lastText = ""
    @Published private(set) var message = "Klar til diktasjon"
    @Published var locale: String = UserDefaults.standard.string(forKey: "locale") ?? "nb-NO" {
        didSet { UserDefaults.standard.set(locale, forKey: "locale") }
    }
    @Published var automaticallyPaste = UserDefaults.standard.object(forKey: "automaticallyPaste") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticallyPaste, forKey: "automaticallyPaste")
            if automaticallyPaste { requestAutomaticPasteAccess() }
        }
    }
    @Published private(set) var accessibilityGranted = TextDelivery.hasAccessibility
    private var checkedStartupAccess = false

    func checkStartupAccess() {
        guard !checkedStartupAccess else { return }
        checkedStartupAccess = true
        if automaticallyPaste { requestAutomaticPasteAccess() }
    }

    func refreshAccessibility() {
        accessibilityGranted = TextDelivery.hasAccessibility
    }

    func requestAutomaticPasteAccess() {
        accessibilityGranted = TextDelivery.requestAccessibility()
    }
    @Published var useNBWhisper = UserDefaults.standard.object(forKey: "useNBWhisper") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(useNBWhisper, forKey: "useNBWhisper")
            if useNBWhisper && !isBusy { Task { await NBWhisper.shared.warmUp() } }
        }
    }
    private var session: SpeechSession?
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private let delivery = TextDelivery()
    lazy var panel = RecordingPanel(controller: self)

    // Recording from the microphone, including the moment it starts up.
    var isListening: Bool { !preparingFile && [.preparing, .recording].contains(phase) }
    private var preparingFile = false
    // X and stop appear together with the sound bars, not over the microphone icon.
    var buttonsVisible: Bool { !isListening || showBars }

    var isBusy: Bool { ![.idle, .failed].contains(phase) }
    var canCancel: Bool { [.preparing, .recording, .finishing].contains(phase) }
    var canToggle: Bool { [.idle, .failed, .recording].contains(phase) }

    init() {
        if useNBWhisper { Task { await NBWhisper.shared.warmUp() } }
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in self?.toggle() }
        KeyboardShortcuts.onKeyUp(for: .cancelDictation) { [weak self] in self?.dismissPanel() }
    }

    func toggle() {
        if phase == .recording { stop() }
        else if !isBusy { start(source: .microphone) }
    }

    // Lets a recording made elsewhere (e.g. a phone voice memo) be transcribed.
    // The result is copied only; the frontmost app after the open panel is not a paste target.
    func transcribeFile() {
        guard !isBusy else { return }
        let dialog = NSOpenPanel()
        dialog.title = "Velg lydfil"
        dialog.prompt = "Transkriber"
        dialog.message = "Velg et lydopptak som skal transkriberes lokalt."
        dialog.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie, .quickTimeMovie]
        dialog.allowsMultipleSelection = false
        dialog.canChooseDirectories = false
        NSApp.activate()
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        start(source: .file(url))
    }

    private func start(source: AudioSource) {
        text = ""
        audioLevel = 0
        progress = 0
        showProgress = false
        preparingFile = source.isFile
        phase = .preparing
        message = source.isFile ? "Klargjør transkripsjon …" : "Klargjør diktasjon …"
        panel.show()
        let session = SpeechSession(useNBWhisper: useNBWhisper)
        self.session = session
        session.onLevel = { [weak self, weak session] level in
            guard let self, self.session === session, self.phase == .recording else { return }
            self.audioLevel = level
        }
        inputDevice = nil
        // The same quick microphone as last time needs no introduction: go straight to the bars.
        if AudioDevices.lastQuickUID != nil {
            barsTask?.cancel()
            hearing = true
            showBars = true
        } else {
            showBadge()
        }
        session.onInput = { [weak self, weak session] device, hearing in
            guard let self, self.session === session else { return }
            self.inputDevice = device
            let familiar = device.map { !$0.isBluetooth && $0.uid == AudioDevices.lastQuickUID } ?? false
            if let device {
                AudioDevices.lastSymbol = device.symbol
                AudioDevices.lastQuickUID = device.isBluetooth ? nil : device.uid
            }
            if hearing {
                self.hearing = true
                self.updateBars()
            } else if !(familiar && self.showBars) {
                self.showBadge()
            }
        }
        session.onText = { [weak self, weak session] text in
            guard let self, self.session === session else { return }
            self.text = text
        }
        session.onFailure = { [weak self, weak session] error in
            guard let self, self.session === session else { return }
            self.fail(error)
        }
        session.onStatus = { [weak self, weak session] status in
            guard let self, self.session === session, [.recording, .finishing].contains(self.phase) else { return }
            self.message = status
        }
        let selectedLocale = locale
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await session.start(source: source, locale: selectedLocale) { [weak self] status in
                    guard let self, self.session === session, self.phase == .preparing else { return }
                    self.message = status
                }
                guard self.session === session, self.phase == .preparing else { return }
                if source.isFile {
                    self.phase = .recording
                    self.stop(automaticallyPaste: false, showFileProgress: true)
                    return
                }
                self.phase = .recording
                let language = selectedLocale == "nb-NO" ? "Norsk bokmål" : "English"
                self.message = "Lytter · \(language)"
                if self.useNBWhisper { self.message += " · Whisper · 30 s" }
            } catch {
                guard self.session === session, self.phase == .preparing else { return }
                self.fail(error)
            }
        }
    }

    private func showBadge() {
        hearing = false
        showBars = false
        badgeUntil = Date().addingTimeInterval(0.8)
        barsTask?.cancel()
        barsTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            self?.updateBars()
        }
    }

    private func updateBars() {
        guard hearing, Date() >= badgeUntil else { return }
        showBars = true
    }

    private func stop(automaticallyPaste shouldPaste: Bool? = nil, showFileProgress: Bool = false) {
        guard let session else { return }
        phase = .finishing
        progress = 0
        showProgress = false
        if showFileProgress {
            let clock = ContinuousClock()
            let began = clock.now
            progressTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard let self, self.phase == .finishing else { return }
                    if clock.now - began >= .seconds(2) { self.showProgress = true }
                    // Poll actual completed audio; never advance just because time passed.
                    let actual = Int(session.processingProgress * 100)
                    self.progress = min(99, max(self.progress, actual))
                }
            }
        }
        message = "Ferdigstiller …"
        delivery.captureTarget()
        let shouldPaste = shouldPaste ?? automaticallyPaste
        let timeoutSeconds = session.finalizationTimeout
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
            guard let self, self.session === session, self.phase == .finishing else { return }
            self.fail(DiktatError(message: "Ferdigstillingen tok for lang tid. Tilgjengelig tekst er bevart."))
        }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let finalText = try await session.finish()
                guard self.session === session, self.phase == .finishing else { return }
                self.timeout?.cancel()
                self.progressTask?.cancel()
                self.progress = 100
                self.text = finalText
                if finalText.isEmpty {
                    self.message = "Ingen tale oppfattet."
                    self.delivery.reset()
                } else {
                    self.lastText = finalText
                    // Delivery is committed now. Cancellation is disabled before
                    // writing the clipboard, so an accepted cancel never copies.
                    self.phase = .delivering
                    self.message = await self.delivery.deliver(finalText, automaticallyPaste: shouldPaste)
                }
                await session.cancel()
                self.session = nil
                self.phase = .idle
                self.panel.hide()
            } catch {
                guard self.session === session, self.phase == .finishing else { return }
                self.fail(error)
            }
        }
    }

    func dismissPanel() {
        if confirmingDiscard { cancel(); return }
        if phase == .recording, let recordingStartedAt, Date().timeIntervalSince(recordingStartedAt) > 10 {
            confirmingDiscard = true
            panel.refresh()
            return
        }
        if canCancel { cancel() }
        panel.hide()
    }

    func keepRecording() {
        confirmingDiscard = false
        panel.refresh()
    }

    func cancel() {
        guard canCancel, let session else { return }
        phase = .cancelling
        operation?.cancel()
        timeout?.cancel()
        progressTask?.cancel()
        delivery.reset()
        message = "Avbryter …"
        operation = Task { [weak self] in
            await session.cancel()
            guard let self, self.session === session else { return }
            self.session = nil
            self.text = ""
            self.phase = .idle
            self.message = "Diktasjonen er forkastet."
            self.panel.hide()
        }
    }

    private func fail(_ error: Error) {
        guard phase == .preparing || phase == .recording || phase == .finishing else { return }
        phase = .cancelling
        operation?.cancel()
        timeout?.cancel()
        progressTask?.cancel()
        delivery.reset()
        message = error.localizedDescription
        let session = session
        operation = Task { [weak self] in
            await session?.cancel()
            guard let self else { return }
            self.session = nil
            self.phase = .failed
            self.panel.show()
        }
    }

    func copyLast() {
        if TextDelivery.copy(lastText) { message = "Siste ferdige tekst er kopiert." }
    }

    func copyRecovery() {
        if TextDelivery.copy(text) { message = "Tilgjengelig tekst er kopiert." }
    }

    func quit() {
        guard let session else { NSApp.terminate(nil); return }
        operation?.cancel()
        timeout?.cancel()
        progressTask?.cancel()
        Task {
            await session.cancel()
            NSApp.terminate(nil)
        }
    }
}
