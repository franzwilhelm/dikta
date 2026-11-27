import AVFoundation
import Accelerate
import Foundation
import Speech

struct DiktatError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AVAudioPCMBuffer {
    // Real microphones always carry some noise. A channel of pure digital silence
    // is padding, or a device that is not delivering yet.
    func carriesSound(onChannel channel: Int) -> Bool {
        guard frameLength > 0, let samples = floatChannelData?[channel] else { return false }
        var peak: Float = 0
        vDSP_maxmgv(samples, stride, &peak, vDSP_Length(frameLength))
        return peak > 1e-6
    }
}

// AVAudioConverter's callback is Sendable; this object owns the buffer only
// for the synchronous conversion and guards one-shot delivery explicitly.
private final class ConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}

// AVAudioEngine invokes the tap serially. The lock also synchronizes shutdown
// with an in-flight callback, so the final audio is yielded before stream finish.
final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter
    private let format: AVAudioFormat
    private let consume: @Sendable (AVAudioPCMBuffer) throws -> Void
    private let end: @Sendable (Error?) -> Void
    private var ended = false
    private var outputFrames: Int64 = 0
    private var meterSeconds = 0.0
    private let level: @Sendable (Float) -> Void

    var recordedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return format.sampleRate > 0 ? Double(outputFrames) / format.sampleRate : 0
    }

    init(input: AVAudioFormat, output: AVAudioFormat,
         level: @escaping @Sendable (Float) -> Void = { _ in },
         consume: @escaping @Sendable (AVAudioPCMBuffer) throws -> Void,
         end: @escaping @Sendable (Error?) -> Void) throws {
        guard let converter = Self.converter(at: input.sampleRate, to: output) else {
            throw DiktatError(message: "Mikrofonens lydformat kan ikke konverteres.")
        }
        self.level = level
        self.converter = converter
        self.format = output
        self.consume = consume
        self.end = end
    }

    // AVAudioConverter does not mix channels down. Stereo loses its right channel,
    // and channels without a speaker layout (a microphone array, or an engine still
    // on another device's format) come out silent. The feed mixes to one channel
    // itself, so the converter only changes sample rate and sample type.
    private static func converter(at sampleRate: Double, to output: AVAudioFormat) -> AVAudioConverter? {
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                       channels: 1, interleaved: false) else { return nil }
        return AVAudioConverter(from: mono, to: output)
    }

    // The average of the channels that carry sound, in the converter's input
    // format. Silent channels are left out so they do not turn the others down.
    private func mixed(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.format == converter.inputFormat { return input }
        guard input.format.commonFormat == .pcmFormatFloat32, !input.format.isInterleaved,
              let channels = input.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: input.frameLength),
              let mix = mono.floatChannelData?[0] else { return nil }
        let frames = vDSP_Length(input.frameLength)
        mono.frameLength = input.frameLength
        vDSP_vclr(mix, 1, frames)
        var sounding: Float = 0
        for channel in 0..<Int(input.format.channelCount) where input.carriesSound(onChannel: channel) {
            vDSP_vadd(mix, 1, channels[channel], 1, mix, 1, frames)
            sounding += 1
        }
        if sounding > 1 { vDSP_vsdiv(mix, 1, &sounding, mix, 1, frames) }
        return mono
    }

    // Construct this callback outside MainActor. AVAudioNodeTapBlock does not
    // express its background execution in its type; creating it in start()
    // inherits MainActor and traps as soon as the audio thread calls it.
    func makeTap() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in receive(buffer) }
    }

    func receive(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !ended, input.frameLength > 0 else { return }
        // The input device can change mid-session (e.g. a headset connects); follow its rate.
        if input.format.sampleRate != converter.inputFormat.sampleRate {
            guard let replacement = Self.converter(at: input.format.sampleRate, to: format) else {
                fail(DiktatError(message: "Mikrofonens lydformat kan ikke konverteres."))
                return
            }
            converter = replacement
        }
        guard let input = mixed(input), let samples = input.floatChannelData?[0] else {
            fail(DiktatError(message: "Mikrofonens lydformat kan ikke konverteres."))
            return
        }
        meterSeconds += Double(input.frameLength) / input.format.sampleRate
        if meterSeconds >= 0.05 {
            meterSeconds = 0
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(input.frameLength))
            level(min(1, max(0, (20 * log10(max(rms, 0.00001)) + 60) / 60)))
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            fail(DiktatError(message: "Kunne ikke opprette lydbuffer."))
            return
        }
        let source = ConverterInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            source.take(status: state)
        }
        if status == .error {
            fail(error ?? DiktatError(message: "Lydkonverteringen feilet.") as NSError)
            return
        }
        if output.frameLength > 0 {
            outputFrames += Int64(output.frameLength)
            do { try consume(output) }
            catch { fail(error) }
        }
    }

    private func fail(_ error: Error) {
        ended = true
        end(error)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        // Drain any samples retained by the sample-rate converter.
        var error: NSError?
        if let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) {
            let status = converter.convert(to: output, error: &error) { _, state in
                state.pointee = .endOfStream
                return nil
            }
            if status == .error {
                fail(error ?? DiktatError(message: "Kunne ikke avslutte lydstrømmen.") as NSError)
                return
            }
            if output.frameLength > 0 {
                outputFrames += Int64(output.frameLength)
                do { try consume(output) }
                catch { fail(error); return }
            }
        }
        ended = true
        end(nil)
    }
}
