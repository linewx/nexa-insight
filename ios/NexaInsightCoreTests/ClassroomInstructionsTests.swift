import XCTest
@testable import NexaInsightCore

final class ClassroomInstructionsTests: XCTestCase {
    func testStableInstructionsStripsBakedContext() {
        let full = "STYLE AND RULES\n\nClassroom material:\nEpisode: X\nmap..."
        XCTAssertEqual(stableInstructions(full), "STYLE AND RULES")
    }

    func testComposeAttachesSingleAuthoritativeWindow() {
        let full = "PREFIX\n\nCurrent podcast context:\nOLD WINDOW"
        let composed = composeInstructions(full, freshContext: "NEW WINDOW")
        XCTAssertTrue(composed.hasPrefix("PREFIX"))
        XCTAssertTrue(composed.contains("NEW WINDOW"))
        XCTAssertFalse(composed.contains("OLD WINDOW"))
        XCTAssertTrue(composed.contains("ONLY current context"))
    }

    func testRealtimeToolsAdvertiseOmniDirectSet() {
        let names = realtimePlaybackTools.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), ["resume_playback", "pause_playback", "previous_sentence",
                                    "next_sentence", "seek_to_timestamp",
                                    "save_note", "save_answer"])
    }

    // A tool the model is not told about is a tool it cannot call, so the schema is as
    // load-bearing as the instructions. These two carry TEXT, which is what safeArgs had
    // to learn to parse.
    func testSaveToolsAreAdvertisedWithTheirRequiredFields() {
        func tool(_ name: String) -> [String: Any]? {
            realtimePlaybackTools.first { ($0["name"] as? String) == name }
        }
        func required(_ name: String) -> Set<String> {
            let params = tool(name)?["parameters"] as? [String: Any]
            return Set((params?["required"] as? [String]) ?? [])
        }
        XCTAssertEqual(required("save_note"), ["text", "meaning"])
        XCTAssertEqual(required("save_answer"), ["question", "answer"])

        // The surface-form rule has to reach the model: the highlight is found by
        // searching the line, so a dictionary lemma silently loses it.
        let params = tool("save_note")?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        func described(_ key: String) -> String {
            (properties?[key] as? [String: Any])?["description"] as? String ?? ""
        }
        XCTAssertTrue(described("text").contains("EXACTLY as it appears"))

        // The four fields the rebuilt card draws on. Asked for by name because a field the
        // model is not told about is a field the card renders empty forever.
        for key in ["sense_group", "usage", "literal", "note_type"] {
            XCTAssertFalse(described(key).isEmpty, "save_note must ask for \(key)")
        }
        // Verbatim, because an invented example is discarded — say so up front rather than
        // silently dropping the model's work.
        XCTAssertTrue(described("example").contains("VERBATIM"))
        XCTAssertTrue(described("sense_group").contains("VERBATIM"))
        // The non-answer that the old when_to_use kept producing is named as one.
        XCTAssertTrue(described("usage").contains("\u{65e5}\u{5e38}\u{5bf9}\u{8bdd}\u{4e2d}\u{4f7f}\u{7528}"))
        // The kinds are sorted by what goes wrong, and `reference` is the invisible case:
        // every word known, the reading still wrong.
        XCTAssertTrue(described("note_type").contains("wrong here"))
    }

    // The instruction that decides whether any of this works: the model must CALL the
    // tool rather than claim it did. Playback needed the same wording.
    func testTheTeacherIsToldToCallRatherThanClaim() {
        let text = baseClassroomInstructions(material: "M")
        XCTAssertTrue(text.contains("SAVING NOTES"))
        XCTAssertTrue(text.contains("WITHOUT calling save_note"))
        // One request can be several cards. Asked to analyse a passage, the teacher used to
        // save the first item and stop — and the parser was dropping the rest anyway.
        XCTAssertTrue(text.contains("ONE REQUEST CAN BE SEVERAL CARDS"))
        // And not to save unasked — the whole point of making it explicit.
        XCTAssertTrue(text.contains("Only when ASKED"))
    }

    func testBaseInstructionsAppendMaterial() {
        let text = baseClassroomInstructions(material: "MATERIAL_XYZ")
        XCTAssertTrue(text.contains("MATERIAL_XYZ"))
    }

    // MARK: - Card guidance per material

    // Tested against a real teaching vlog before this existed: asked which misunderstanding
    // each word prevents, the model forced plainly-taught vocabulary (ripe / underripe /
    // overripe) into "reference" and invented literal readings ("在成熟之下") to fill the
    // field. Nothing was hidden from the learner; it was being explained.
    func testTeachingMaterialIsToldNotToInventMisreadings() {
        let text = baseClassroomInstructions(material: "M", materialKind: "teaching")
        XCTAssertTrue(text.contains("TEACHES English"))
        XCTAssertTrue(text.contains("leave `literal` empty"))
        XCTAssertTrue(text.contains("CONTRAST SET"))
        // The set is one card, and its quote must come from ONE member's sentence — a
        // stitched quote is a sentence nobody said, and verified(against:) discards it.
        XCTAssertTrue(text.contains("stitched quote"))
    }

    // Native speech fails a learner the other way round: they follow most of it and come off
    // the rails in specific places, usually without noticing.
    func testNativeMaterialKeepsTheMisunderstandingFraming() {
        let text = baseClassroomInstructions(material: "M", materialKind: "native")
        XCTAssertTrue(text.contains("made for native speakers"))
        XCTAssertTrue(text.contains("the everyday sense is easy AND WRONG HERE"))
        XCTAssertFalse(text.contains("CONTRAST SET"), "teaching guidance must not leak")
    }

    // The default has to stay native: an episode imported before classification existed has
    // no material_kind at all, and native is the safer framing to guess.
    func testCardGuidanceDefaultsToNative() {
        XCTAssertEqual(baseClassroomInstructions(material: "M"),
                       baseClassroomInstructions(material: "M", materialKind: "native"))
        XCTAssertEqual(baseClassroomInstructions(material: "M", materialKind: "nonsense"),
                       baseClassroomInstructions(material: "M", materialKind: "native"))
    }

    // Reading asked "what is worth studying here" and got "好，我们来梳理一下…" with the
    // content deferred to a turn that never came. The learner held that paragraph
    // because they are stuck on it now, and a turn spent on preamble also leaves the
    // exchange with nothing to sediment.
    func testReadingIsToldToAnswerInTheSameTurn() {
        let composed = composeInstructions("PREFIX", freshContext: "WINDOW", scene: .reading)
        XCTAssertTrue(composed.contains("READING MODE"))
        XCTAssertTrue(composed.contains("THIS turn"))
        XCTAssertTrue(composed.contains("do not defer content"))
    }

    // Listening keeps the Socratic framing: thinking aloud while the podcast plays is
    // exactly where engaging before explaining is right.
    func testListeningScenesAreLeftAlone() {
        for scene in [ClassroomScene.selfStudy, .live] {
            let composed = composeInstructions("PREFIX", freshContext: "WINDOW", scene: scene)
            XCTAssertFalse(composed.contains("READING MODE"), "leaked into \(scene)")
        }
    }

    // The default has to stay the listening one: `updateContext` is called from paths
    // that predate scenes, and a wrong default would silently reshape 精听.
    func testDefaultSceneIsSelfStudy() {
        XCTAssertEqual(composeInstructions("P", freshContext: "W"),
                       composeInstructions("P", freshContext: "W", scene: .selfStudy))
    }

    // The reading guidance is appended, not substituted: the material window and the
    // "only current context" rule must survive it.
    func testReadingKeepsTheAuthoritativeWindow() {
        let composed = composeInstructions(
            "PREFIX\n\nCurrent podcast context:\nOLD", freshContext: "NEW", scene: .reading)
        XCTAssertTrue(composed.contains("NEW"))
        XCTAssertFalse(composed.contains("OLD"))
        XCTAssertTrue(composed.contains("ONLY current context"))
    }
}
