import Foundation
import CoreMedia
import Speech

struct TranscriptBuffer {
    private struct Segment {
        let range: CMTimeRange
        let text: String
        let pieces: [TimedPiece]
        let isFinal: Bool
    }

    private var segments: [Segment] = []

    mutating func update(_ result: DictationTranscriber.Result) {
        // A revision replaces the previous hypothesis over the same audio range.
        // Keep separate final segments; never append successive partial strings.
        segments.removeAll {
            !$0.isFinal && (
                CMTimeCompare($0.range.start, result.range.start) == 0 ||
                CMTimeRangeGetIntersection($0.range, otherRange: result.range).duration > .zero
            )
        }
        let plain = String(result.text.characters)
        let pieces = Self.extractPieces(from: result)
        segments.append(Segment(range: result.range, text: plain, pieces: pieces, isFinal: result.isFinal))
        segments.sort { CMTimeCompare($0.range.start, $1.range.start) < 0 }
    }

    var text: String {
        var value = ""
        for segment in segments {
            let next = segment.text
            if let last = value.last, let first = next.first,
               !last.isWhitespace, !first.isWhitespace,
               !".,!?;:)]}".contains(first) {
                value += " "
            }
            value += next
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var timedPieces: [TimedPiece] {
        segments.flatMap(\.pieces)
    }

    private static func extractPieces(from result: DictationTranscriber.Result) -> [TimedPiece] {
        let fallbackStart = safeSeconds(result.range.start)
        let fallbackEnd = max(fallbackStart, safeSeconds(result.range.end))
        var pieces: [TimedPiece] = []

        for run in result.text.runs {
            let substring = String(result.text[run.range].characters)
            let tokens = substring.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { continue }
            let runRange = run.audioTimeRange ?? result.range
            let start = safeSeconds(runRange.start, fallback: fallbackStart)
            let end = max(start, safeSeconds(runRange.end, fallback: fallbackEnd))
            pieces.append(contentsOf: distribute(tokens, start: start, end: end))
        }

        if !pieces.isEmpty { return pieces }
        let tokens = String(result.text.characters).split(whereSeparator: \.isWhitespace).map(String.init)
        return distribute(tokens, start: fallbackStart, end: fallbackEnd)
    }

    private static func distribute(_ tokens: [String], start: Double, end: Double) -> [TimedPiece] {
        guard !tokens.isEmpty else { return [] }
        if tokens.count == 1 {
            return [TimedPiece(text: tokens[0], start: start, end: end)]
        }
        let duration = max(0, end - start)
        let totalChars = max(1, tokens.reduce(0) { $0 + $1.count })
        var cursor = start
        return tokens.map { token in
            let share = duration * Double(token.count) / Double(totalChars)
            let next = cursor + share
            defer { cursor = next }
            return TimedPiece(text: token, start: cursor, end: next)
        }
    }

    private static func safeSeconds(_ time: CMTime, fallback: Double = 0) -> Double {
        guard time.isNumeric else { return fallback }
        let value = CMTimeGetSeconds(time)
        return value.isFinite ? max(0, value) : fallback
    }
}
