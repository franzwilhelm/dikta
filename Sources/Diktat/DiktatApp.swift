import AppKit
import AVFoundation
import SwiftUI
import KeyboardShortcuts

@main
struct DiktatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = SessionController()

    var body: some Scene {
        MenuBarExtra {
            Text(controller.message)
            Button(controller.phase == .recording ? "Stopp diktasjon" : "Start diktasjon") { controller.toggle() }
                .disabled(!controller.canToggle)
            Button("Avbryt diktasjon") { controller.cancel() }.disabled(!controller.canCancel)
            Divider()
            Picker("Språk", selection: $controller.locale) {
                Text("Norsk bokmål").tag("nb-NO")
                Text("English (US)").tag("en-US")
            }.disabled(controller.isBusy)
            Picker("Talemotor", selection: $controller.useNBWhisper) {
                Text("NB-Whisper Medium").tag(true)
                Text("Mac-diktasjon").tag(false)
            }.disabled(controller.isBusy)
            Toggle("Lim inn automatisk", isOn: $controller.automaticallyPaste)
                .disabled(controller.isBusy)
            Button("Kopier siste tekst") { controller.copyLast() }.disabled(controller.lastText.isEmpty)
            if controller.phase == .failed && !controller.text.isEmpty {
                Button("Kopier tilgjengelig tekst etter feil") { controller.copyRecovery() }
            }
            Divider()
            Button("Innstillinger …") { delegate.showSettings(controller: controller) }
            Button("Avslutt Dikta") { controller.quit() }
        } label: {
            Image(systemName: controller.phase == .recording ? "mic.fill" : "mic")
                .accessibilityLabel("Dikta: \(controller.message)")
                .onAppear {
                    if !UserDefaults.standard.bool(forKey: "hasOpenedSettings") {
                        UserDefaults.standard.set(true, forKey: "hasOpenedSettings")
                        delegate.showSettings(controller: controller)
                    }
                    controller.checkStartupAccess()
                }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?

    private var readyToTerminate = false
    private var shuttingDown = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        if !shuttingDown {
            shuttingDown = true
            Task {
                await NBWhisper.shared.shutdown()
                readyToTerminate = true
                sender.terminate(nil)
            }
        }
        return .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func showSettings(controller: SessionController) {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Dikta – innstillinger"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(controller: controller))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var controller: SessionController
    @State private var permissionMessage = ""
    var body: some View {
        Form {
            Section("Diktasjon") {
                Picker("Språk", selection: $controller.locale) {
                    Text("Norsk bokmål").tag("nb-NO")
                    Text("English (US)").tag("en-US")
                }
                Picker("Talemotor", selection: $controller.useNBWhisper) {
                    Text("NB-Whisper Medium").tag(true)
                    Text("Mac-diktasjon").tag(false)
                }
                Text("Whisper behandler 20 sekunder om gangen mens du snakker. Ved stopp ferdigstilles bare køen og den siste resten.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Lim inn automatisk", isOn: $controller.automaticallyPaste)
                Text("Når valget er av, kopieres teksten bare. Teksten beholdes på utklippstavlen i begge modi.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(controller.isBusy)
            Section("Hurtigtaster") {
                KeyboardShortcuts.Recorder("Start / stopp", name: .toggleDictation)
                KeyboardShortcuts.Recorder("Avbryt", name: .cancelDictation)
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
                if !permissionMessage.isEmpty { Text(permissionMessage).font(.caption) }
                Text("Begge motorene behandler tale lokalt. Lyd og tekst holdes i minnet. Siste ferdige tekst kan kopieres frem til appen avsluttes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .task {
            while !Task.isCancelled {
                controller.refreshAccessibility()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
