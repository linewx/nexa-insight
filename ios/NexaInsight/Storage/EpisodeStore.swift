import Foundation
import SwiftData

@MainActor
final class EpisodeStore {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: StoredEpisode.self, StoredChapter.self, StoredSentence.self, StoredRecording.self, StoredInsight.self, StoredLearningExpression.self, StoredExpressionOccurrence.self, StoredExamplePractice.self, StoredParagraphNote.self, configurations: config)
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
            // Manual notes are the learner's own work and nothing can regenerate
            // them, so a bundle download replaces only what extraction produced.
            // Deleting all of them here meant every resync — and every reinstall
            // that re-downloaded — silently threw away hand-made notes.
            //
            // A note already archived to the backend comes back inside the bundle,
            // so keeping the local copy too would double it. Those are dropped by
            // remoteId and re-attached from the payload below.
            let (archived, unsynced) = existing.learningExpressions.reduce(
                into: ([StoredLearningExpression](), [StoredLearningExpression]())
            ) { partial, item in
                guard item.isManual else { return }
                if item.remoteId == nil { partial.1.append(item) } else { partial.0.append(item) }
            }
            existing.learningExpressions
                .filter { !$0.isManual }
                .forEach(context.delete)
            archived.forEach(context.delete)
            existing.sentences = []; existing.chapters = []; existing.learningExpressions = unsynced
            existing.title = e.title; existing.channel = e.channel; existing.status = e.status
            existing.materialKind = e.materialKind ?? existing.materialKind
            if let localAudioPath { existing.localAudioPath = localAudioPath }
            try attach(bundle, to: existing)
            try context.save()
            return existing
        }
        let stored = StoredEpisode(episodeId: e.id, sourceUrl: e.sourceUrl, youtubeId: e.youtubeId, title: e.title, channel: e.channel, durationMs: e.durationMs, thumbnailUrl: e.thumbnailUrl, localAudioPath: localAudioPath, status: e.status)
        stored.materialKind = e.materialKind
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
        for item in bundle.learningExpressions {
            let expression = StoredLearningExpression(
                expressionId: item.id, episodeId: bundle.episode.id, text: item.text,
                kind: item.kind.rawValue, type: item.type.rawValue,
                chinese: item.chinese, pronunciation: item.pronunciation,
                example: item.example, exampleChinese: item.exampleChinese,
                heardAs: item.heardAs, restored: item.restored, whyHard: item.whyHard,
                whenToUse: item.whenToUse, commonMistake: item.commonMistake,
                formality: item.formality,
                // A manual note that round-tripped through the backend carries its
                // id, which is what marks it archived and stops the uploader from
                // sending it twice.
                source: item.source, request: item.request,
                remoteId: item.source == "manual" ? item.id : nil)
            context.insert(expression)
            for item in item.occurrences {
                let occurrence = StoredExpressionOccurrence(
                    sentenceId: item.sentenceId, startOffset: item.startOffset, endOffset: item.endOffset)
                context.insert(occurrence)
                expression.occurrences.append(occurrence)
            }
            stored.learningExpressions.append(expression)
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

    func learningExpressions(for episodeId: Int) -> [LearningExpressionDTO] {
        guard let e = episode(episodeId) else { return [] }
        return e.learningExpressions.sorted { $0.expressionId < $1.expressionId }.compactMap { item in
            // Unknown stored values fall back rather than dropping the row: a
            // discarded expression is a hole in the transcript's highlights.
            let kind = LearningExpressionKind(fallbackFrom: item.kind)
            return LearningExpressionDTO(
                id: item.expressionId, text: item.text, kind: kind,
                type: LearningExpressionType(rawValue: item.type) ?? .phrase,
                chinese: item.chinese,
                pronunciation: item.pronunciation, example: item.example, exampleChinese: item.exampleChinese,
                heardAs: item.heardAs, restored: item.restored, whyHard: item.whyHard,
                whenToUse: item.whenToUse, commonMistake: item.commonMistake,
                formality: item.formality,
                source: item.source, request: item.request,
                occurrences: item.occurrences.map {
                    ExpressionOccurrenceDTO(sentenceId: $0.sentenceId, startOffset: $0.startOffset, endOffset: $0.endOffset)
                })
        }
    }

    /// Stores a note the learner asked for, anchored by searching the sentence for
    /// the expression text.
    ///
    /// The id is local and negative. Backend ids are positive and assigned on
    /// upload, so a negative one cannot collide with a row that arrives in a
    /// bundle later, and its sign says "not archived yet" without a second field
    /// to keep in sync.
    @discardableResult
    func addManualExpression(
        episodeId: Int, sentenceId: Int, expression: LearningExpressionDTO, request: String?
    ) throws -> StoredLearningExpression? {
        guard let stored = episode(episodeId) else { return nil }
        let nextLocalId = (stored.learningExpressions.map(\.expressionId).min() ?? 0) - 1
        let note = StoredLearningExpression(
            expressionId: min(nextLocalId, -1), episodeId: episodeId, text: expression.text,
            kind: expression.kind.rawValue, type: expression.type.rawValue,
            chinese: expression.chinese, pronunciation: expression.pronunciation,
            example: expression.example, exampleChinese: expression.exampleChinese,
            heardAs: expression.heardAs, restored: expression.restored, whyHard: expression.whyHard,
            whenToUse: expression.whenToUse, commonMistake: expression.commonMistake,
            formality: expression.formality, source: "manual", request: request)
        context.insert(note)

        // Anchored by text, not by any offset the model reported: those were wrong
        // ~97% of the time in the batch pipeline, and the same model answers here.
        if let sentence = stored.sentences.first(where: { $0.sentenceId == sentenceId }),
           let range = ExpressionLocator.locate(expression.text, in: sentence.sourceText) {
            let occurrence = StoredExpressionOccurrence(
                sentenceId: sentenceId, startOffset: range.lowerBound, endOffset: range.upperBound)
            context.insert(occurrence)
            note.occurrences.append(occurrence)
        }
        stored.learningExpressions.append(note)
        try context.save()
        return note
    }

    /// The DTO for one stored expression, so a freshly made note can be shown
    /// without re-reading the whole episode.
    func expressionDTO(_ item: StoredLearningExpression) -> LearningExpressionDTO {
        LearningExpressionDTO(
            id: item.expressionId, text: item.text,
            kind: LearningExpressionKind(fallbackFrom: item.kind),
            type: LearningExpressionType(rawValue: item.type) ?? .phrase,
            chinese: item.chinese, pronunciation: item.pronunciation,
            example: item.example, exampleChinese: item.exampleChinese,
            heardAs: item.heardAs, restored: item.restored, whyHard: item.whyHard,
            whenToUse: item.whenToUse, commonMistake: item.commonMistake,
            formality: item.formality, source: item.source, request: item.request,
            occurrences: item.occurrences.map {
                ExpressionOccurrenceDTO(sentenceId: $0.sentenceId, startOffset: $0.startOffset, endOffset: $0.endOffset)
            })
    }

    // MARK: - Paragraph notes

    @discardableResult
    func addParagraphNote(
        episodeId: Int, sentenceId: Int, question: String, answer: String
    ) throws -> StoredParagraphNote {
        let existing = paragraphNotes(for: episodeId)
        let note = StoredParagraphNote(
            noteId: min((existing.map(\.noteId).min() ?? 0) - 1, -1),
            episodeId: episodeId, sentenceId: sentenceId, question: question, answer: answer)
        context.insert(note)
        try context.save()
        return note
    }

    /// Oldest first, so a paragraph's cards read in the order they were asked.
    func paragraphNotes(for episodeId: Int) -> [StoredParagraphNote] {
        let notes = (try? context.fetch(FetchDescriptor<StoredParagraphNote>(
            predicate: #Predicate { $0.episodeId == episodeId },
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return notes
    }

    func deleteParagraphNote(_ noteId: Int) throws {
        let matches = (try? context.fetch(FetchDescriptor<StoredParagraphNote>(
            predicate: #Predicate { $0.noteId == noteId }))) ?? []
        matches.forEach(context.delete)
        try context.save()
    }

    /// Deletes a note the learner made by hand.
    ///
    /// Refuses anything from batch extraction: those are replaced wholesale by a
    /// reprocess, so "deleting" one would only make it reappear on the next sync —
    /// a delete that does not stay deleted is worse than no delete.
    func deleteManualExpression(_ expressionId: Int) throws {
        let matches = (try? context.fetch(FetchDescriptor<StoredLearningExpression>(
            predicate: #Predicate { $0.expressionId == expressionId }))) ?? []
        for match in matches where match.isManual {
            match.occurrences.forEach(context.delete)
            context.delete(match)
        }
        try context.save()
    }

    /// Manual notes that have not reached the backend yet.
    func unsyncedManualExpressions(for episodeId: Int) -> [StoredLearningExpression] {
        guard let stored = episode(episodeId) else { return [] }
        return stored.learningExpressions.filter { $0.isManual && $0.remoteId == nil }
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
            EpisodeDTO(id: $0.episodeId, sourceUrl: $0.sourceUrl, youtubeId: $0.youtubeId, title: $0.title, channel: $0.channel, durationMs: $0.durationMs, thumbnailUrl: $0.thumbnailUrl, audioPath: $0.localAudioPath, status: $0.status, error: nil, positionMs: $0.positionMs, materialKind: $0.materialKind)
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
    func addExamplePractice(episodeId: Int, expressionId: Int, localFilePath: String, overall: Int, clarity: Int, stressRhythm: Int, completeness: Int, advice: String) throws -> StoredExamplePractice {
        let practice = StoredExamplePractice(
            episodeId: episodeId, expressionId: expressionId, localFilePath: localFilePath,
            overall: overall, clarity: clarity, stressRhythm: stressRhythm,
            completeness: completeness, advice: advice)
        context.insert(practice)
        if let episode = episode(episodeId) { episode.examplePractices.append(practice) }
        try context.save()
        return practice
    }

    func examplePractices(episodeId: Int, expressionId: Int) -> [StoredExamplePractice] {
        (try? context.fetch(FetchDescriptor<StoredExamplePractice>(
            predicate: #Predicate { $0.episodeId == episodeId && $0.expressionId == expressionId },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
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
