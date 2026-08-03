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
}
