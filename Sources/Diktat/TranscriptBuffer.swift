import Foundation
import CoreMedia
import Speech

struct TranscriptBuffer {
    private struct Segment {
        let range: CMTimeRange
        let text: String
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
        segments.append(Segment(range: result.range, text: String(result.text.characters), isFinal: result.isFinal))
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
}
