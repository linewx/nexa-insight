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

    /// The extractor is asked for word/phrase/pattern but does not comply: real
    /// imports produced 19 distinct labels ("phrasal verb", "collocation",
    /// "compound noun (YC term)"). A plain `String` enum throws on those, and one
    /// bad value failed the entire bundle decode, so the whole episode showed an
    /// error instead of the expressions that did parse.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(fallbackFrom: raw)
    }

    init(fallbackFrom raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = Self(rawValue: text) {
            self = exact
        } else if text.contains("pattern") {
            self = .pattern
        } else if text.contains("word") || text.contains("acronym") {
            self = .word
        } else {
            self = .phrase
        }
    }
}

/// What kind of study item this is, which picks the card template.
///
/// The two source kinds are mined for different things: native-speed material for
/// what defeats comprehension, teaching material for what the learner should be
/// able to say. Decoding tolerates unknown values for the same reason
/// `LearningExpressionKind` does — one unrecognised string used to fail the whole
/// bundle and take the episode down with it.
enum LearningExpressionType: String, Codable, Equatable, CaseIterable {
    // Native-speed material: why the line was missed or misread.
    case reduction
    case ellipsis
    case syntax
    case idiom
    case reference
    // Teaching material: what to put in the learner's own mouth.
    case phrase
    case pattern
    case collocation
    // Either source.
    case word
    case chunk

    /// True when the card's job is to explain a comprehension failure rather than
    /// to hand the learner something to say.
    var explainsComprehension: Bool {
        switch self {
        case .reduction, .ellipsis, .syntax, .idiom, .reference: true
        case .phrase, .pattern, .collocation, .word, .chunk: false
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = Self(rawValue: text)
            ?? Self.allCases.first { text.contains($0.rawValue) }
            ?? .phrase
    }
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
    /// Absent from older backends, where the three-value `kind` was all there was.
    let type: LearningExpressionType
    let chinese: String
    let pronunciation: String?
    let example: String
    let exampleChinese: String
    let heardAs: String?
    let restored: String?
    let whyHard: String?
    let whenToUse: String?
    let commonMistake: String?
    let formality: String?
    let occurrences: [ExpressionOccurrenceDTO]

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        kind = try values.decode(LearningExpressionKind.self, forKey: .kind)
        type = try values.decodeIfPresent(LearningExpressionType.self, forKey: .type) ?? .phrase
        chinese = try values.decode(String.self, forKey: .chinese)
        pronunciation = try values.decodeIfPresent(String.self, forKey: .pronunciation)
        example = try values.decode(String.self, forKey: .example)
        exampleChinese = try values.decode(String.self, forKey: .exampleChinese)
        heardAs = try values.decodeIfPresent(String.self, forKey: .heardAs)
        restored = try values.decodeIfPresent(String.self, forKey: .restored)
        whyHard = try values.decodeIfPresent(String.self, forKey: .whyHard)
        whenToUse = try values.decodeIfPresent(String.self, forKey: .whenToUse)
        commonMistake = try values.decodeIfPresent(String.self, forKey: .commonMistake)
        formality = try values.decodeIfPresent(String.self, forKey: .formality)
        occurrences = try values.decodeIfPresent([ExpressionOccurrenceDTO].self, forKey: .occurrences) ?? []
    }

    init(
        id: Int, text: String, kind: LearningExpressionKind, type: LearningExpressionType = .phrase,
        chinese: String, pronunciation: String? = nil, example: String, exampleChinese: String,
        heardAs: String? = nil, restored: String? = nil, whyHard: String? = nil,
        whenToUse: String? = nil, commonMistake: String? = nil, formality: String? = nil,
        occurrences: [ExpressionOccurrenceDTO] = []
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.type = type
        self.chinese = chinese
        self.pronunciation = pronunciation
        self.example = example
        self.exampleChinese = exampleChinese
        self.heardAs = heardAs
        self.restored = restored
        self.whyHard = whyHard
        self.whenToUse = whenToUse
        self.commonMistake = commonMistake
        self.formality = formality
        self.occurrences = occurrences
    }
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

    // Names must stay camelCase: the decoder applies .convertFromSnakeCase, so
    // "has_audio" arrives as "hasAudio" and a literal snake_case key never
    // matches. Spelling them out as snake_case made every bundle fail with
    // "The data couldn't be read because it is missing".
    private enum CodingKeys: String, CodingKey {
        case episode, chapters, sentences, hasAudio, hasLearningPack, learningExpressions
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
