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

    func teardown() {
        queue.async { [self] in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
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
    // Which microphone is in use, and whether real sound has arrived from it yet.
    var onInput: ((InputDevice?, Bool) -> Void)?
    private var device: InputDevice?
    private var shownDevice: String?

    // Opens a fresh engine on the chosen microphone and returns its format.
    func open() async throws -> AVAudioFormat {
        link?.teardown()
        let link = EngineLink()
        self.link = link
        let (device, format) = try await link.run(within: 4) { engine -> (InputDevice?, AVAudioFormat?) in
            var device = AudioDevices.chosen(from: AudioDevices.inputs)
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
        try await run()
    }

    private func run() async throws {
        guard let tap, let link else { throw DiktatError(message: "Ingen tilgjengelig mikrofon.") }
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
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleRestart() }
        }
        try await link.run(within: 4) { [link] engine in
            // nil lets the engine tap in the device's current format; AudioFeed converts per buffer.
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil, block: box.block)
            let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                  object: engine, queue: nil) { _ in changed() }
            engine.prepare()
            do { try engine.start() } catch {
                NotificationCenter.default.removeObserver(observer)
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

    // Device changes arrive in bursts; rebuild once the route has settled.
    private func scheduleRestart() {
        restart?.cancel()
        restart = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await self?.rebuildIfStopped()
        }
    }

    // Selecting a microphone also posts a configuration change. Only a change
    // that actually stopped the engine (a device came or went) needs a rebuild.
    private func rebuildIfStopped() async {
        guard let link else { return }
        let running = (try? await link.run(within: 2) { engine in engine.isRunning }) ?? false
        guard !running, self.link === link else { return }
        await rebuild()
    }

    private func rebuild() async {
        guard tap != nil else { return }
        do {
            _ = try await open()
            guard tap != nil else { link?.teardown(); return }
            try await run()
        } catch {
            guard tap != nil else { return }
            link?.teardown()
            link = nil
            tap = nil
            onFailure?(DiktatError(message: "Mikrofonen ble endret og kunne ikke startes igjen. Ferdig tekst er bevart."))
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
