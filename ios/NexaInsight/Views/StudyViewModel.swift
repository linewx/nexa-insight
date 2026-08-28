import CoreGraphics
import Foundation

@MainActor
final class StudyViewModel: ObservableObject {
    @Published var following = true
    private var idleTask: Task<Void, Never>?

    func currentSentence(sentences: [SentenceDTO], cursorMs: Int) -> SentenceDTO? {
        activeSentence(sentences, cursorMs) ?? sentences.first
    }

    /// How far the CONTENT must move before the playing line counts as gone.
    ///
    /// Two wrong measures preceded this one. First, any 12pt drag flipped `following`, so the
    /// button appeared while the line was still plainly visible — "仅仅不在正中间而已". Then I
    /// measured finger travel, which made it never appear at all: a flick moves a finger
    /// 150-250pt and momentum carries the content several screens, so a 220pt FINGER threshold
    /// was never reached no matter how far the transcript actually went.
    ///
    /// Content offset is the right signal. About three rows — far enough that the line is off
    /// screen, close enough that a real flick trips it immediately.
    static let driftThreshold: CGFloat = 260

    /// Content offset when the transcript was last in sync, or nil before the first reading.
    private var anchorOffset: CGFloat?

    /// Whether the current content movement came from a finger. Distinguishes the learner
    /// scrolling away from the auto-scroll that follows the playing line — both move the content
    /// by large amounts, and only one means "reading elsewhere".
    private var userScrolling = false

    /// Accumulated vertical movement since the last time the transcript was in sync.
    private var drift: CGFloat = 0

    /// The learner dragged the transcript. Stops following only once they have moved far enough
    /// that the playing line is actually off screen.
    ///
    /// Takes the drag's total translation, not a delta: SwiftUI reports cumulative translation
    /// during a gesture, so summing the values would count the same movement many times over and
    /// trip the threshold within one flick.
    ///
    /// Deliberately NOT auto-resuming after a delay. Ten seconds is a normal amount of time to
    /// spend on one paragraph, and the page yanking itself back mid-sentence is worse than a
    /// button you have to press. Following resumes when the learner asks for it, or taps a line.
    /// A drag began or continued. This marks the movement as the learner's, but does NOT decide
    /// visibility: `translation` is finger travel, and a flick's momentum carries the content
    /// roughly ten times further. `onContentOffset` measures the actual distance.
    func onManualScroll(translation: CGFloat = StudyViewModel.driftThreshold) {
        idleTask?.cancel()
        userScrolling = true
        drift = max(drift, abs(translation))
    }

    /// The transcript's content offset changed.
    ///
    /// Two signals are needed and neither suffices alone. The DRAG says the movement is the
    /// learner's rather than the auto-scroll following the playing line; the OFFSET says how far
    /// it went, including the distance momentum adds after the finger lifts. Finger travel alone
    /// missed that entirely — a flick moves a finger 200pt and the content 2000.
    func onContentOffset(_ offset: CGFloat) {
        guard userScrolling else {
            // Auto-scroll, or a settled view: this is the reference point for the next drag.
            anchorOffset = offset
            return
        }
        guard let anchor = anchorOffset else {
            anchorOffset = offset
            return
        }
        if abs(offset - anchor) >= StudyViewModel.driftThreshold {
            following = false
        }
    }

    func onScrollEnded() {
        // Momentum continues after the finger lifts, so `userScrolling` stays true until the
        // content settles — ending it here would ignore most of a flick's travel. It is cleared
        // when following resumes, which is the only moment the anchor is meaningful again.
        if following {
            drift = 0
        }
    }

    func syncNow() {
        idleTask?.cancel()
        drift = 0
        userScrolling = false
        anchorOffset = nil
        following = true
    }

    func tap(sentence: SentenceDTO, playback: Playback) {
        // Tapping a line is a request to be AT that line, so following resumes — otherwise
        // "Back to current" would still be showing while the transcript is already there.
        syncNow()
        playback.seek(sentence.startMs)
        playback.play()
    }
}
