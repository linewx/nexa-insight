import Foundation

/// The instruction sent for on-demand extraction of a single sentence.
///
/// A deliberate second copy of the backend's extraction prompts. The backend is
/// for transcoding and translation; asking a note to wait on it would make the
/// feature unusable exactly when it is most wanted — mid-listen, offline, on a
/// phone. So the rules live here too.
///
/// Both copies encode the same hard-won constraints, and the reject list is the
/// load-bearing part: the first prompt merely asked for "useful words, phrasal
/// verbs, collocations" and returned greetings ("welcome back") and literal
/// domain nouns ("training data center") on every source. What was missing was
/// any statement of what makes an item worth studying, and any instruction to
/// refuse.
enum ExtractionPrompt {
    /// One sentence, so the batch prompt's "at most 8 items" cap does not apply;
    /// what matters here is refusing to invent something when the line holds
    /// nothing worth studying.
    static let rejectRules = """
        REJECT, however frequent: greetings, sign-offs and show boilerplate \
        ("welcome back", "thanks so much", "link in the description"); anything a \
        B2 learner already knows ("speaking of that", "a lot of"); domain nouns \
        that translate literally and teach no English ("training data center"); \
        and compounds whose meaning is just the sum of their words. \
        Each item must be at most 6 words — the reusable expression itself, not \
        the sentence containing it. Quoting a whole sentence teaches nothing \
        transferable. The one exception is a pattern with {slots}, which may be \
        longer because the frame is what carries over. \
        If this sentence genuinely holds nothing worth studying, return an empty \
        array rather than padding it with something obvious. \
        Every explanation field must be written in Chinese. \
        Do NOT return character offsets — those are computed from the text itself.
        """

    static let nativeTypes = """
        - "reduction": what the words become in fast speech, unrecognisable by ear \
        ("want to" -> "wanna"). Give heard_as (the sound produced) and restored \
        (the full form).
        - "ellipsis": omitted words the learner must restore to parse it \
        ("Been there?"). Give restored.
        - "syntax": a structure that breaks parsing. Give restored as a plain \
        rewrite.
        - "idiom": a figurative meaning not derivable from the words.
        - "reference": a name, place or cultural fact assumed known that a \
        non-native would not recognise.
        """

    static let teachingTypes = """
        - "phrase": a conversational expression to use verbatim ("real talk"). \
        Give when_to_use.
        - "pattern": a reusable frame with slots in braces \
        ("I can't {change X}, but I can {change Y}"). Give when_to_use and state \
        what fills each slot.
        - "collocation": a pairing a Chinese speaker gets wrong by translating. \
        Give common_mistake (the wrong Chinese-English attempt).
        """

    static let fields = """
        For each item return: text, type, chinese, pronunciation (IPA, single \
        words only, no slashes, else null), heard_as, restored, why_hard (one \
        Chinese sentence on why it defeats a listener or reader), when_to_use, \
        common_mistake, formality ("formal"|"neutral"|"spoken"|"technical"), \
        example (verbatim from the sentence), example_chinese. \
        Return JSON with key "expressions".
        """

    /// Asks the model which line the learner meant.
    ///
    /// Spoken questions refer to the transcript loosely — "that what-clause a
    /// moment ago" — because by the time you notice you did not follow a line, it
    /// has already scrolled past. So the nearby lines travel with the audio and the
    /// model picks; `sentence_position` is its answer.
    static let locateFromContext = """
        The learner is listening and asked about something they just heard, so the \
        line they mean is usually NOT the last one — it is one they have already \
        passed. The numbered lines below are the ones around their current \
        position. Decide which single line the question is about and return its \
        number as sentence_position. Extract only from THAT line. If the question \
        is about English in general rather than any of these lines, omit \
        sentence_position.
        """

    /// - Parameters:
    ///   - materialKind: "teaching" selects the say-it-yourself types; anything
    ///     else assumes native-speed material, matching the backend's default.
    ///   - request: what the learner asked for. Placed last and marked as
    ///     overriding, because it is the whole point of extracting on demand —
    ///     a learner who asks about the tense does not want the idiom.
    ///   - spokenQuestion: true when the request arrives as audio rather than
    ///     text, which also means the target line has to be inferred.
    static func instruction(
        materialKind: String,
        request: String?,
        spokenQuestion: Bool = false
    ) -> String {
        var prompt = instruction(materialKind: materialKind, request: request)
        if spokenQuestion {
            prompt += "\n\n" + spokenQuestionRules + "\n\n" + locateFromContext
        }
        return prompt
    }

    /// A spoken question is not always about a word, so the reply is routed rather
    /// than assumed. Asking for one shape only meant every question about meaning,
    /// grammar or argument came back as a failed vocabulary extraction.
    static let spokenQuestionRules = """
        The learner's question arrives as audio. Answer WHAT THEY ACTUALLY ASKED — \
        it may be about a word, or about grammar, or about what the passage means, \
        or anything else.

        Decide which it is and return one of two shapes.

        If they are asking about a word or phrase to learn, return: \
        {"intent":"vocabulary","question":"<their question in Chinese>", \
        "expressions":[ … as specified above … ]}

        For anything else — meaning, grammar, argument, background, why a choice was \
        made — return: {"intent":"comprehension", \
        "question":"<their question, transcribed in Chinese>", \
        "answer":"<a direct answer in Chinese, 1-3 sentences>", \
        "sentence_position":<the line it is about>}

        Answer the question rather than describing it, and never repeat the audio \
        back as the answer. If you can answer but cannot isolate a phrase, use the \
        comprehension shape — an answer is always better than nothing.
        """

    private static func instruction(materialKind: String, request: String?) -> String {
        let framing = materialKind == "teaching"
            ? """
              This line is from an English-teaching podcast and the learner's goal \
              is to SAY these things. Extract, each as exactly one type:
              \(teachingTypes)
              """
            : """
              This line runs at native speed and was made for native speakers. The \
              learner can already read slowly; what defeats them is catching and \
              parsing real speech. Extract only what would make a learner MISS or \
              MISREAD it, each as exactly one type:
              \(nativeTypes)
              """

        var parts = [
            "Extract what is worth studying from ONE sentence of a transcript.",
            framing,
            fields,
            rejectRules,
        ]
        if let request, !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("""
                The learner specifically asked: "\(request)". \
                This overrides the type preferences above — answer what they asked \
                about, even if it is not what you would have picked. Still obey the \
                reject list and the field format.
                """)
        }
        return parts.joined(separator: "\n\n")
    }
}
