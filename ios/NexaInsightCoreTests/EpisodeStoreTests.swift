import XCTest
import SwiftData
@testable import NexaInsightCore

@MainActor
final class EpisodeStoreTests: XCTestCase {
    func makeStore() throws -> EpisodeStore {
        try EpisodeStore(inMemory: true)
    }

    func bundle() -> BundleDTO {
        BundleDTO(
            episode: EpisodeDTO(id: 1, sourceUrl: "u", youtubeId: "y", title: "T", channel: "C", durationMs: 1000, thumbnailUrl: nil, audioPath: "episodes/1/source.mp3", status: "ready", error: nil),
            chapters: [ChapterDTO(id: 1, title: "Intro", summary: "s", startMs: 0, endMs: 1000)],
            sentences: [
                SentenceDTO(id: 10, episodeId: 1, chapterId: 1, position: 0, startMs: 0, endMs: 500, speaker: nil, sourceText: "Hi", chinese: "嗨"),
                SentenceDTO(id: 11, episodeId: 1, chapterId: 1, position: 1, startMs: 500, endMs: 1000, speaker: nil, sourceText: "Bye", chinese: "拜"),
            ],
            hasAudio: true,
            hasLearningPack: true,
            learningExpressions: [
                LearningExpressionDTO(id: 1, text: "Hello", kind: .word, chinese: "你好", pronunciation: "həˈloʊ", example: "Hello again.", exampleChinese: "再次你好。", occurrences: [
                    ExpressionOccurrenceDTO(sentenceId: 10, startOffset: 0, endOffset: 2),
                ])
            ])
    }

    // Every study field has to survive the round trip: anything dropped here is invisible
    // in the app whatever produced it. A MANUAL note, because those are the only rows the
    // store keeps now — an archived note comes back inside the bundle the same way.
    func testSavedExpressionKeepsItsStudyFields() throws {
        let store = try makeStore()
        let expression = LearningExpressionDTO(
            id: 2, text: "kind of", kind: .phrase, type: .reduction, chinese: "有点儿",
            pronunciation: nil, example: "I kind of like it.", exampleChinese: "我有点喜欢。",
            heardAs: "kinda", restored: "kind of", whyHard: "弱读脱落。",
            whenToUse: nil, commonMistake: "a little bit of", formality: "spoken",
            source: "manual",
            occurrences: [ExpressionOccurrenceDTO(sentenceId: 10, startOffset: 0, endOffset: 2)])
        _ = try store.saveBundle(
            BundleDTO(episode: bundle().episode, chapters: [], sentences: [], hasAudio: false,
                      hasLearningPack: true, learningExpressions: [expression]),
            localAudioPath: nil)

        let read = try XCTUnwrap(store.learningExpressions(for: 1).first)
        XCTAssertEqual(read.type, .reduction)
        XCTAssertEqual(read.heardAs, "kinda")
        XCTAssertEqual(read.restored, "kind of")
        XCTAssertEqual(read.whyHard, "弱读脱落。")
        XCTAssertEqual(read.commonMistake, "a little bit of")
        XCTAssertEqual(read.formality, "spoken")
    }

    // MARK: - Library order

    private func bundle(id: Int, title: String) -> BundleDTO {
        let base = bundle()
        return BundleDTO(
            episode: EpisodeDTO(
                id: id, sourceUrl: "u\(id)", youtubeId: "y\(id)", title: title, channel: "C",
                durationMs: 1000, thumbnailUrl: nil, audioPath: "episodes/\(id)/source.mp3",
                status: "ready", error: nil),
            chapters: [], sentences: [], hasAudio: true, hasLearningPack: false,
            learningExpressions: [])
    }

    // The library sorts by recency, so the episode visited last comes first — regardless
    // of the order they were added in.
    func testMostRecentlyVisitedComesFirst() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(id: 1, title: "first added"), localAudioPath: nil)
        _ = try store.saveBundle(bundle(id: 2, title: "second added"), localAudioPath: nil)

        store.markVisited(1)

        XCTAssertEqual(store.downloadedEpisodes().first?.title, "first added")
    }

    // An episode never opened falls back to when it was ADDED, so it sorts among the
    // visited ones rather than being buried below them or floated above them — which is
    // what a nil-at-one-end sort in the fetch would have done.
    func testNeverOpenedEpisodesSortByWhenTheyWereAdded() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(id: 1, title: "old"), localAudioPath: nil)
        store.markVisited(1)
        // Added after the visit above, and never opened: it is still the more recent
        // thing to have happened, so it belongs on top.
        _ = try store.saveBundle(bundle(id: 2, title: "added later, unopened"), localAudioPath: nil)

        XCTAssertEqual(store.downloadedEpisodes().map(\.title), ["added later, unopened", "old"])
    }

    // Visiting again re-sorts. Two visits in a row must order by the LAST one.
    func testVisitingAgainMovesItBackToTheTop() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(id: 1, title: "one"), localAudioPath: nil)
        _ = try store.saveBundle(bundle(id: 2, title: "two"), localAudioPath: nil)

        store.markVisited(1)
        store.markVisited(2)
        XCTAssertEqual(store.downloadedEpisodes().first?.title, "two")

        store.markVisited(1)
        XCTAssertEqual(store.downloadedEpisodes().first?.title, "one")
    }

    // Where you were and when you were last here are different facts: opening an episode
    // must not claim you had listened to any of it.
    func testMarkingAVisitDoesNotInventAPlaybackPosition() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(id: 1, title: "one"), localAudioPath: nil)
        store.savePlaybackPosition(42_000, for: 1)
        store.markVisited(1)
        XCTAssertEqual(store.playbackPosition(for: 1), 42_000, "the saved position must survive a visit")
    }

    func testSaveAndReadBundle() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: "audio/1.mp3")
        XCTAssertEqual(store.sentences(for: 1).map(\.sourceText), ["Hi", "Bye"])
        XCTAssertEqual(store.chapters(for: 1).count, 1)
        XCTAssertEqual(store.downloadedEpisodes().first?.title, "T")
        XCTAssertEqual(store.localAudioPath(for: 1), "audio/1.mp3")
        // The bundle still SHIPS batch-extracted expressions; the store no longer keeps
        // them, so a downloaded episode arrives with transcript and chapters and no cards.
        XCTAssertTrue(store.learningExpressions(for: 1).isEmpty)
    }

    func testSaveBundleUpsertsReplacingSentences() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: nil)
        var updated = bundle()
        updated = BundleDTO(episode: updated.episode, chapters: updated.chapters,
                            sentences: [updated.sentences[0]], hasAudio: true)
        _ = try store.saveBundle(updated, localAudioPath: nil)
        XCTAssertEqual(store.sentences(for: 1).count, 1)  // replaced, not duplicated
    }

    func testRecordingsLifecycle() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: nil)
        let r1 = try store.addRecording(episodeId: 1, sentenceId: 10, localFilePath: "rec/a.m4a")
        _ = try store.addRecording(episodeId: 1, sentenceId: 10, localFilePath: "rec/b.m4a")
        XCTAssertEqual(store.recordings(sentenceId: 10).count, 2)
        try store.markBest(recordingId: r1.persistentModelID)
        XCTAssertEqual(store.recordings(sentenceId: 10).filter(\.isBest).count, 1)
        try store.setFeedback(recordingId: r1.persistentModelID, feedback: "great rhythm")
        XCTAssertTrue(store.recordings(sentenceId: 10).contains { $0.feedback == "great rhythm" })
    }

    func testInsightPersistsWithSourceAnchor() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: nil)

        let insight = try store.addInsight(
            episodeId: 1,
            title: "A useful claim",
            body: "The speaker assumes coordination is the bottleneck.",
            sourceText: "Hi",
            startMs: 0,
            endMs: 500
        )

        XCTAssertEqual(insight.episodeId, 1)
        XCTAssertEqual(insight.sourceText, "Hi")
        XCTAssertEqual(insight.startMs, 0)
        XCTAssertEqual(insight.endMs, 500)
    }

    func testExamplePracticePersistsItsEvaluation() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: nil)

        _ = try store.addExamplePractice(
            episodeId: 1, expressionId: 1, localFilePath: "practice/1.wav",
            overall: 86, clarity: 88, stressRhythm: 82, completeness: 90,
            advice: "注意 how 的重音。")

        let result = store.examplePractices(episodeId: 1, expressionId: 1).first
        XCTAssertEqual(result?.overall, 86)
        XCTAssertEqual(result?.clarity, 88)
        XCTAssertEqual(result?.stressRhythm, 82)
        XCTAssertEqual(result?.completeness, 90)
        XCTAssertEqual(result?.advice, "注意 how 的重音。")
    }

    private func manualNote(text: String = "Hi") -> LearningExpressionDTO {
        LearningExpressionDTO(
            id: 0, text: text, kind: .phrase, type: .syntax, chinese: "\u{6253}\u{62db}\u{547c}",
            pronunciation: nil, example: "Hi", exampleChinese: "\u{55e8}",
            whyHard: "\u{6d4b}\u{8bd5}\u{7528}")
    }

    func testManualNoteSurvivesABundleRedownload() throws {
        // The learner asked for this note and nothing can regenerate it, so a
        // resync must not take it away.
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: nil)
        try store.addManualExpression(
            episodeId: 1, sentenceId: 10, expression: manualNote(), request: "\u{53ea}\u{8bb2}\u{65f6}\u{6001}")

        _ = try store.saveBundle(bundle(), localAudioPath: nil)

        let stored = store.learningExpressions(for: 1)
        let manual = stored.filter { $0.source == "manual" }
        XCTAssertEqual(manual.count, 1)
        XCTAssertEqual(manual.first?.text, "Hi")
        XCTAssertEqual(manual.first?.request, "\u{53ea}\u{8bb2}\u{65f6}\u{6001}")
        // And nothing else arrived with it: the bundle's batch-extracted row is dropped on
        // the way in, so a redownload cannot bury the learner's own note under it.
        XCTAssertTrue(stored.filter { $0.source == "auto" }.isEmpty)
    }

    func testManualNoteIsAnchoredBySearchingTheSentence() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: nil)

        try store.addManualExpression(
            episodeId: 1, sentenceId: 10, expression: manualNote(text: "Hi"), request: nil)

        let manual = store.learningExpressions(for: 1).first { $0.source == "manual" }
        XCTAssertEqual(manual?.occurrences.map(\.startOffset), [0])
        XCTAssertEqual(manual?.occurrences.map(\.endOffset), [2])
    }

    // The caller's idea of "the current line" comes from the playback position, while a
    // saved word comes from whatever the teacher was discussing. In reading those are
    // routinely different lines — you scroll ahead of the audio — and a strict match meant
    // the card saved with no occurrence, so nothing was highlighted.
    func testAWordFromAnotherLineIsStillHighlighted() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: nil)

        // "Bye" lives in sentence 11, but the position says 10.
        try store.addManualExpression(
            episodeId: 1, sentenceId: 10, expression: manualNote(text: "Bye"), request: nil)

        let manual = store.learningExpressions(for: 1).first { $0.source == "manual" }
        XCTAssertEqual(manual?.occurrences.map(\.sentenceId), [11],
                       "the highlight belongs on the line the word is actually in")
    }

    // The named sentence is tried first, so a word appearing in several lines highlights
    // the one being discussed rather than the earliest in the episode.
    func testTheNamedSentenceWinsWhenTheWordAppearsTwice() throws {
        let store = try makeStore()
        let twice = BundleDTO(
            episode: EpisodeDTO(id: 1, sourceUrl: "u", youtubeId: "y", title: "T", channel: "C",
                                durationMs: 1000, thumbnailUrl: nil, audioPath: "a.mp3",
                                status: "ready", error: nil),
            chapters: [], sentences: [
                SentenceDTO(id: 10, episodeId: 1, chapterId: nil, position: 0, startMs: 0, endMs: 500,
                            speaker: nil, sourceText: "Hi there", chinese: "嗨"),
                SentenceDTO(id: 11, episodeId: 1, chapterId: nil, position: 1, startMs: 500, endMs: 1000,
                            speaker: nil, sourceText: "Hi again", chinese: "又见"),
            ], hasAudio: true, hasLearningPack: false, learningExpressions: [])
        _ = try store.saveBundle(twice, localAudioPath: nil)

        try store.addManualExpression(
            episodeId: 1, sentenceId: 11, expression: manualNote(text: "Hi"), request: nil)

        let manual = store.learningExpressions(for: 1).first { $0.source == "manual" }
        XCTAssertEqual(manual?.occurrences.map(\.sentenceId), [11])
    }

    func testManualNoteAbsentFromTheEpisodeGetsNoHighlight() throws {
        // Better no highlight than one pointing at unrelated words.
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: nil)

        try store.addManualExpression(
            episodeId: 1, sentenceId: 10, expression: manualNote(text: "absent phrase"), request: nil)

        let manual = store.learningExpressions(for: 1).first { $0.source == "manual" }
        XCTAssertEqual(manual?.text, "absent phrase")
        XCTAssertEqual(manual?.occurrences.isEmpty, true)
    }

    func testManualNotesUseNegativeIdsSoTheyCannotCollideWithBackendRows() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: nil)

        try store.addManualExpression(episodeId: 1, sentenceId: 10, expression: manualNote(), request: nil)
        try store.addManualExpression(episodeId: 1, sentenceId: 11, expression: manualNote(text: "Bye"), request: nil)

        let ids = store.learningExpressions(for: 1).filter { $0.source == "manual" }.map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.allSatisfy { $0 < 0 }, "got \(ids)")
        XCTAssertEqual(Set(ids).count, 2, "ids must be distinct")
    }

    func testUnsyncedManualExpressionsListsOnlyUnarchivedNotes() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: nil)
        try store.addManualExpression(episodeId: 1, sentenceId: 10, expression: manualNote(), request: nil)

        XCTAssertEqual(store.unsyncedManualExpressions(for: 1).count, 1)
        XCTAssertEqual(store.unsyncedManualExpressions(for: 1).first?.remoteId, nil)
    }
}

@MainActor
final class ParagraphNoteStoreTests: XCTestCase {
    private func store() throws -> EpisodeStore { try EpisodeStore(inMemory: true) }

    private func bundle() -> BundleDTO {
        BundleDTO(
            episode: EpisodeDTO(id: 1, sourceUrl: "u", youtubeId: "y", title: "T", channel: "C",
                                durationMs: 1000, thumbnailUrl: nil, audioPath: "a.mp3",
                                status: "ready", error: nil),
            chapters: [ChapterDTO(id: 1, title: "Intro", summary: "s", startMs: 0, endMs: 1000)],
            sentences: [
                SentenceDTO(id: 10, episodeId: 1, chapterId: 1, position: 0, startMs: 0, endMs: 500,
                            speaker: nil, sourceText: "Hi there", chinese: "嗨"),
                SentenceDTO(id: 11, episodeId: 1, chapterId: 1, position: 1, startMs: 500, endMs: 1000,
                            speaker: nil, sourceText: "Bye now", chinese: "拜"),
            ],
            hasAudio: true, hasLearningPack: false, learningExpressions: [])
    }

    func testNoteIsStoredAgainstItsParagraph() throws {
        let s = try store()
        _ = try s.saveBundle(bundle(), localAudioPath: nil)

        try s.addParagraphNote(
            episodeId: 1, sentenceId: 10,
            question: "\u{8fd9}\u{6bb5}\u{5728}\u{8bb2}\u{4ec0}\u{4e48}", answer: "\u{5728}\u{8bb2}\u{6253}\u{62db}\u{547c}")

        let notes = s.paragraphNotes(for: 1)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].sentenceId, 10)
        XCTAssertEqual(notes[0].answer, "\u{5728}\u{8bb2}\u{6253}\u{62db}\u{547c}")
    }

    func testNoteIDsAreNegativeAndDistinct() throws {
        // Backend ids are positive, so a local note can never collide with one that
        // arrives in a bundle.
        let s = try store()
        _ = try s.saveBundle(bundle(), localAudioPath: nil)

        try s.addParagraphNote(episodeId: 1, sentenceId: 10, question: "q1", answer: "a1")
        try s.addParagraphNote(episodeId: 1, sentenceId: 10, question: "q2", answer: "a2")

        let ids = s.paragraphNotes(for: 1).map(\.noteId)
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.allSatisfy { $0 < 0 }, "got \(ids)")
        XCTAssertEqual(Set(ids).count, 2)
    }

    func testOneParagraphHoldsSeveralNotesInAskedOrder() throws {
        let s = try store()
        _ = try s.saveBundle(bundle(), localAudioPath: nil)

        try s.addParagraphNote(episodeId: 1, sentenceId: 10, question: "first", answer: "a")
        try s.addParagraphNote(episodeId: 1, sentenceId: 10, question: "second", answer: "b")
        try s.addParagraphNote(episodeId: 1, sentenceId: 11, question: "elsewhere", answer: "c")

        let onTen = s.paragraphNotes(for: 1).filter { $0.sentenceId == 10 }
        XCTAssertEqual(onTen.map(\.question), ["first", "second"])
    }

    func testDeletingANoteRemovesOnlyThatOne() throws {
        let s = try store()
        _ = try s.saveBundle(bundle(), localAudioPath: nil)
        try s.addParagraphNote(episodeId: 1, sentenceId: 10, question: "keep", answer: "a")
        let doomed = try s.addParagraphNote(episodeId: 1, sentenceId: 10, question: "drop", answer: "b")

        try s.deleteParagraphNote(doomed.noteId)

        XCTAssertEqual(s.paragraphNotes(for: 1).map(\.question), ["keep"])
    }

    func testDeletingAManualExpressionRemovesItAndItsHighlight() throws {
        let s = try store()
        _ = try s.saveBundle(bundle(), localAudioPath: nil)
        let dto = LearningExpressionDTO(
            id: 0, text: "Hi", kind: .phrase, type: .idiom, chinese: "\u{55e8}",
            pronunciation: nil, example: "Hi there", exampleChinese: "\u{55e8}")
        let note = try s.addManualExpression(
            episodeId: 1, sentenceId: 10, expression: dto, request: nil)
        let id = try XCTUnwrap(note?.expressionId)
        XCTAssertEqual(s.learningExpressions(for: 1).filter { $0.source == "manual" }.count, 1)

        try s.deleteManualExpression(id)

        XCTAssertTrue(s.learningExpressions(for: 1).filter { $0.source == "manual" }.isEmpty)
    }

    // "Clear" means clear what the learner made. Automatic rows survive for the same
    // reason a single one cannot be deleted: a reprocess rewrites them, so removing one is
    // a promise the next sync would break.
    func testClearingRemovesOnlyWhatTheLearnerMade() throws {
        let s = try store()
        var withAuto = bundle()
        // The bundle's own batch-extracted row is dropped on the way in, so there is no
        // longer an "auto" half to protect — clearing removes everything there is.
        _ = try s.saveBundle(withAuto, localAudioPath: nil)
        let dto = LearningExpressionDTO(
            id: 0, text: "Hi", kind: .phrase, type: .idiom, chinese: "\u{55e8}",
            pronunciation: nil, example: "Hi there", exampleChinese: "\u{55e8}")
        _ = try s.addManualExpression(episodeId: 1, sentenceId: 10, expression: dto, request: nil)
        try s.addParagraphNote(episodeId: 1, sentenceId: 10, question: "q", answer: "a")

        let removed = try s.clearManualNotes(for: 1)

        XCTAssertEqual(removed, 2, "one expression and one note")
        XCTAssertTrue(s.learningExpressions(for: 1).isEmpty)
        XCTAssertTrue(s.paragraphNotes(for: 1).isEmpty)
    }

    // A device that ran the old build still holds hundreds of batch-extracted rows per
    // episode. Nothing regenerates them now, so they are cleared once on launch — the
    // learner's own notes are untouched.
    func testPurgingRemovesLegacyAutoExpressionsOnly() throws {
        let s = try store()
        _ = try s.saveBundle(bundle(), localAudioPath: nil)
        // Inserted the way the OLD build did, since saveBundle no longer accepts them.
        let legacy = StoredLearningExpression(
            expressionId: 900, episodeId: 1, text: "legacy", kind: "word", type: "word",
            chinese: "\u{65e7}", pronunciation: nil, example: "x", exampleChinese: "y",
            source: "auto")
        s.context.insert(legacy)
        let dto = LearningExpressionDTO(
            id: 0, text: "Hi", kind: .phrase, type: .idiom, chinese: "\u{55e8}",
            pronunciation: nil, example: "Hi there", exampleChinese: "\u{55e8}")
        _ = try s.addManualExpression(episodeId: 1, sentenceId: 10, expression: dto, request: nil)

        let removed = try s.purgeAutoExpressions()

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(s.learningExpressions(for: 1).map(\.text), ["Hi"],
                       "only the learner's own note survives")
        // Idempotent: a second launch has nothing left to do.
        XCTAssertEqual(try s.purgeAutoExpressions(), 0)
    }

    func testClearingAnEpisodeWithNothingToClearIsHarmless() throws {
        let s = try store()
        _ = try s.saveBundle(bundle(), localAudioPath: nil)
        XCTAssertEqual(try s.clearManualNotes(for: 1), 0)
        XCTAssertEqual(try s.clearManualNotes(for: 999), 0, "an unknown episode is not an error")
    }


    /// The round trip the transcript rows actually draw from: delete, re-read the
    /// store, rebuild the card index.
    ///
    /// Both deletes worked at the store layer and neither reached the screen. The
    /// note branch never rebuilt the index, and the expression branch was rebuilding
    /// from an init-time snapshot unioned with this sitting's additions — and since
    /// `learningExpressions` already returns the manual rows, a card made in an
    /// earlier sitting sat in the immutable half and came straight back.
    func testDeletedCardsLeaveTheRebuiltCardIndex() throws {
        let s = try store()
        _ = try s.saveBundle(bundle(), localAudioPath: nil)
        let dto = LearningExpressionDTO(
            id: 0, text: "Hi", kind: .phrase, type: .idiom, chinese: "\u{55e8}",
            pronunciation: nil, example: "Hi there", exampleChinese: "\u{55e8}")
        let expression = try XCTUnwrap(
            try s.addManualExpression(episodeId: 1, sentenceId: 10, expression: dto, request: nil))
        let note = try s.addParagraphNote(
            episodeId: 1, sentenceId: 10, question: "\u{4e3a}\u{4ec0}\u{4e48}", answer: "\u{56e0}\u{4e3a}")

        func rebuild() -> ParagraphCards.Index {
            ParagraphCards.Index(
                expressions: s.learningExpressions(for: 1),
                notes: s.paragraphNotes(for: 1).map {
                    (id: $0.noteId, sentenceId: $0.sentenceId, question: $0.question, answer: $0.answer)
                })
        }

        // This bundle carries no automatic expressions, so the paragraph holds
        // exactly the two hand-made cards. Auto rows surviving a delete is pinned
        // by testAutoExpressionsCannotBeDeleted.
        XCTAssertEqual(rebuild().cards(for: 10).count, 2)

        try s.deleteParagraphNote(note.noteId)
        XCTAssertFalse(
            rebuild().cards(for: 10).contains { $0.id == "n\(note.noteId)" },
            "a deleted note must not survive the rebuild")

        try s.deleteManualExpression(expression.expressionId)
        XCTAssertFalse(
            rebuild().cards(for: 10).contains { $0.id == "e\(expression.expressionId)" },
            "a deleted manual expression must not come back from a stale snapshot")

        XCTAssertTrue(rebuild().cards(for: 10).isEmpty)
    }
}
