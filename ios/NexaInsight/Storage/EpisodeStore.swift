import Foundation
import SwiftData

@MainActor
final class EpisodeStore {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: StoredEpisode.self, StoredChapter.self, StoredSentence.self, StoredRecording.self, StoredInsight.self, configurations: config)
    }

    private func episode(_ id: Int) -> StoredEpisode? {
        try? context.fetch(FetchDescriptor<StoredEpisode>(predicate: #Predicate { $0.episodeId == id })).first
    }

    @discardableResult
    func saveBundle(_ bundle: BundleDTO, localAudioPath: String?) throws -> StoredEpisode {
        let e = bundle.episode
        if let existing = episode(e.id) {
            existing.sentences.forEach(context.delete)
            existing.chapters.forEach(context.delete)
            existing.sentences = []; existing.chapters = []
            existing.title = e.title; existing.channel = e.channel; existing.status = e.status
            if let localAudioPath { existing.localAudioPath = localAudioPath }
            try attach(bundle, to: existing)
            try context.save()
            return existing
        }
        let stored = StoredEpisode(episodeId: e.id, sourceUrl: e.sourceUrl, youtubeId: e.youtubeId, title: e.title, channel: e.channel, durationMs: e.durationMs, thumbnailUrl: e.thumbnailUrl, localAudioPath: localAudioPath, status: e.status)
        context.insert(stored)
        try attach(bundle, to: stored)
        try context.save()
        return stored
    }

    private func attach(_ bundle: BundleDTO, to stored: StoredEpisode) throws {
        for c in bundle.chapters {
            let chapter = StoredChapter(chapterId: c.id, episodeId: bundle.episode.id, title: c.title, summary: c.summary, startMs: c.startMs, endMs: c.endMs)
            context.insert(chapter); stored.chapters.append(chapter)
        }
        for s in bundle.sentences {
            let sentence = StoredSentence(sentenceId: s.id, episodeId: bundle.episode.id, chapterId: s.chapterId, position: s.position, startMs: s.startMs, endMs: s.endMs, speaker: s.speaker, sourceText: s.sourceText, chinese: s.chinese)
            context.insert(sentence); stored.sentences.append(sentence)
        }
    }

    func sentences(for episodeId: Int) -> [SentenceDTO] {
        guard let e = episode(episodeId) else { return [] }
        return e.sentences.sorted { $0.position < $1.position }.map {
            SentenceDTO(id: $0.sentenceId, episodeId: $0.episodeId, chapterId: $0.chapterId, position: $0.position, startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker, sourceText: $0.sourceText, chinese: $0.chinese)
        }
    }

    func chapters(for episodeId: Int) -> [ChapterDTO] {
        guard let e = episode(episodeId) else { return [] }
        return e.chapters.sorted { $0.startMs < $1.startMs }.map {
            ChapterDTO(id: $0.chapterId, title: $0.title, summary: $0.summary, startMs: $0.startMs, endMs: $0.endMs)
        }
    }

    func localAudioPath(for episodeId: Int) -> String? { episode(episodeId)?.localAudioPath }

    func playbackPosition(for episodeId: Int) -> Int? { episode(episodeId)?.positionMs }

    // Called as playback advances, so it is throttled by Resume.shouldPersist at
    // the call site rather than writing on every tick.
    func savePlaybackPosition(_ ms: Int, for episodeId: Int) {
        guard let stored = episode(episodeId) else { return }
        stored.positionMs = ms
        stored.lastPlayedAt = Date()
        try? context.save()
    }

    func downloadedEpisodes() -> [EpisodeDTO] {
        let all = (try? context.fetch(FetchDescriptor<StoredEpisode>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        return all.map {
            EpisodeDTO(id: $0.episodeId, sourceUrl: $0.sourceUrl, youtubeId: $0.youtubeId, title: $0.title, channel: $0.channel, durationMs: $0.durationMs, thumbnailUrl: $0.thumbnailUrl, audioPath: $0.localAudioPath, status: $0.status, error: nil, positionMs: $0.positionMs)
        }
    }

    @discardableResult
    func addRecording(episodeId: Int, sentenceId: Int, localFilePath: String) throws -> StoredRecording {
        let recording = StoredRecording(episodeId: episodeId, sentenceId: sentenceId, localFilePath: localFilePath)
        context.insert(recording)
        if let e = episode(episodeId) { e.recordings.append(recording) }
        try context.save()
        return recording
    }

    func recordings(sentenceId: Int) -> [StoredRecording] {
        (try? context.fetch(FetchDescriptor<StoredRecording>(predicate: #Predicate { $0.sentenceId == sentenceId }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func markBest(recordingId: PersistentIdentifier) throws {
        guard let target = context.model(for: recordingId) as? StoredRecording else { return }
        for peer in recordings(sentenceId: target.sentenceId) { peer.isBest = false }
        target.isBest = true
        try context.save()
    }

    func setFeedback(recordingId: PersistentIdentifier, feedback: String) throws {
        guard let target = context.model(for: recordingId) as? StoredRecording else { return }
        target.feedback = feedback
        try context.save()
    }

    @discardableResult
    func addInsight(episodeId: Int, title: String, body: String, sourceText: String, startMs: Int, endMs: Int) throws -> StoredInsight {
        let insight = StoredInsight(episodeId: episodeId, title: title, body: body, sourceText: sourceText, startMs: startMs, endMs: endMs)
        context.insert(insight)
        if let episode = episode(episodeId) { episode.insights.append(insight) }
        try context.save()
        return insight
    }
}
