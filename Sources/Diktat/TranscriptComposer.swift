import Foundation

struct TimedPiece: Sendable, Hashable {
    let text: String
    let start: Double
    let end: Double
}

struct SessionScreenshot: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let filename: String
    let timestamp: Double
}

enum TranscriptBlock: Equatable, Sendable {
    case text(String)
    case screenshot(number: Int, screenshot: SessionScreenshot)
}

enum DisplayBlock: Identifiable, Equatable {
    case text(id: String, content: String)
    case screenshot(id: String, number: Int, url: URL, marker: String)

    var id: String {
        switch self {
        case .text(let id, _): return id
        case .screenshot(let id, _, _, _): return id
        }
    }
}

enum TranscriptComposer {
    static func marker(number: Int, url: URL) -> String {
        "[Skjermbilde \(number): \(url.path)]"
    }

    static func join(_ pieces: [TimedPiece]) -> String {
        var value = ""
        for piece in pieces {
            let next = piece.text
            if let last = value.last, let first = next.first,
               !last.isWhitespace, !first.isWhitespace,
               !".,!?;:)]}".contains(first) {
                value += " "
            }
            value += next
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Interleaves screenshots at their audio timestamps among timed speech pieces.
    // If a screenshot lands just before a word that ends a sentence (within 0.5 s),
    // that final word stays before the screenshot so the sentence is not split mid-tail.
    static func blocks(pieces: [TimedPiece], screenshots: [SessionScreenshot]) -> [TranscriptBlock] {
        guard !screenshots.isEmpty else {
            let text = join(pieces)
            return text.isEmpty ? [] : [.text(text)]
        }

        let ordered = screenshots.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp < rhs.element.timestamp
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var result: [TranscriptBlock] = []
        var cursor = 0

        for (index, shot) in ordered.enumerated() {
            let cutoff = shot.timestamp
            var before: [TimedPiece] = []
            while cursor < pieces.count {
                let piece = pieces[cursor]
                let midpoint = (piece.start + piece.end) / 2
                if midpoint <= cutoff {
                    before.append(piece)
                    cursor += 1
                    continue
                }
                if endsSentence(piece.text), piece.start <= cutoff + 0.5 {
                    before.append(piece)
                    cursor += 1
                }
                break
            }
            let text = join(before)
            if !text.isEmpty {
                result.append(.text(text))
            }
            result.append(.screenshot(number: index + 1, screenshot: shot))
        }

        if cursor < pieces.count {
            let tail = join(Array(pieces[cursor...]))
            if !tail.isEmpty {
                result.append(.text(tail))
            }
        }

        return result
    }

    static func render(_ blocks: [TranscriptBlock], folder: URL) -> String {
        var output = ""
        var previousWasScreenshot = false

        for block in blocks {
            switch block {
            case .text(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if !output.isEmpty {
                    output += previousWasScreenshot ? "\n\n" : " "
                }
                output += trimmed
                previousWasScreenshot = false

            case .screenshot(let number, let shot):
                let url = folder.appendingPathComponent(shot.filename)
                if !output.isEmpty {
                    output += previousWasScreenshot ? "\n" : "\n\n"
                }
                output += marker(number: number, url: url)
                previousWasScreenshot = true
            }
        }

        return output
    }

    // Splits stored text back into text runs and inline screenshot previews for HistoryView.
    static func parseDisplayBlocks(text: String, screenshots: [SessionScreenshot], folder: URL) -> [DisplayBlock] {
        guard !screenshots.isEmpty else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(id: "t-0", content: trimmed)]
        }

        let ordered = screenshots.enumerated().map { idx, shot -> (number: Int, url: URL, marker: String) in
            let url = folder.appendingPathComponent(shot.filename)
            let number = idx + 1
            return (number, url, marker(number: number, url: url))
        }

        var blocks: [DisplayBlock] = []
        var remainder = text[...]
        var matchedIDs = Set<Int>()
        var blockIndex = 0

        for item in ordered {
            guard let range = remainder.range(of: item.marker) else { continue }
            let before = String(remainder[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty {
                blocks.append(.text(id: "t-\(blockIndex)", content: before))
                blockIndex += 1
            }
            blocks.append(.screenshot(id: "s-\(item.number)", number: item.number, url: item.url, marker: item.marker))
            matchedIDs.insert(item.number)
            blockIndex += 1
            remainder = remainder[range.upperBound...]
        }

        let tail = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            blocks.append(.text(id: "t-\(blockIndex)", content: tail))
        }

        // If a session stopped early or failed before final composition, still show captured images.
        for item in ordered where !matchedIDs.contains(item.number) {
            blocks.append(.screenshot(id: "s-\(item.number)", number: item.number, url: item.url, marker: item.marker))
        }

        return blocks
    }

    private static func endsSentence(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return ".!?".contains(last)
    }
}
