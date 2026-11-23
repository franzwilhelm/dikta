import AppKit
import AVFoundation
import CoreAudio
import SwiftUI
import KeyboardShortcuts
import Sparkle

@main
struct DiktatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller: SessionController
    @ObservedObject private var whisper = NBWhisper.shared

    init() {
        let controller = SessionController()
        _controller = StateObject(wrappedValue: controller)
        AppDelegate.startupController = controller
    }

    private var warmingUp: Bool { controller.useNBWhisper && whisper.isLoading && !controller.isBusy }

    var body: some Scene {
        MenuBarExtra {
            Text(warmingUp ? "Gjør klar …" : controller.message)
            Button(controller.phase == .recording ? "Stopp diktasjon" : "Start diktasjon") { controller.toggle() }
                .disabled(!controller.canToggle)
            if controller.canCaptureScreenshot {
                Button("Ta skjermbilde") { controller.captureScreenshot() }
            }
            Button("Avbryt diktasjon") { controller.cancel() }.disabled(!controller.canCancel)
            Button("Transkriber lydfil …") { controller.transcribeFile() }.disabled(controller.isBusy)
            Divider()
            Picker("Språk", selection: $controller.locale) {
                Text("Norsk bokmål").tag("nb-NO")
                Text("English (US)").tag("en-US")
            }.disabled(controller.isBusy)
            Picker("Talemotor", selection: $controller.useNBWhisper) {
                Text("NB-Whisper").tag(true)
                Text("Mac-diktasjon").tag(false)
            }.disabled(controller.isBusy)
            Toggle("Lim inn automatisk", isOn: $controller.automaticallyPaste)
                .disabled(controller.isBusy)
            Toggle("Rydd opp teksten", isOn: $controller.cleanUpText)
                .disabled(controller.isBusy)
            Button("Kopier siste tekst") { controller.copyLast() }.disabled(controller.lastText.isEmpty)
            Button("Tidligere økter …") { delegate.showHistory(controller: controller) }
            if controller.phase == .failed && !controller.text.isEmpty {
                Button("Kopier tilgjengelig tekst etter feil") { controller.copyRecovery() }
            }
            Divider()
            Button("Innstillinger …") { delegate.showSettings(controller: controller) }
            Button("Hva er nytt …") { delegate.showWhatsNew(controller: controller) }
            Button("Se etter oppdateringer …") { delegate.checkForUpdates() }
                .disabled(!delegate.canCheckForUpdates)
            Button("Avslutt Dikta") { controller.quit() }
        } label: {
            Image(systemName: controller.phase == .recording ? "mic.fill" : "mic")
                .opacity(warmingUp ? 0.45 : 1)
                .symbolEffect(.pulse, isActive: warmingUp)
                .animation(.easeInOut(duration: 0.6), value: warmingUp)
                .accessibilityLabel(warmingUp ? "Dikta gjør klar" : "Dikta: \(controller.message)")
                .onAppear {
                    delegate.registerStartup(controller: controller)
                    controller.checkStartupAccess()
                }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    static weak var startupController: SessionController?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var whatsNewWindow: NSWindow?
    private var didFinishLaunching = false
    private var didRunStartupPresentation = false
    // Sparkle reads SUFeedURL and SUPublicEDKey from Info.plist and checks in the background.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @Published private(set) var canCheckForUpdates = false

    override init() {
        super.init()
        updater.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    private var readyToTerminate = false
    private var shuttingDown = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        if !shuttingDown {
            shuttingDown = true
            Task {
                await NBWhisper.shared.shutdown()
                SessionHistory.shared.flush()
                readyToTerminate = true
                sender.terminate(nil)
            }
        }
        return .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        didFinishLaunching = true
        runStartupPresentationIfReady()
    }

    func registerStartup(controller: SessionController) {
        Self.startupController = controller
        runStartupPresentationIfReady()
    }

    private func runStartupPresentationIfReady() {
        guard didFinishLaunching, !didRunStartupPresentation, let controller = Self.startupController else { return }
        didRunStartupPresentation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak controller] in
            guard let self, let controller else { return }
            if !UserDefaults.standard.bool(forKey: "hasOpenedSettings") {
                UserDefaults.standard.set(true, forKey: "hasOpenedSettings")
                WhatsNewRelease.markSeen()
                self.showSettings(controller: controller)
            } else if WhatsNewRelease.shouldPresentOnUpgrade {
                self.showWhatsNew(controller: controller)
            }
            controller.checkStartupAccess()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === whatsNewWindow {
            WhatsNewRelease.markSeen()
        }
    }

    private func present(_ window: NSWindow, centerOnActiveScreen: Bool = false) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        if centerOnActiveScreen {
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                let origin = NSPoint(
                    x: frame.midX - window.frame.width / 2,
                    y: frame.midY - window.frame.height / 2
                )
                window.setFrameOrigin(origin)
            }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func showSettings(controller: SessionController) {
        let isNew = settingsWindow == nil
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Dikta – innstillinger"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(controller: controller))
            settingsWindow = window
        }
        if let settingsWindow {
            present(settingsWindow, centerOnActiveScreen: isNew)
        }
    }

    func showHistory(controller: SessionController) {
        let isNew = historyWindow == nil
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Dikta – tidligere økter"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 720, height: 440)
            window.contentView = NSHostingView(rootView: HistoryView(history: .shared, controller: controller))
            window.setFrameAutosaveName("DiktaHistory")
            historyWindow = window
        }
        if let historyWindow {
            present(historyWindow, centerOnActiveScreen: isNew && !historyWindow.setFrameUsingName("DiktaHistory"))
        }
    }

    func showWhatsNew(controller: SessionController) {
        if whatsNewWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 495),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Nytt i Dikta"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: WhatsNewView(
                controller: controller,
                onOpenSettings: { [weak self] in
                    WhatsNewRelease.markSeen()
                    self?.whatsNewWindow?.close()
                    self?.showSettings(controller: controller)
                },
                onClose: { [weak self] in
                    WhatsNewRelease.markSeen()
                    self?.whatsNewWindow?.close()
                }
            ))
            whatsNewWindow = window
        }
        if let whatsNewWindow {
            present(whatsNewWindow, centerOnActiveScreen: true)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject private var models = WhisperModels.shared
    @State private var permissionMessage = ""
    @State private var microphones: [InputDevice] = []
    @State private var cleanupProblem: String?
    @AppStorage(AudioDevices.preferenceKey) private var microphoneUID = AudioDevices.builtIn
    @AppStorage(Vocabulary.key) private var vocabulary = Vocabulary.defaultText
    var body: some View {
        Form {
            Section("Diktasjon") {
                Picker("Språk", selection: $controller.locale) {
                    Text("Norsk bokmål").tag("nb-NO")
                    Text("English (US)").tag("en-US")
                }
                Picker("Talemotor", selection: $controller.useNBWhisper) {
                    Text("NB-Whisper").tag(true)
                    Text("Mac-diktasjon").tag(false)
                }
                Text("Whisper behandler 30 sekunder om gangen mens du snakker. Ved stopp ferdigstilles bare køen og den siste resten.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Mikrofon", selection: $microphoneUID) {
                    Text("Mac-mikrofonen").tag(AudioDevices.builtIn)
                    Text("Systemvalg").tag("")
                    ForEach(microphones.filter { $0.transport != kAudioDeviceTransportTypeBuiltIn }) { device in
                        Label(device.name, systemImage: device.symbol).tag(device.uid)
                    }
                    if ![AudioDevices.builtIn, ""].contains(microphoneUID) && !microphones.contains(where: { $0.uid == microphoneUID }) {
                        Text("Frakoblet mikrofon").tag(microphoneUID)
                    }
                }
                Text("Mac-mikrofonen starter raskest. AirPods og andre Bluetooth-mikrofoner bruker et par sekunder på å starte, og kan miste de første ordene.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Lim inn automatisk", isOn: $controller.automaticallyPaste)
                Text("Når valget er av, kopieres teksten bare. Teksten beholdes på utklippstavlen i begge modi.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Rydd opp teksten", isOn: $controller.cleanUpText)
                Text("Fjerner fyllord, stamming og gjentakelser med Apples språkmodell på denne Mac-en. Tar et par sekunder ved stopp. Hvis resultatet ikke ligner det du sa, brukes teksten slik den ble diktert. Originalen lagres alltid i «Tidligere økter».")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.cleanUpText, let cleanupProblem {
                    Text(cleanupProblem).font(.caption).foregroundStyle(.orange)
                    Button("Åpne Apple Intelligence-innstillinger …") { openSettings("com.apple.Siri-Settings.extension") }
                }
            }.disabled(controller.isBusy)
            Section("Egne ord") {
                TextEditor(text: $vocabulary)
                    .font(.body)
                    .frame(height: 120)
                Text("Ord og uttrykk talemotoren skal kjenne igjen, for eksempel engelske faguttrykk. Skill med komma eller linjeskift. Skriv dem slik de skal staves.")
                    .font(.caption).foregroundStyle(.secondary)
                if vocabulary != Vocabulary.defaultText {
                    Button("Tilbakestill til standardlisten") { vocabulary = Vocabulary.defaultText }
                }
            }.disabled(controller.isBusy)
            if controller.useNBWhisper {
                Section("Whisper-modell") {
                    Picker("Modell", selection: $models.selected) {
                        Text("Medium · 1,53 GB").tag(WhisperModel.medium)
                        Text("Large · 3,10 GB").tag(WhisperModel.large)
                    }
                    if models.isDownloading { ProgressView(value: models.progress) }
                    Text(models.status).font(.caption).foregroundStyle(.secondary)
                    if models.isDownloading {
                        Text("Medium brukes mens nedlastingen pågår. Large krever mer minne og behandlingstid.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Avbryt nedlasting") { models.cancelDownload() }
                    } else if !models.selected.isInstalled {
                        if let error = models.error { Text(error).font(.caption).foregroundStyle(.red) }
                        Button("Prøv nedlasting igjen") { models.ensureSelected() }
                    }
                }
            }
            Section("Hurtigtaster") {
                KeyboardShortcuts.Recorder("Start / stopp", name: .toggleDictation)
                KeyboardShortcuts.Recorder("Avbryt", name: .cancelDictation)
                KeyboardShortcuts.Recorder("Ta skjermbilde", name: .captureScreenshot)
                Text("Skjermbilde-hurtigtasten er aktiv mens du dikterer. Marker et område, så legger Dikta til en rød ramme med kontekst rundt og setter bildet inn der du var i diktatet.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(controller.isBusy)
            Section("Tilganger") {
                Button("Gi mikrofontilgang") {
                    Task {
                        let granted = await AVCaptureDevice.requestAccess(for: .audio)
                        permissionMessage = granted ? "Mikrofonen er klar." : "Aktiver Mikrofon for Dikta i Systeminnstillinger."
                        if !granted { openPrivacy("Privacy_Microphone") }
                    }
                }
                Label(
                    controller.accessibilityGranted ? "Automatisk innliming har tilgang" : "Automatisk innliming mangler tilgang",
                    systemImage: controller.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle"
                )
                if !controller.accessibilityGranted {
                    Text("Slå på Dikta i Systeminnstillinger → Personvern og sikkerhet → Tilgjengelighet. Bruk + og velg Dikta i Programmer-mappen din hvis appen mangler i listen.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Åpne Tilgjengelighet …") {
                        controller.requestAutomaticPasteAccess()
                    }
                }
                Label(
                    controller.screenCaptureGranted ? "Skjermbilder har tilgang" : "Skjermbilder mangler tilgang",
                    systemImage: controller.screenCaptureGranted ? "checkmark.circle.fill" : "exclamationmark.triangle"
                )
                if !controller.screenCaptureGranted {
                    Text("Slå på Dikta i Systeminnstillinger → Personvern og sikkerhet → Skjerm- og systemlydopptak for å ta skjermbilder under diktasjon.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Åpne Skjermopptak …") {
                        controller.requestScreenCaptureAccess()
                    }
                }
                if !permissionMessage.isEmpty { Text(permissionMessage).font(.caption) }
                Text("Begge motorene behandler tale lokalt. Hver økt lagres med tekst og lyd på denne Mac-en og finnes under «Tidligere økter» i menyen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
        .task {
            while !Task.isCancelled {
                controller.refreshAccessibility()
                cleanupProblem = TextCleaner.unavailableReason
                // Core Audio can block while a Bluetooth headset switches mode; keep that off the main thread.
                microphones = await Task.detached { AudioDevices.inputs }.value
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
