import Foundation

/// Whether the learner is working with their ears or their eyes.
///
/// The two modes were once mutually exclusive VIEWS, which was wrong: entering
/// reading removed tap-to-seek and the per-sentence controls, and the reason you
/// open a definition is usually to hear the line again. They were merged into one
/// annotated view.
///
/// They are separate again, but along a different seam. It is not *what the
/// transcript looks like* that differs — both render the same annotated text —
/// it is *which controls a sentence offers*:
///
/// - `.listening` keeps every playback control: replay, loop, shadow, speed,
///   previous/next. You are grinding one line until you can hear it.
/// - `.reading` keeps only what reading needs: play this one sentence, and take a
///   note. Looping and speed belong to ear work, and putting six controls under a
///   line you are reading is noise.
///
/// Notes are a reading affordance, so they appear only there.
enum StudyMode: String, Hashable, CaseIterable {
    case listening
    case reading

    var label: String {
        switch self {
        case .listening: "\u{7cbe}\u{542c}"
        case .reading: "\u{7cbe}\u{8bfb}"
        }
    }

    var icon: String {
        switch self {
        case .listening: "headphones"
        case .reading: "text.book.closed"
        }
    }

    /// The mode the toggle moves to.
    var toggled: StudyMode {
        self == .listening ? .reading : .listening
    }

    /// Whether a selected sentence offers the full set of playback controls.
    /// True everywhere now. With 精听 gone `mode` is always `.reading`, and leaving this as
    /// `self == .listening` would have silently taken the dock, hold-to-talk, shadowing, looping
    /// and speed with it — the practice, not just the mode.
    ///
    /// Kept as a property rather than deleted: it is read in six places, and removing the concept
    /// is a separate change from removing the second mode.
    var showsPlaybackControls: Bool { true }

}
