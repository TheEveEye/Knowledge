import Foundation

/// A narrow local safeguard for obvious missing-context questions. Semantic
/// answerability, answer leakage and rubric fairness are checked by the verifier.
nonisolated enum RecallQuestionQuality {
    /// A narrow generation gate, never a learner-answer grading rule.
    static func usesOutlineLabel(_ prompt: String) -> Bool {
        prompt.range(of: #"(?i)\btheor(?:y|ies)\s+(?:[A-D]|[1-9][0-9]?|[IVX]{1,4})(?:\b|[,/])"#,
                     options: .regularExpression) != nil
    }

    static func contextIssue(_ prompt: String) -> String? {
        // A quoted excerpt or an explicit context block can supply a referent.
        guard !prompt.contains(":"), !prompt.contains("\n"),
              !prompt.contains("\""), !prompt.contains("“"), !prompt.contains("«") else { return nil }
        let patterns = [
            #"(?i)^\s*(?:in|according to|based on)\s+(?:this|that|the above|the given)\s+(?:definition|passage|text|diagram|example)\b"#,
            #"(?i)^\s*what\s+(?:does|is)\s+(?:this|that)\s+(?:statistical measure|measure|technique|method|process|definition)\b"#
        ]
        guard patterns.contains(where: { prompt.range(of: $0, options: .regularExpression) != nil }) else { return nil }
        return "This question refers to context the learner cannot see. Name the subject or include the referenced context without revealing the answer."
    }

    /// Follow-ups share the visible conversation's context; a pronoun alone is
    /// not a defect. Reject only explicit repetition demands here.
    static func followUpIssue(_ prompt: String) -> String? {
        let patterns = [
            #"(?i)^\s*(?:(?:were|are) you saying|did you mean|do you mean|are you sure|is that your (?:answer|final answer))\b"#,
            #"(?i)^\s*(?:what else|anything else)\b"#,
            #"(?i)\b(?:what|which)\s+(?:additional|other)\s+(?:details?|qualifiers?|qualifications?|adjectives?|wording)\b"#,
            #"(?i)\b(?:according to|as (?:stated|described|mentioned) in)\s+(?:the|this|that|original)\s+question\b"#,
            #"(?i)\b(?:state|repeat|recite|write|give)\s+(?:(?:the|a|your)\s+)?(?:full|complete|entire)\s+definition\b"#,
            #"(?i)\b(?:put|combine|restate|summari[sz]e)\b.{0,60}\bin(?:to)?\s+(?:one|a single)\s+sentence\b"#
        ]
        guard patterns.contains(where: { prompt.range(of: $0, options: .regularExpression) != nil }) else { return nil }
        return "This follow-up asks for repetition rather than missing knowledge. Assess the learner's answers in their visible question context; ask only a genuinely unresolved point, or return followUp=null."
    }

    static func contentWords(_ text: String) -> Set<String> {
        let stop: Set<String> = ["a", "an", "the", "and", "or", "it", "is", "are", "of", "to", "in", "for", "with",
            "that", "this", "they", "can", "does", "what", "how", "sleep", "during", "from", "be", "by", "its"]
        return Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 2 && !stop.contains($0) })
    }

    /// Conservative candidate filtering only; it never awards a grade from word overlap.
    static func mentionsSubject(_ alternatives: [String], in text: String) -> Bool {
        func phrase(_ value: String) -> String {
            value.normalizedName.split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        }
        let context = " " + phrase(text) + " "
        return alternatives.contains { name in
            let subject = phrase(name)
            return !subject.isEmpty && context.contains(" " + subject + " ")
        }
    }

    /// A known material distinction must not disappear during paraphrase. This requests
    /// correction/clarification; it never decides whether the learner's claim is correct.
    static func erasesConsciousnessDistinction(answer: String, interpretation: String) -> Bool {
        let claimsUnconscious = answer.range(of: #"(?i)\bunconscious\b"#, options: .regularExpression) != nil
            && answer.range(of: #"(?i)\bnot\s+unconscious\b"#, options: .regularExpression) == nil
        return claimsUnconscious
            && interpretation.range(of: #"(?i)\bunresponsive\b"#, options: .regularExpression) != nil
            && interpretation.range(of: #"(?i)\bunconscious\b"#, options: .regularExpression) == nil
    }

    /// Reject contradictions in the response contract; never infer learner credit from prose.
    static func invalidGap(_ value: String) -> Bool {
        let text = value.trimmed.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if ["null", "nil", "none", "n/a", "na", "not applicable", "nothing", "no gap"].contains(text) { return true }
        return text.range(of: #"(?:should (?:have been|be) (?:marked |graded )?correct|should receive credit|already (?:supplied|provided|demonstrated|identified)|explicitly (?:says|states).{0,130}(?:conveys|meets|captures)|(?:answer|response).{0,100}(?:meets|conveys|captures) (?:the )?required|no (?:substantive |essential )?(?:meaning|knowledge|point) is missing)"#,
            options: .regularExpression) != nil
    }

    static func affirmsCompleteAnswer(_ value: String) -> Bool {
        let text = value.trimmed.lowercased()
        // Praise of one part followed by an actual gap is legitimate partial feedback.
        if text.range(of: #"\b(?:but|however|although|except|missing|remaining|still needs|not yet)\b"#, options: .regularExpression) != nil { return false }
        // A bare "Yes" or "you correctly identified X" can acknowledge only one
        // component. Only an explicit whole-answer verdict justifies a correction call.
        return text.range(of: #"^(?:correct\b|that[’']s right\b|your (?:whole |entire )?answer is (?:fully |completely )?correct\b)|\b(?:the (?:whole|entire) answer is correct|all (?:requested |required )?(?:parts|criteria) (?:are|were) (?:correct|met)|should have been marked correct|should receive credit)\b"#,
            options: .regularExpression) != nil
    }

    static func gapIsGiven(_ gap: String, prompt: String) -> Bool {
        let meta: Set<String> = ["answer", "learner", "needs", "need", "identify", "identifies", "identifying", "state", "states",
            "stated", "stating", "whether", "does", "not", "says", "saying", "must", "explicit", "explicitly", "comparison",
            "mention", "mentioned", "that", "difficulty", "requires", "required", "reference", "refer", "include"]
        let words = contentWords(gap).subtracting(meta)
        return !words.isEmpty && words.isSubset(of: contentWords(prompt))
    }

    static func revealsGap(_ probe: String, gap: String, originalPrompt: String, learnerAnswers: String) -> Bool {
        let meta: Set<String> = ["answer", "learner", "identify", "identifies", "needs", "state", "states", "mention", "missing", "does", "not"]
        let newWords = contentWords(gap).subtracting(contentWords(originalPrompt)).subtracting(contentWords(learnerAnswers)).subtracting(meta)
        return !newWords.intersection(contentWords(probe)).isEmpty
    }

    /// Probe safety only: this never awards knowledge from matching words.
    static func suppliesWholeGap(_ probe: String, gap: String, originalPrompt: String, learnerAnswers: String) -> Bool {
        let meta: Set<String> = ["answer", "learner", "identify", "identified", "specify", "described",
            "needs", "state", "states", "mention", "missing", "explicitly", "rather", "saying", "describing"]
        let novel = contentWords(gap).subtracting(contentWords(originalPrompt))
            .subtracting(contentWords(learnerAnswers)).subtracting(meta)
        return !novel.isEmpty && novel.count <= 3 && novel.isSubset(of: contentWords(probe))
    }

    /// Used only to suppress duplicate observations, never to award semantic credit or merge history.
    static func sameProposition(_ lhs: String, _ rhs: String) -> Bool {
        let filler: Set<String> = ["one", "theory", "proposes", "proposed", "under", "according", "notes", "saved", "supplied", "claim"]
        let a = contentWords(lhs).subtracting(filler), b = contentWords(rhs).subtracting(filler)
        func quantities(_ text: String) -> [String] { text.split { !$0.isNumber }.map(String.init).filter { !$0.isEmpty } }
        let negations: Set<String> = ["no", "not", "never", "without", "always"]
        func polarity(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter }.map(String.init)).intersection(negations)
        }
        guard quantities(lhs) == quantities(rhs), polarity(lhs) == polarity(rhs), min(a.count, b.count) >= 5 else { return false }
        return Double(a.intersection(b).count) / Double(a.union(b).count) >= 0.85
    }

    static func hasNumericRange(_ text: String) -> Bool {
        text.range(of: #"\b\d+(?:[.,]\d+)?\s*(?:–|—|-|to)\s*\d"#, options: .regularExpression) != nil
    }

    static func offersAlternatives(_ prompt: String) -> Bool {
        prompt.range(of: #"(?i)\b(?:or|either|true or false|yes or no)\b"#, options: .regularExpression) != nil
    }

    /// Precision notes are learner-facing content, never instructions to the grader.
    static func isAssessmentInstruction(_ note: String) -> Bool {
        note.range(of: #"(?i)\b(?:do not|don't|never|must not)\s+(?:require|grade|score|assess|penalize|accept|ask)|\b(?:grader|rubric|criterion|criteria)\b"#,
            options: .regularExpression) != nil
    }

    /// Conservative lexical check for probes reciting an entire expected meaning.
    /// This only suppresses an optional question; it never awards or removes credit.
    static func containsAnswer(_ prompt: String, expected: String) -> Bool {
        let stop: Set<String> = ["a", "an", "the", "of", "and", "or", "is", "are", "it", "that", "this", "to", "with",
            "in", "on", "as", "for", "be", "being", "means", "involves", "during", "while", "what", "which", "does", "do", "recall", "recognizes", "identifies", "state", "states", "define", "defines",
            "definition", "characterizes", "has", "can"]
        func words(_ text: String) -> Set<String> {
            let equivalents = ["problems": "difficulty", "problem": "difficulty", "difficulties": "difficulty"]
            return Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map { equivalents[String($0)] ?? String($0) }.filter { !stop.contains($0) })
        }
        let answer = words(expected), question = words(prompt)
        return answer.count >= 3 && answer.isSubset(of: question)
    }

    /// Remove source-location filler from new presentations, never scientific/theory qualifications.
    static func displayPrompt(_ prompt: String) -> String {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"(?i)^according to (?:the )?(?:(?:saved|supplied) )?(?:notes?|claim),\s*"#,
            with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i),?\s+according to (?:the )?(?:(?:saved|supplied) )?notes?\?$"#,
            with: "?", options: .regularExpression)
        guard let first = text.first else { return prompt }
        return String(first).uppercased() + text.dropFirst()
    }

    /// Catch trivial rewordings/reordering, rather than comparing punctuation alone.
    /// This checks probes only; it never decides whether learner knowledge is correct.
    static func repeatsProbe(_ lhs: String, _ rhs: String) -> Bool {
        let stop: Set<String> = ["what", "which", "does", "do", "the", "a", "an", "is", "are", "can", "could", "would",
            "please", "according", "to", "saved", "supplied", "note", "notes", "claim", "it", "this", "that", "of", "in",
            "on", "as", "with", "for", "might", "from", "and", "s"]
        func words(_ value: String) -> Set<String> {
            Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !stop.contains($0) })
        }
        if lhs.normalizedName == rhs.normalizedName { return true }
        let a = words(lhs), b = words(rhs)
        guard min(a.count, b.count) >= 3 else { return false }
        return Double(a.intersection(b).count) / Double(a.union(b).count) >= 0.85
    }

}
