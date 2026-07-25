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
}

struct JobDTO: Codable, Equatable {
    let id: Int
    let episodeId: Int
    let stage: String
    let status: String
    let progress: Int
    let error: String?
}

struct BundleDTO: Codable, Equatable {
    let episode: EpisodeDTO
    let chapters: [ChapterDTO]
    let sentences: [SentenceDTO]
    let hasAudio: Bool
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
