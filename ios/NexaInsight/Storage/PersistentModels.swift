import Foundation
import SwiftData

@Model final class StoredEpisode {
    @Attribute(.unique) var episodeId: Int
    var sourceUrl: String
    var youtubeId: String?
    var title: String?
    var channel: String?
    var durationMs: Int?
    var thumbnailUrl: String?
    var localAudioPath: String?
    var status: String
    var createdAt: Date
    // Playback position. OPTIONAL deliberately: SwiftData has to open stores
    // written before these existed, and a non-optional would need a migration for
    // what is only a convenience.
    var positionMs: Int?
    var lastPlayedAt: Date?
    /// "native" or "teaching". Optional for the same reason as the fields above,
    /// and on-demand extraction falls back to native when it is missing.
    var materialKind: String?
    /// The 洞察 page as JSON, exactly as the backend produced it.
    ///
    /// Stored as a blob rather than decomposed into models: it is written whole, read whole, and
    /// never queried by its parts. SwiftData migrations are the expensive kind of change here, and
    /// four extra @Model types would buy nothing.
    var insightJSON: String?
    @Relationship(deleteRule: .cascade) var chapters: [StoredChapter]
    @Relationship(deleteRule: .cascade) var sentences: [StoredSentence]
    @Relationship(deleteRule: .cascade) var recordings: [StoredRecording]
    @Relationship(deleteRule: .cascade) var insights: [StoredInsight]
    @Relationship(deleteRule: .cascade) var learningExpressions: [StoredLearningExpression]
    @Relationship(deleteRule: .cascade) var examplePractices: [StoredExamplePractice]

    init(episodeId: Int, sourceUrl: String, youtubeId: String?, title: String?, channel: String?, durationMs: Int?, thumbnailUrl: String?, localAudioPath: String?, status: String) {
        self.episodeId = episodeId; self.sourceUrl = sourceUrl; self.youtubeId = youtubeId
        self.title = title; self.channel = channel; self.durationMs = durationMs
        self.thumbnailUrl = thumbnailUrl; self.localAudioPath = localAudioPath; self.status = status
        self.createdAt = Date(); self.chapters = []; self.sentences = []; self.recordings = []; self.insights = []; self.learningExpressions = []; self.examplePractices = []
    }
}

@Model final class StoredChapter {
    var chapterId: Int; var episodeId: Int; var title: String; var summary: String; var startMs: Int; var endMs: Int
    init(chapterId: Int, episodeId: Int, title: String, summary: String, startMs: Int, endMs: Int) {
        self.chapterId = chapterId; self.episodeId = episodeId; self.title = title
        self.summary = summary; self.startMs = startMs; self.endMs = endMs
    }
}

@Model final class StoredSentence {
    var sentenceId: Int; var episodeId: Int; var chapterId: Int?; var position: Int
    var startMs: Int; var endMs: Int; var speaker: String?; var sourceText: String; var chinese: String
    init(sentenceId: Int, episodeId: Int, chapterId: Int?, position: Int, startMs: Int, endMs: Int, speaker: String?, sourceText: String, chinese: String) {
        self.sentenceId = sentenceId; self.episodeId = episodeId; self.chapterId = chapterId
        self.position = position; self.startMs = startMs; self.endMs = endMs
        self.speaker = speaker; self.sourceText = sourceText; self.chinese = chinese
    }
}

@Model final class StoredRecording {
    var episodeId: Int; var sentenceId: Int; var localFilePath: String; var isBest: Bool; var feedback: String?; var createdAt: Date
    init(episodeId: Int, sentenceId: Int, localFilePath: String, isBest: Bool = false, feedback: String? = nil) {
        self.episodeId = episodeId; self.sentenceId = sentenceId; self.localFilePath = localFilePath
        self.isBest = isBest; self.feedback = feedback; self.createdAt = Date()
    }
}

@Model final class StoredInsight {
    var episodeId: Int
    var title: String
    var body: String
    var sourceText: String
    var startMs: Int
    var endMs: Int
    var createdAt: Date

    init(episodeId: Int, title: String, body: String, sourceText: String, startMs: Int, endMs: Int) {
        self.episodeId = episodeId; self.title = title; self.body = body; self.sourceText = sourceText
        self.startMs = startMs; self.endMs = endMs; self.createdAt = Date()
    }
}

@Model final class StoredLearningExpression {
    var expressionId: Int; var episodeId: Int; var text: String; var kind: String; var chinese: String
    var pronunciation: String?; var example: String; var exampleChinese: String
    // Defaulted so an existing local store opens without a migration; a
    // re-download fills them in. Dropping these here made the richer card
    // invisible for downloaded episodes whatever the backend produced.
    var type: String = "phrase"
    var heardAs: String?
    var restored: String?
    var whyHard: String?
    var whenToUse: String?
    var commonMistake: String?
    var formality: String?
    // "auto" or "manual". Defaulted for the same reason as the fields above, and
    // "auto" is right for every row that predates on-demand notes.
    var source: String = "auto"
    var request: String?
    // Manual notes are created on the device before any upload, so they have no
    // backend id yet. Nil marks "not archived", which is what the uploader looks
    // for and what keeps a failed upload retriable.
    var remoteId: Int?
    @Relationship(deleteRule: .cascade) var occurrences: [StoredExpressionOccurrence]

    var isManual: Bool { source == "manual" }

    init(
        expressionId: Int, episodeId: Int, text: String, kind: String, type: String = "phrase",
        chinese: String, pronunciation: String?, example: String, exampleChinese: String,
        heardAs: String? = nil, restored: String? = nil, whyHard: String? = nil,
        whenToUse: String? = nil, commonMistake: String? = nil, formality: String? = nil,
        source: String = "auto", request: String? = nil, remoteId: Int? = nil
    ) {
        self.expressionId = expressionId; self.episodeId = episodeId; self.text = text; self.kind = kind
        self.type = type
        self.chinese = chinese; self.pronunciation = pronunciation; self.example = example; self.exampleChinese = exampleChinese
        self.heardAs = heardAs; self.restored = restored; self.whyHard = whyHard
        self.whenToUse = whenToUse; self.commonMistake = commonMistake; self.formality = formality
        self.source = source; self.request = request; self.remoteId = remoteId
        self.occurrences = []
    }
}

@Model final class StoredExpressionOccurrence {
    var sentenceId: Int; var startOffset: Int; var endOffset: Int

    init(sentenceId: Int, startOffset: Int, endOffset: Int) {
        self.sentenceId = sentenceId; self.startOffset = startOffset; self.endOffset = endOffset
    }
}

/// A free-form question about one paragraph, and the answer.
///
/// Separate from `StoredLearningExpression` because that model is entirely about a
/// piece of vocabulary — pronunciation, the sound it reduces to, the form to
/// restore, the example to shadow. A question like "what is this paragraph
/// arguing" fills none of those, and forcing it in would mean fifteen nil columns
/// and `chinese` quietly repurposed as the answer.
///
/// Anchored to a sentence id rather than to character offsets: the subject is the
/// paragraph, so there is nothing to highlight and no offsets to keep aligned.
@Model final class StoredParagraphNote {
    /// Negative and local, same convention as manual expressions: backend ids are
    /// positive, so the two can never collide if these are ever synced.
    var noteId: Int
    var episodeId: Int
    var sentenceId: Int
    var question: String
    var answer: String
    var createdAt: Date

    init(noteId: Int, episodeId: Int, sentenceId: Int, question: String, answer: String) {
        self.noteId = noteId
        self.episodeId = episodeId
        self.sentenceId = sentenceId
        self.question = question
        self.answer = answer
        self.createdAt = Date()
    }
}

@Model final class StoredExamplePractice {
    var episodeId: Int; var expressionId: Int; var localFilePath: String
    var overall: Int; var clarity: Int; var stressRhythm: Int; var completeness: Int; var advice: String
    var createdAt: Date

    init(episodeId: Int, expressionId: Int, localFilePath: String, overall: Int, clarity: Int, stressRhythm: Int, completeness: Int, advice: String) {
        self.episodeId = episodeId; self.expressionId = expressionId; self.localFilePath = localFilePath
        self.overall = overall; self.clarity = clarity; self.stressRhythm = stressRhythm; self.completeness = completeness
        self.advice = advice; self.createdAt = Date()
    }
}
