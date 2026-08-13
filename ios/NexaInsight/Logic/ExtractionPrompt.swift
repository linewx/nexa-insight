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

    /// The per-item fields. Deliberately says nothing about the wrapping key: batch
    /// extraction wants "expressions", a reading conversation wants "points", and
    /// naming one here contradicted the other at the point of use.
    static let fields = """
        For each item return: text, type, chinese, pronunciation (IPA, single \
        words only, no slashes, else null), heard_as, restored, why_hard (one \
        Chinese sentence on why it defeats a listener or reader), when_to_use, \
        common_mistake, formality ("formal"|"neutral"|"spoken"|"technical"), \
        example (verbatim from the sentence), example_chinese.
        """

    /// What to keep from a finished reading conversation, if anything.
    ///
    /// The input is text, not audio: the realtime session already transcribed both
    /// sides, so this reads what was actually said rather than listening again. One
    /// less model hop, and one less chance to mishear.
    ///
    /// The load-bearing instruction is permission to keep NOTHING. Reading a
    /// paragraph produces a lot of talk that is not worth a card — confirming a word
    /// you already knew, asking where a name comes from, an aside that went nowhere.
    /// The old path had no way to say so: every question became a card, so the stack
    /// filled with "I asked about this once" and the real material was lost among it.
    /// `rejectRules` already said this for batch extraction; it says it here too.
    ///
    /// One conversation yields at most a few points, and a follow-up chain usually
    /// yields ONE: "what does that refer to" then "so why passive" is a single thing
    /// understood, not two.
    static func conversationRules(materialKind: String) -> String {
        let types = materialKind == "teaching" ? teachingTypes : nativeTypes
        return """
            You are reviewing a finished exchange between a learner and their teacher \
            about one paragraph of a transcript. Decide what — IF ANYTHING — is worth \
            keeping as a study card.

            KEEP NOTHING when the exchange taught nothing durable. Returning an empty \
            array is a correct and common answer, not a failure. Reject: a word the \
            learner turned out to already know; a fact about the world with no English \
            in it; small talk; a question that was never really answered; anything \
            they would not want to see again in a week. Do not invent a card to be \
            helpful — an empty result is better than a card that wastes a review.

            A follow-up chain about one thing is ONE card, not one per turn.

            Return {"points":[ … ]} where each point is either

            a vocabulary card, when the exchange was about a word or phrase to learn, \
            carrying the fields below plus \
            "question":"<what the learner asked, in Chinese>" and \
            "kind":"vocabulary"

            \(fields)

            \(types)

            or a question card, for anything else worth remembering — meaning, \
            grammar, argument, background:
            {"kind":"question","question":"<what they asked, in Chinese>", \
            "answer":"<the answer as settled, in Chinese, 1-3 sentences>"}

            The answer must be what the exchange CONCLUDED, written to be read cold in \
            a week — not a transcript of how they got there, and not a reference to \
            "as mentioned above".

            \(rejectRules)
            """
    }

}
