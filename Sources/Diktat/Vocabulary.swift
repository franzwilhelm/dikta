import Foundation

// Words the speech engines should favour, such as English terms used in Norwegian speech.
enum Vocabulary {
    static let key = "vocabulary"
    // Whisper keeps only the last ~220 prompt tokens, so the most important terms come last.
    static let defaultText = """
        Supabase, Postgres, Docker, GitHub, Sentry, Resend, Intercom, AG Grid, Recharts, Expo, Vitest, oxlint, Turborepo, pnpm, Zustand, Zod, Tailwind, Vite, Drizzle, TanStack, tRPC, oRPC, Clerk, WorkOS, Vercel, BigQuery, Airflow, Inngest, dbt, ClickHouse
        Slack, Linear, Notion, Claude Code, Codex, subagent, prompt, MCP
        worktree, rebase, merge, pull request, commit, branch, deploy, staging, prod, endpoint, schema, migration, refactor, query, tenant, snapshot, partition, pipeline, frontend, backend
        COGS, P&L, gold model, Semantic Mapping, Legal Entity, Cost Center, Stock Unit, Movement Fact, Count Anchor, Import Session, Publish Plan, Prebatch, Inventory Graph, Supplier Document, Price Episode, Data Scope, Page Grant, Block, Report Builder, Concept, Entity, Lens, Edda
        """

    static var words: [String] {
        let text = UserDefaults.standard.string(forKey: key) ?? defaultText
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // Whisper conditions on the prompt as if it were preceding speech.
    static var whisperPrompt: String? {
        let words = words
        return words.isEmpty ? nil : words.joined(separator: ", ") + "."
    }

    // Rewrites every spoken occurrence of a listed term to its listed spelling,
    // e.g. "clickhouse" or "Click house" becomes "ClickHouse". Inflected forms
    // joined with a hyphen, like "ClickHouse-tabellen", are kept.
    @MainActor static func format(_ text: String) -> String {
        var result = text
        for (word, pattern) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            for match in pattern.matches(in: result, range: range).reversed() {
                guard let found = Range(match.range, in: result) else { continue }
                var replacement = word
                // Keep sentence-initial capitals for lowercase terms such as "commit".
                if word == word.lowercased(), result[found].first?.isUppercase == true {
                    replacement = word.prefix(1).uppercased() + word.dropFirst()
                }
                result.replaceSubrange(found, with: replacement)
            }
        }
        return result
    }

    @MainActor private static var cache: (words: [String], patterns: [(String, NSRegularExpression)])?

    @MainActor private static var patterns: [(String, NSRegularExpression)] {
        let words = words
        if let cache, cache.words == words { return cache.patterns }
        let patterns = words.sorted { $0.count > $1.count }.compactMap { word -> (String, NSRegularExpression)? in
            // "ClickHouse" may be heard as "Click house", so camel case splits too.
            let spaced = word.replacingOccurrences(of: "(?<=\\p{Ll})(?=\\p{Lu})", with: " ", options: .regularExpression)
            let parts = spaced.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            let body = parts.joined(separator: "[\\s-]*")
            guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(body)(?![\\p{L}\\p{N}])",
                                                       options: [.caseInsensitive]) else { return nil }
            return (word, regex)
        }
        cache = (words, patterns)
        return patterns
    }
}
