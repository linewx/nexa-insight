import Foundation

struct SentenceDTO: Codable, Identifiable, Equatable {
    let id: Int
    let episodeId: Int
    let chapterId: Int?
    let position: Int
    let startMs: Int
    let endMs: Int
    let speaker: String?
    let sourceText: String
    let chinese: String
}

struct ChapterDTO: Codable, Identifiable, Equatable {
    let id: Int
    let title: String
    let summary: String
    let startMs: Int
    let endMs: Int
}

struct EpisodeDTO: Codable, Identifiable, Equatable {
    let id: Int
    let sourceUrl: String
    let youtubeId: String?
    let title: String?
    let channel: String?
    let durationMs: Int?
    let thumbnailUrl: String?
    let audioPath: String?
    let status: String
    let error: String?
    // Saved playback position. Optional and defaulted so the backend's decoding of
    // this DTO is unaffected — the backend has no such field.
    var positionMs: Int? = nil
}

struct JobDTO: Codable, Equatable {
    let id: Int
    let episodeId: Int
    let stage: String
    let status: String
    let progress: Int
    let error: String?
}

enum LearningExpressionKind: String, Codable, Equatable {
    case word
    case phrase
    case pattern
}

struct ExpressionOccurrenceDTO: Codable, Equatable {
    let sentenceId: Int
    let startOffset: Int
    let endOffset: Int
}

struct LearningExpressionDTO: Codable, Identifiable, Equatable {
    let id: Int
    let text: String
    let kind: LearningExpressionKind
    let chinese: String
    let pronunciation: String?
    let example: String
    let exampleChinese: String
    let occurrences: [ExpressionOccurrenceDTO]
}

struct BundleDTO: Codable, Equatable {
    let episode: EpisodeDTO
    let chapters: [ChapterDTO]
    let sentences: [SentenceDTO]
    let hasAudio: Bool
    let hasLearningPack: Bool
    let learningExpressions: [LearningExpressionDTO]

    init(
        episode: EpisodeDTO,
        chapters: [ChapterDTO],
        sentences: [SentenceDTO],
        hasAudio: Bool,
        hasLearningPack: Bool = false,
        learningExpressions: [LearningExpressionDTO] = []
    ) {
        self.episode = episode
        self.chapters = chapters
        self.sentences = sentences
        self.hasAudio = hasAudio
        self.hasLearningPack = hasLearningPack
        self.learningExpressions = learningExpressions
    }

    private enum CodingKeys: String, CodingKey {
        case episode, chapters, sentences
        case hasAudio = "has_audio"
        case hasLearningPack = "has_learning_pack"
        case learningExpressions = "learning_expressions"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        episode = try values.decode(EpisodeDTO.self, forKey: .episode)
        chapters = try values.decode([ChapterDTO].self, forKey: .chapters)
        sentences = try values.decode([SentenceDTO].self, forKey: .sentences)
        hasAudio = try values.decode(Bool.self, forKey: .hasAudio)
        hasLearningPack = try values.decodeIfPresent(Bool.self, forKey: .hasLearningPack) ?? false
        learningExpressions = try values.decodeIfPresent([LearningExpressionDTO].self, forKey: .learningExpressions) ?? []
    }
}

struct TutorTurn: Equatable {
    enum Role { case user, assistant, system }
    let role: Role
    let text: String
    var corrections: [String]
    init(role: Role, text: String, corrections: [String] = []) {
        self.role = role; self.text = text; self.corrections = corrections
    }
}
