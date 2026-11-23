import AppKit
import KeyboardShortcuts
import SwiftUI

struct WhatsNewFeature: Identifiable {
    let id = UUID()
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
}

struct WhatsNewRelease {
    let id: String
    let subtitle: String
    let features: [WhatsNewFeature]

    static let seenKey = "lastSeenWhatsNewID"

    static let current = WhatsNewRelease(
        id: "0.11.0",
        subtitle: "Ta skjermbilder mens du snakker, rett inn i diktatet.",
        features: [
            WhatsNewFeature(
                symbol: "camera.viewfinder",
                tint: Color(red: 1.0, green: 0.23, blue: 0.19),
                title: "Innebygd skjermbilde med kontekst",
                detail: "Trykk hurtigtasten eller kamera-ikonet på opptakskapselen mens du dikterer. Klikk på et vindu for hele vinduet, eller dra over et område for rød ramme med kontekst rundt."
            ),
            WhatsNewFeature(
                symbol: "text.insert",
                tint: .blue,
                title: "Plassert der du var i diktatet",
                detail: "Hvert skjermbilde flettes inn midt i teksten på riktig tidspunkt med filsti som AI-agenter kan lese direkte. «Rydd opp teksten» lar bildene stå urørt."
            ),
            WhatsNewFeature(
                symbol: "photo.stack",
                tint: .indigo,
                title: "Lagret i «Tidligere økter»",
                detail: "Skjermbildene vises inline i historikken med forhåndsvisning og egen kopier-knapp, og følger med hvis du transkriberer lydopptaket på nytt."
            )
        ]
    )

    static var shouldPresentOnUpgrade: Bool {
        // Fresh installs open Settings instead; show What's New only to upgrading users.
        guard UserDefaults.standard.bool(forKey: "hasOpenedSettings") else {
            markSeen()
            return false
        }
        return UserDefaults.standard.string(forKey: seenKey) != current.id
    }

    static func markSeen() {
        UserDefaults.standard.set(current.id, forKey: seenKey)
    }
}

struct WhatsNewView: View {
    @ObservedObject var controller: SessionController
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nytt i Dikta")
                        .font(.title2.weight(.semibold))
                    Text(WhatsNewRelease.current.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(WhatsNewRelease.current.features) { feature in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: feature.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(feature.tint)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 9).fill(feature.tint.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.headline)
                            Text(feature.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            permissionCard

            Spacer(minLength: 0)

            HStack {
                Button("Innstillinger …", action: onOpenSettings)
                Spacer()
                Button("Ferdig", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 495)
        .task {
            while !Task.isCancelled {
                controller.refreshAccessibility()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.screenCaptureGranted {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Skjermbilder er klare")
                            .font(.callout.weight(.medium))
                        Text("Trykk hurtigtasten under diktasjon.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    KeyboardShortcuts.Recorder(for: .captureScreenshot)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Skjermopptak mangler tilgang")
                            .font(.callout.weight(.medium))
                        Text("Gi Dikta tilgang i Systeminnstillinger for å ta skjermbilder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Gi tilgang …") {
                        controller.requestScreenCaptureAccess()
                    }
                }
                Divider()
                HStack(spacing: 10) {
                    Text("Hurtigtast under diktasjon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    KeyboardShortcuts.Recorder(for: .captureScreenshot)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(controller.screenCaptureGranted ? Color.green.opacity(0.10) : Color.orange.opacity(0.12))
        )
    }
}
