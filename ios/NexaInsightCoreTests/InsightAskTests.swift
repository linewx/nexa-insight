import XCTest
@testable import NexaInsightCore

// Asking a question ON the 洞察 page.
//
// The machinery is the transcript's — same session, same ReadingAsk, same turn observer — and the
// two things that differ are the two things that can silently go wrong: what the teacher is told
// to answer about, and which conversation a follow-up continues.
final class InsightAskTests: XCTestCase {
    private let page = InsightDTO(
        thesis: "AI 监管正被恐惧叙事劫持，而非真正保障安全",
        claims: [
            InsightClaimDTO(claim: "Anthropic 以制造恐慌推动有利于自身的监管",
                            evidence: "把 50% 失业预测包装成媒体运动",
                            dispute: "弗里伯格认为实验室领导者确实预见到灾难风险",
                            atMs: 2_480_000),
        ],
        facts: [
            InsightFactDTO(fact: "英国 AI 安全研究所批评勒索研究是人为设计", sourced: false, atMs: 1_200_000),
            InsightFactDTO(fact: "得州与宾州签署行政命令限制数据中心", sourced: true, atMs: 3_000_000),
        ],
        takeaways: ["开源不是监管漏洞，而是制衡权力的机制"])

    func testTheTeacherIsGivenThePageNotATranscriptWindow() {
        // The reader is looking at claims and figures: "this point" means something on screen. A
        // window of transcript around some timestamp would answer a different question from the
        // one asked.
        let context = insightContext(episodeTitle: "Dario Defends Himself", channel: "All-In",
                                     insight: page)
        XCTAssertTrue(context.contains("INSIGHT PAGE"), "the teacher must know where the learner is")
        XCTAssertTrue(context.contains(page.thesis))
        XCTAssertTrue(context.contains("Anthropic 以制造恐慌推动有利于自身的监管"))
        // Evidence and dispute travel too: a question is often ABOUT the disagreement, and a
        // teacher given only the claims would flatten it back out.
        XCTAssertTrue(context.contains("依据: 把 50% 失业预测包装成媒体运动"))
        XCTAssertTrue(context.contains("分歧: 弗里伯格认为实验室领导者确实预见到灾难风险"))
    }

    func testAnUnsourcedFigureStaysMarkedInTheContext() {
        // Asked "is that true", the teacher should know the page already flagged it rather than
        // asserting it afresh.
        let context = insightContext(episodeTitle: nil, channel: nil, insight: page)
        XCTAssertTrue(context.contains("英国 AI 安全研究所批评勒索研究是人为设计（无出处）"))
        XCTAssertTrue(context.contains("得州与宾州签署行政命令限制数据中心"))
        XCTAssertFalse(context.contains("得州与宾州签署行政命令限制数据中心（无出处）"),
                       "a sourced fact must not be marked")
    }

    func testThePageAnchorCannotCollideWithASentence() {
        // The "different paragraph closes the previous conversation" rule keys off sentenceId, so
        // page-level follow-ups must share one anchor — and it must not match any real line, or a
        // transcript row would render the page's conversation under itself.
        XCTAssertEqual(ReadingAsk.insightPageId, -1)
        XCTAssertLessThan(ReadingAsk.insightPageId, 0, "no sentence id is negative")

        var ask = ReadingAsk(sentenceId: ReadingAsk.insightPageId, atMs: 0)
        ask.heard("谁反驳了这个观点")
        ask.answered("弗里伯格提出了钢人式辩护")
        ask.finished()
        XCTAssertTrue(ask.acceptsFollowUp, "a second question about the page continues the same talk")
        XCTAssertEqual(ask.sentenceId, ReadingAsk.insightPageId)
    }

    func testAskingWithoutClaimsStillProducesUsableContext() {
        // A page can be nothing but a thesis: every list is optional, and takeaways are
        // deliberately empty when the model could only restate.
        let context = insightContext(episodeTitle: "T", channel: nil,
                                     insight: InsightDTO(thesis: "这集讨论监管与竞争"))
        XCTAssertTrue(context.contains("这集讨论监管与竞争"))
        XCTAssertTrue(context.contains("INSIGHT PAGE"))
    }
}

// The ask bar's five behaviours. Phase transitions are testable directly; the gesture and haptic
// wiring is checked against the source, since neither can be driven on macOS.
extension InsightAskTests {
    func testPressingWhileTheTeacherTalksIsAnInterrupt() {
        // `acceptsFollowUp` is false during a turn, and on the transcript that is right — the
        // session must not open a second conversation. But it made the button a no-op through a
        // long answer, which reads as broken. The floor reducer already grants `.user`
        // unconditionally, so the controller was always willing; only the view refused.
        var ask = ReadingAsk(sentenceId: ReadingAsk.insightPageId, atMs: 0)
        ask.heard("谁反驳了这个观点")
        ask.answered("弗里伯格提出了钢人式辩护")
        XCTAssertTrue(ask.interrupts, "an answer in progress can be interrupted")
        XCTAssertFalse(ask.acceptsFollowUp, "which is NOT the same as accepting a follow-up")

        ask.interrupted()
        XCTAssertEqual(ask.phase, .recording, "the mic opens immediately")
    }

    func testCancellingLeavesNoTurnBehind() {
        // Dragged up and released: nothing was asked, so the conversation must not gain a turn.
        var ask = ReadingAsk(sentenceId: ReadingAsk.insightPageId, atMs: 0)
        XCTAssertEqual(ask.phase, .recording)
        ask.cancelled()
        XCTAssertEqual(ask.phase, .idle)
        XCTAssertTrue(ask.isEmpty, "an abandoned question is not a turn")
        XCTAssertTrue(ask.acceptsFollowUp, "and the next press starts cleanly")
    }

    func testTheBarNamesEveryStateAndTheHapticsAreDistinct() throws {
        let source = try String(contentsOfFile: "NexaInsight/Views/InsightView.swift", encoding: .utf8)
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        // A control that looks identical in every state cannot tell you what to do next, and the
        // interrupt in particular is undiscoverable unless the bar says so.
        // `.idle` and `nil` share a branch — nothing asked yet and a finished turn both mean
        // "ask about this page" — so match the state name rather than an exact case spelling.
        for phase in [".recording", ".waiting", ".answering", ".misheard", ".idle"] {
            XCTAssertTrue(code.contains("case \(phase)"), "status must cover \(phase)")
        }
        // The line shows the CONVERSATION first: a label reading "老师正在回答" tells you less
        // than the answer's own words. Instructions printed on a button you are already holding
        // are describing what you just did.
        XCTAssertTrue(code.contains("ask?.turns.last"), "the last turn is what the line shows")
        XCTAssertTrue(code.contains("statusDotColor"), "and a dot carries what content cannot")
        // The interrupt has to LOOK different from a fresh question, or the one thing the learner
        // cannot discover — that pressing during an answer takes the floor — stays hidden. Deleting
        // the glyph left every other assertion passing.
        XCTAssertTrue(code.contains("hand.raised.fill"), "answering shows an interrupt glyph")
        // Matched as the ESCAPE, because that is what the file contains: asserting on the
        // characters compiles 打断 into the test and searches a source that spells it
        // \u{6253}\u{65ad}, so it failed on correct code.
        XCTAssertTrue(code.contains(#"\u{6253}\u{65ad}"#), "and the capsule says 打断")
        XCTAssertTrue(code.contains("cancelThreshold"), "upward drag arms cancelling")
        // Three weights, each meaning something: medium on press, light on arming or disarming,
        // rigid on cancel — so cancelling never feels like a question went out.
        XCTAssertTrue(code.contains("UIImpactFeedbackGenerator(style: .medium)"))
        XCTAssertTrue(code.contains("UIImpactFeedbackGenerator(style: .light)"))
        XCTAssertTrue(code.contains("UIImpactFeedbackGenerator(style: .rigid)"))
    }

    func testTheExitSwipeCannotFireFromTheCapsuleOrMidTurn() throws {
        let source = try String(contentsOfFile: "NexaInsight/Views/InsightView.swift", encoding: .utf8)
        // Any drag on the capsule starts recording, so a sideways flick off the button would send
        // a question AND leave the page.
        XCTAssertTrue(source.contains("guard value.startLocation.y < pageHeight - Self.askBarZone"))
        // And leaving mid-turn would strand the answer on a page nobody is looking at.
        XCTAssertTrue(source.contains("guard ask == nil || ask?.phase == .idle else { return }"))
        // Simultaneous, or a five-minute read would not scroll.
        XCTAssertTrue(source.contains(".simultaneousGesture("))
    }
}
