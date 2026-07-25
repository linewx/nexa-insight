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
    @Relationship(deleteRule: .cascade) var chapters: [StoredChapter]
    @Relationship(deleteRule: .cascade) var sentences: [StoredSentence]
    @Relationship(deleteRule: .cascade) var recordings: [StoredRecording]
    @Relationship(deleteRule: .cascade) var insights: [StoredInsight]

    init(episodeId: Int, sourceUrl: String, youtubeId: String?, title: String?, channel: String?, durationMs: Int?, thumbnailUrl: String?, localAudioPath: String?, status: String) {
        self.episodeId = episodeId; self.sourceUrl = sourceUrl; self.youtubeId = youtubeId
        self.title = title; self.channel = channel; self.durationMs = durationMs
        self.thumbnailUrl = thumbnailUrl; self.localAudioPath = localAudioPath; self.status = status
        self.createdAt = Date(); self.chapters = []; self.sentences = []; self.recordings = []; self.insights = []
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
