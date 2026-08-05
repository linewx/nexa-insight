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

    func testSavedExpressionKeepsItsStudyFields() throws {
        // A downloaded episode reads from this store, so anything dropped here is
        // invisible in the app no matter what the backend produced.
        let store = try makeStore()
        let expression = LearningExpressionDTO(
            id: 2, text: "kind of", kind: .phrase, type: .reduction, chinese: "有点儿",
            pronunciation: nil, example: "I kind of like it.", exampleChinese: "我有点喜欢。",
            heardAs: "kinda", restored: "kind of", whyHard: "弱读脱落。",
            whenToUse: nil, commonMistake: "a little bit of", formality: "spoken",
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

    func testSaveAndReadBundle() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: "audio/1.mp3")
        XCTAssertEqual(store.sentences(for: 1).map(\.sourceText), ["Hi", "Bye"])
        XCTAssertEqual(store.chapters(for: 1).count, 1)
        XCTAssertEqual(store.downloadedEpisodes().first?.title, "T")
        XCTAssertEqual(store.localAudioPath(for: 1), "audio/1.mp3")
        XCTAssertEqual(store.learningExpressions(for: 1).first?.text, "Hello")
        XCTAssertEqual(store.learningExpressions(for: 1).first?.occurrences.first?.sentenceId, 10)
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
        // The auto row from the bundle is still replaced, not accumulated.
        XCTAssertEqual(stored.filter { $0.source == "auto" }.count, 1)
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

    func testManualNoteAbsentFromItsSentenceGetsNoHighlight() throws {
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

    func testAutoExpressionsCannotBeDeleted() throws {
        // A reprocess replaces them, so a delete would not stay deleted.
        let s = try store()
        var withAuto = bundle()
        withAuto = BundleDTO(
            episode: withAuto.episode, chapters: withAuto.chapters, sentences: withAuto.sentences,
            hasAudio: true, hasLearningPack: true,
            learningExpressions: [
                LearningExpressionDTO(
                    id: 5, text: "Hi", kind: .phrase, chinese: "\u{55e8}", pronunciation: nil,
                    example: "Hi there", exampleChinese: "\u{55e8}",
                    occurrences: [ExpressionOccurrenceDTO(sentenceId: 10, startOffset: 0, endOffset: 2)])
            ])
        _ = try s.saveBundle(withAuto, localAudioPath: nil)

        try s.deleteManualExpression(5)

        XCTAssertEqual(s.learningExpressions(for: 1).count, 1, "an auto row must survive")
    }
}
