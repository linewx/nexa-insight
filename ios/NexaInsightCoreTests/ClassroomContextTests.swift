import XCTest
@testable import NexaInsightCore

private func s(_ id: Int, _ start: Int, _ end: Int, _ en: String, _ zh: String) -> SentenceDTO {
    SentenceDTO(id: id, episodeId: 1, chapterId: nil, position: id, startMs: start, endMs: end, speaker: "Host", sourceText: en, chinese: zh)
}

final class ClassroomContextTests: XCTestCase {
    func testContextTextFormat() {
        let line = contextText([s(0, 1500, 3000, "Hello", "你好")])
        XCTAssertEqual(line, "[1.5s] Host: Hello / 你好")
    }

    // The highlighted line must be marked in the window, or "explain this
    // sentence" makes the teacher guess among the surrounding lines.
    func testContextTextMarksCurrentLineOnly() {
        let window = [s(0, 0, 1000, "A", "甲"), s(1, 2000, 3000, "B", "乙"), s(2, 4000, 5000, "C", "丙")]
        let text = contextText(window, currentId: 1)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[1].hasSuffix("<<< CURRENT LINE"))
        XCTAssertFalse(lines[0].contains("CURRENT LINE"))
        XCTAssertFalse(lines[2].contains("CURRENT LINE"))
    }

    // The marked line must be the one activeSentence picks — the same rule the
    // on-screen highlight uses — so context and highlight can't disagree.
    func testClassroomContextMarksTheHighlightedLine() {
        let sentences = [s(0, 0, 1000, "A", "甲"), s(1, 2000, 3000, "B", "乙"), s(2, 4000, 5000, "C", "丙")]
        // 2600ms sits inside line B, which is what the UI highlights.
        let text = classroomContext(episodeTitle: "T", channel: "C", chapters: [], sentences: sentences, atMs: 2600, radius: 6)
        XCTAssertTrue(text.contains("B / 乙    <<< CURRENT LINE"))
        XCTAssertFalse(text.contains("A / 甲    <<< CURRENT LINE"))
        XCTAssertTrue(text.contains("THE CURRENT LINE"))
        // The dedicated field names the same line.
        XCTAssertTrue(text.contains("[2.0s] B / 乙"))
    }

    func testClassroomContextIncludesMapChapterWindow() {
        let chapters = [
            ChapterDTO(id: 1, title: "Intro", summary: "opening", startMs: 0, endMs: 2000),
            ChapterDTO(id: 2, title: "Core", summary: "the meat", startMs: 2000, endMs: 6000),
        ]
        let sentences = [s(0, 0, 1000, "A", "甲"), s(1, 2500, 3500, "B", "乙"), s(2, 4000, 5000, "C", "丙")]
        let text = classroomContext(episodeTitle: "T", channel: "C", chapters: chapters, sentences: sentences, atMs: 2600, radius: 1)
        XCTAssertTrue(text.contains("Episode: T · C"))
        XCTAssertTrue(text.contains("Episode map:"))
        XCTAssertTrue(text.contains("Intro"))
        XCTAssertTrue(text.contains("Current chapter:\nCore: the meat"))
        XCTAssertTrue(text.contains("Current transcript window"))
        XCTAssertTrue(text.contains("B / 乙"))
    }

    func testChapterFallbackWhenBetweenChapters() {
        let chapters = [ChapterDTO(id: 1, title: "Only", summary: "s", startMs: 0, endMs: 1000)]
        let text = classroomContext(episodeTitle: nil, channel: nil, chapters: chapters, sentences: [s(0, 0, 500, "A", "甲")], atMs: 5000, radius: 1)
        XCTAssertTrue(text.contains("Only"))
        XCTAssertTrue(text.contains("Untitled"))
    }
}
