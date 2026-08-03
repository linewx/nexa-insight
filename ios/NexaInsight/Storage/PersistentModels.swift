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
    @Relationship(deleteRule: .cascade) var occurrences: [StoredExpressionOccurrence]

    init(expressionId: Int, episodeId: Int, text: String, kind: String, chinese: String, pronunciation: String?, example: String, exampleChinese: String) {
        self.expressionId = expressionId; self.episodeId = episodeId; self.text = text; self.kind = kind
        self.chinese = chinese; self.pronunciation = pronunciation; self.example = example; self.exampleChinese = exampleChinese
        self.occurrences = []
    }
}

@Model final class StoredExpressionOccurrence {
    var sentenceId: Int; var startOffset: Int; var endOffset: Int

    init(sentenceId: Int, startOffset: Int, endOffset: Int) {
        self.sentenceId = sentenceId; self.startOffset = startOffset; self.endOffset = endOffset
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
