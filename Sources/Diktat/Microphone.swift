import AVFoundation
import AudioToolbox
import Foundation

// Bluetooth microphones deliver pure digital silence while the headset switches
// mode. Real microphones always carry some noise, so any signal means it is live.
private final class SoundGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false

    func opens(on buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !open, let channel = buffer.floatChannelData?[0] else { return false }
        for index in 0..<Int(buffer.frameLength) where abs(channel[index]) > 1e-6 {
            open = true
            return true
        }
        return false
    }
}

// One engine and the serial queue that is the only place it is touched.
// Core Audio can block indefinitely while a Bluetooth headset changes mode; on
// this queue that stalls only the engine, never the app, and a device change
// simply gets a new link.
private final class EngineLink: @unchecked Sendable {
    let queue = DispatchQueue(label: "no.franzvonderlippe.Diktat.microphone")
    let engine = AVAudioEngine()
    // Touched only on the queue.
    var observer: NSObjectProtocol?

    // Runs work on the queue, or gives up after the limit so the caller can recover.
    func run<T: Sendable>(within seconds: Double, _ work: @escaping @Sendable (AVAudioEngine) throws -> T) async throws -> T {
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [engine] in
                let result = Result { try work(engine) }
                if once.claim() { continuation.resume(with: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.claim() {
                    continuation.resume(throwing: DiktatError(message: "Mikrofonen svarer ikke. Prøv igjen, eller velg en annen mikrofon i Innstillinger."))
                }
            }
        }
    }

    // Freeing an engine right after stop races AVAudioIOUnit's own property
    // listener queue, which then messages the freed engine and crashes the app.
    // Keep the stopped engine until those callbacks have run.
    func teardown() {
        queue.async { [self] in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            queue.asyncAfter(deadline: .now() + 10) { withExtendedLifetime(self) {} }
        }
    }
}

// The tap runs on the audio thread by design; AVFAudio just does not mark it Sendable.
private struct TapBox: @unchecked Sendable { let block: AVAudioNodeTapBlock }

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// Owns the input for one recording. Changing the input device leaves an engine
// with stale formats, and tapping it can raise an uncatchable exception. A device
// change therefore builds a fresh engine and taps it in its own format.
@MainActor
final class Microphone {
    private var link: EngineLink?
    private var tap: AVAudioNodeTapBlock?
    private var onFailure: ((Error) -> Void)?
    private var restart: Task<Void, Never>?
    private var changes = 0
    // Which microphone is in use, and whether real sound has arrived from it yet.
    var onInput: ((InputDevice?, Bool) -> Void)?
    private var device: InputDevice?
    private var shownDevice: String?

    // Opens a fresh engine on the chosen microphone and returns its format.
    func open() async throws -> AVAudioFormat {
        try await retrying { builtIn in try await openEngine(builtIn: builtIn) }
    }

    // A Bluetooth headset can need a few seconds to switch mode. Try again, and
    // on the last attempt use the Mac's own microphone rather than give up.
    private func retrying<T>(_ work: (_ builtIn: Bool) async throws -> T) async throws -> T {
        let attempts = 3
        for attempt in 1..<attempts {
            do { return try await work(false) } catch {}
            try await Task.sleep(for: .milliseconds(500 * attempt))
        }
        return try await work(true)
    }

    private func openEngine(builtIn: Bool) async throws -> AVAudioFormat {
        link?.teardown()
        let link = EngineLink()
        self.link = link
        let (device, format) = try await link.run(within: 4) { engine -> (InputDevice?, AVAudioFormat?) in
            let inputs = AudioDevices.inputs
            var device = builtIn ? AudioDevices.builtInMicrophone(in: inputs) : AudioDevices.chosen(from: inputs)
            if var id = device?.id, let unit = engine.inputNode.audioUnit {
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                                  0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
                if status != noErr { device = nil }
            }
            let format = engine.inputNode.inputFormat(forBus: 0)
            let valid = format.sampleRate > 0 && format.channelCount > 0
            return (device ?? AudioDevices.systemDefault, valid ? format : nil)
        }
        guard let format else { throw DiktatError(message: "Ingen tilgjengelig mikrofon.") }
        self.device = device
        return format
    }

    func start(tap: @escaping AVAudioNodeTapBlock, onFailure: @escaping (Error) -> Void) async throws {
        self.tap = tap
        self.onFailure = onFailure
        if let link {
            do { try await run(on: link); return } catch {}
        }
        try await connect()
    }

    private func connect() async throws {
        try await retrying { builtIn in
            guard tap != nil else { return }
            _ = try await openEngine(builtIn: builtIn)
            guard tap != nil, let link else { return }
            try await run(on: link)
        }
    }

    private func run(on link: EngineLink) async throws {
        guard let tap else { throw DiktatError(message: "Ingen tilgjengelig mikrofon.") }
        let gate = SoundGate()
        let device = device
        // Keep the bars when the same microphone comes back; show its icon only for a new one.
        if device?.uid != shownDevice {
            shownDevice = device?.uid
            onInput?(device, false)
        }
        let heard: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.onInput?(device, true) }
        }
        let box = TapBox(block: Self.gated(tap, gate: gate, heard: heard))
        let changed: @Sendable () -> Void = { [weak self, weak link] in
            let source = link
            Task { @MainActor [weak self] in self?.scheduleRestart(for: source) }
        }
        try await link.run(within: 4) { [link] engine in
            let input = engine.inputNode
            // Tapping a device that has no format yet, or one the engine has not
            // caught up with, raises an exception that Swift cannot catch.
            let hardware = input.inputFormat(forBus: 0)
            let tapped = input.outputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0,
                  tapped.sampleRate == hardware.sampleRate, tapped.channelCount > 0 else {
                throw DiktatError(message: "Mikrofonen er ikke klar.")
            }
            // nil lets the engine tap in the device's current format; AudioFeed converts per buffer.
            input.installTap(onBus: 0, bufferSize: 2048, format: nil, block: box.block)
            let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                  object: engine, queue: nil) { _ in changed() }
            engine.prepare()
            do { try engine.start() } catch {
                NotificationCenter.default.removeObserver(observer)
                input.removeTap(onBus: 0)
                throw error
            }
            link.observer = observer
        }
    }

    // Built outside MainActor: the audio thread calls it, and an inherited
    // MainActor isolation would trap there (see AudioFeed.makeTap).
    private nonisolated static func gated(_ tap: @escaping AVAudioNodeTapBlock, gate: SoundGate,
                                          heard: @escaping @Sendable () -> Void) -> AVAudioNodeTapBlock {
        { buffer, time in
            if gate.opens(on: buffer) { heard() }
            tap(buffer, time)
        }
    }

    // Device changes arrive in bursts; rebuild once the route has settled. Only
    // the current engine counts, and a rebuild waits for the one before it, so
    // two rebuilds never tap the same engine.
    private func scheduleRestart(for source: EngineLink?) {
        guard let source, source === link, tap != nil else { return }
        changes += 1
        let change = changes
        let previous = restart
        restart = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await previous?.value
            guard let self, self.changes == change else { return }
            await self.rebuildIfStopped()
        }
    }

    // Selecting a microphone also posts a configuration change. Only a change
    // that actually stopped the engine (a device came or went) needs a rebuild.
    private func rebuildIfStopped() async {
        guard let link, tap != nil else { return }
        let running = (try? await link.run(within: 2) { engine in engine.isRunning }) ?? false
        guard !running, self.link === link else { return }
        await rebuild()
    }

    private func rebuild() async {
        do { try await connect() } catch {
            guard tap != nil else { return }
            link?.teardown()
            link = nil
            tap = nil
            onFailure?(DiktatError(message: "Mikrofonen falt ut og kunne ikke startes igjen."))
        }
    }

    func stop() {
        restart?.cancel()
        restart = nil
        tap = nil
        link?.teardown()
        link = nil
    }
}
