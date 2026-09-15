import AppKit
import ApplicationServices

@MainActor
final class TextDelivery {
    private var target: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var targetChanged = false

    func captureTarget() {
        reset()
        target = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                if pid != self.target?.processIdentifier { self.targetChanged = true }
            }
        }
    }

    func reset() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        target = nil
        targetChanged = false
    }

    static func copy(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    func deliver(_ text: String, automaticallyPaste: Bool) async -> String {
        defer { reset() }
        guard Self.copy(text) else { return "Kunne ikke kopiere teksten. Prøv «Kopier siste tekst»." }
        guard automaticallyPaste else { return "Teksten er kopiert." }
        guard AXIsProcessTrusted() else {
            return "Kopiert. Gi Diktat tilgang til Tilgjengelighet for automatisk innliming."
        }
        let pasteboardVersion = NSPasteboard.general.changeCount
        // Wait at most two seconds for shortcut modifiers to be released.
        for _ in 0..<100 {
            if Task.isCancelled { return "Teksten er kopiert." }
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            if flags.intersection(modifiers).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        guard !Task.isCancelled,
              CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else {
            return "Kopiert. Hurtigtastens modifikatortaster ble ikke sluppet."
        }
        guard let target, !target.isTerminated, !targetChanged,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            return "Kopiert. Aktiv app ble endret; lim inn med ⌘V."
        }
        guard NSPasteboard.general.changeCount == pasteboardVersion else {
            return "Utklippstavlen ble endret. Bruk «Kopier siste tekst» for å hente diktasjonen."
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return "Kopiert. Kunne ikke sende innliming; bruk ⌘V."
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Address the captured process so a last-moment focus change cannot
        // redirect the keystroke to an unrelated application.
        down.postToPid(target.processIdentifier)
        up.postToPid(target.processIdentifier)
        return "Kopiert og innliming sendt."
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccessibility() -> Bool {
        guard !hasAccessibility else { return true }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        // macOS may suppress a repeated prompt. Always provide a direct path
        // to the switch instead of silently leaving automatic paste unavailable.
        if !granted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return granted
    }
}
