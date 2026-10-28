import Foundation

/// Candidate retrieval only. Neither lexical nor numeric similarity proves recall;
/// the existing semantic assessment and independent extra-credit confirmation decide it.
nonisolated enum RecallCandidateSearch {
    struct Match {
        let sharedTerms: [String]
        let sharedQuantities: [String]
        var isRelevant: Bool { sharedTerms.count >= 2 || !sharedQuantities.isEmpty }
        var rank: Int { sharedTerms.count * 10 + sharedQuantities.count * 30 }
    }

    private static func word(_ value: String) -> String {
        let units = ["minutes": "minute", "mins": "minute", "min": "minute", "hours": "hour", "hrs": "hour", "hr": "hour",
                     "seconds": "second", "secs": "second", "sec": "second", "milliseconds": "millisecond", "ms": "millisecond",
                     "cycles": "cycle", "theories": "theory", "memories": "memory"]
        if let unit = units[value] { return unit }
        if value.count > 5, value.hasSuffix("ies") { return String(value.dropLast(3)) + "y" }
        // Conservative common plurals; preserve analysis, consciousness, etc.
        if value.count > 4, value.hasSuffix("s"), !value.hasSuffix("ss"), !value.hasSuffix("is"), !value.hasSuffix("ous") {
            return String(value.dropLast())
        }
        return value
    }

    static func terms(_ text: String) -> Set<String> {
        let stop: Set<String> = ["a", "an", "the", "and", "or", "it", "is", "are", "of", "to", "in", "for", "with",
            "that", "this", "they", "can", "does", "what", "how", "sleep", "during", "from", "be", "by", "its", "about"]
        return Set(text.normalizedName.split { !$0.isLetter && !$0.isNumber }.map { word(String($0)) }
            .filter { !stop.contains($0) && ($0.count > 2 || $0.allSatisfy(\.isNumber)) })
    }

    /// Canonical duration units make 1.5 hours, 90 min and 90-minute comparable.
    /// Keep bare numbers out of this stronger cue: an unrelated 90 is not a duration.
    static func quantities(_ text: String) -> Set<String> {
        let pattern = #"(?i)(?<![\p{L}\d.])([0-9]+(?:[.,][0-9]+)?)\s*[-‐‑–—]?\s*(milliseconds?|ms|minutes?|mins?|hours?|hrs?|h|seconds?|secs?|s)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return Set(expression.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard let value = Double(source.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }
            let unit = word(source.substring(with: match.range(at: 2)).lowercased())
            let seconds: Double
            switch unit {
            case "hour", "h": seconds = value * 3600
            case "minute": seconds = value * 60
            case "second", "s": seconds = value
            case "millisecond": seconds = value / 1000
            default: return nil
            }
            guard seconds.isFinite else { return nil }
            return "duration:" + String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        })
    }

    static func match(claim: String, answer: String) -> Match {
        .init(sharedTerms: terms(claim).intersection(terms(answer)).sorted(),
              sharedQuantities: quantities(claim).intersection(quantities(answer)).sorted())
    }

    static func mentionsSubject(_ alternatives: [String], in text: String) -> Bool {
        func phrase(_ value: String) -> String {
            value.normalizedName.split { !$0.isLetter && !$0.isNumber }.map { word(String($0)) }.joined(separator: " ")
        }
        let context = " " + phrase(text) + " "
        return alternatives.contains { subject in
            let normalized = phrase(subject)
            return !normalized.isEmpty && context.contains(" " + normalized + " ")
        }
    }
}
