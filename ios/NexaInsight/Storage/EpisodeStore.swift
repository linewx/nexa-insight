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
        // Both kinds are stored now. The filter here used to keep only manual notes,
        // because extraction pre-picked hundreds of words nobody chose; the scan that
        // replaced it returns only the two failures a learner cannot ask about — a shifted
        // sense, a set phrase — and returns nothing at all for most passages.
        //
        // Left in place, this filter silently discarded every scanned card: the backend
        // did the work, shipped it in the bundle, and the phone dropped it on the way in.
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
        //
        // Searched across the whole episode, not only in `sentenceId`. The caller's idea
        // of "the current line" comes from the playback position, while a saved word comes
        // from whatever the teacher was just discussing — in reading those are routinely
        // different lines, and a strict match meant the card saved with NO occurrence and
        // therefore no highlight. The named sentence is still tried FIRST, so a word that
        // appears in several lines highlights the one being talked about.
        let host = stored.sentences.first { $0.sentenceId == sentenceId }
        let ordered = [host].compactMap { $0 } + stored.sentences.filter { $0.sentenceId != sentenceId }
        if let found = ordered.lazy.compactMap({ sentence -> (Int, Range<Int>)? in
            ExpressionLocator.locate(expression.text, in: sentence.sourceText)
                .map { (sentence.sentenceId, $0) }
        }).first {
            let occurrence = StoredExpressionOccurrence(
                sentenceId: found.0, startOffset: found.1.lowerBound, endOffset: found.1.upperBound)
            context.insert(occurrence)
            note.occurrences.append(occurrence)
        } else {
            // A word the teacher paraphrased rather than quoted cannot be found in the
            // transcript. The card is still worth keeping — it just carries no highlight,
            // which is the same thing the batch pipeline does for a {slot} pattern.
            NexaLog.log("addManualExpression: no occurrence for \(expression.text)")
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

    /// Removes every batch-extracted expression from every episode, and reports how many.
    ///
    /// A migration, run once on launch: the app no longer stores these (see `attach`), but
    /// a device that ran the old build has them, and they would sit in the notes list and
    /// highlight the transcript forever otherwise.
    ///
    /// Removes everything the learner made by hand on one episode, and reports how many.
    ///
    /// Automatic rows are left alone, for the same reason a single one cannot be deleted:
    /// a reprocess rewrites them, so removing one is a promise the next sync would break.
    /// That makes "clear" mean "clear what I made", which is also the only half a learner
    /// thinks of as theirs.
    ///
    /// One save at the end rather than per row: clearing thirty notes should be one write.
    @discardableResult
    func clearManualNotes(for episodeId: Int) throws -> Int {
        var removed = 0
        if let stored = episode(episodeId) {
            for expression in stored.learningExpressions where expression.isManual {
                expression.occurrences.forEach(context.delete)
                context.delete(expression)
                removed += 1
            }
        }
        for note in paragraphNotes(for: episodeId) {
            context.delete(note)
            removed += 1
        }
        try context.save()
        return removed
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

    /// Records that an episode was opened, which is what the library sorts by.
    ///
    /// Separate from `savePlaybackPosition` because that one only fires once playback
    /// passes ten seconds — so opening an episode, reading a paragraph and leaving would
    /// not have counted as a visit, and the library would keep showing it wherever it was
    /// added. Opening it IS the visit. Deliberately does not touch `positionMs`: where you
    /// were is a different fact from when you were last here.
    func markVisited(_ episodeId: Int) {
        guard let stored = episode(episodeId) else { return }
        stored.lastPlayedAt = Date()
        try? context.save()
    }

    /// Most recently visited first, and newest-added for anything never opened.
    ///
    /// Sorted here rather than in the fetch: `lastPlayedAt` is optional, and SwiftData
    /// puts nil at one end wholesale — which would either bury every new episode below
    /// everything ever opened, or float them all above it. Neither is "recent". So an
    /// episode falls back to its own `createdAt`, which puts a just-added episode exactly
    /// where a just-visited one would be.
    func downloadedEpisodes() -> [EpisodeDTO] {
        let fetched = (try? context.fetch(FetchDescriptor<StoredEpisode>())) ?? []
        let all = fetched.sorted { a, b in
            (a.lastPlayedAt ?? a.createdAt) > (b.lastPlayedAt ?? b.createdAt)
        }
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
