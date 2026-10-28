import AVFoundation
import Foundation

// Writes microphone audio to disk as it arrives. Uncompressed CAF stays
// readable even when the app dies before the file is closed.
final class AudioArchive: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var file: AVAudioFile?
    private var closed = false
    private var frames: AVAudioFramePosition = 0
    private var sampleRate = 0.0

    init(url: URL) { self.url = url }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        do {
            if file == nil {
                let format = buffer.format
                file = try AVAudioFile(forWriting: url, settings: Self.pcm(format), commonFormat: format.commonFormat,
                                       interleaved: format.isInterleaved)
                sampleRate = format.sampleRate
            }
            try file?.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // A full disk must not stop the dictation itself.
            closed = true
        }
    }

    // Returns the recorded length in seconds.
    func close() -> Double {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        file?.close()
        file = nil
        return sampleRate > 0 ? Double(frames) / sampleRate : 0
    }

    private static func pcm(_ format: AVAudioFormat) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
         AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
         AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    }

    // Speech in AAC takes about 20 MB an hour, a sixth of the CAF. The CAF is
    // kept until the compressed file is complete. Returns the length in seconds.
    static func compress(_ source: URL, to target: URL) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let partial = target.deletingLastPathComponent().appendingPathComponent("komprimerer-" + target.lastPathComponent)
        try? FileManager.default.removeItem(at: partial)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 32_000]
        let output = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: format.commonFormat,
                                     interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw DiktatError(message: "Kunne ikke opprette lydbuffer.")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        output.close()
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
        return Double(input.length) / format.sampleRate
    }
}
