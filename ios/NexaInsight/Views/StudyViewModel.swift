import CoreGraphics
import Foundation

@MainActor
final class StudyViewModel: ObservableObject {
    @Published var following = true
    private var idleTask: Task<Void, Never>?

    func currentSentence(sentences: [SentenceDTO], cursorMs: Int) -> SentenceDTO? {
        activeSentence(sentences, cursorMs) ?? sentences.first
    }

    /// How far the transcript must move before the playing line counts as gone.
    ///
    /// The drag itself is NOT the signal. Treating any 12pt drag as "reading elsewhere" meant
    /// the button appeared while the playing line was still perfectly visible, just no longer
    /// centred — nudge the page and a control offers to take you back where you already are.
    ///
    /// Roughly two rows at a typical row height plus `NXSpacing.x6` between them. Below this the
    /// line is still on screen, so there is nothing to go back to.
    static let driftThreshold: CGFloat = 220

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
    func onManualScroll(translation: CGFloat = StudyViewModel.driftThreshold) {
        idleTask?.cancel()
        drift = max(drift, abs(translation))
        if drift >= StudyViewModel.driftThreshold {
            following = false
        }
    }

    /// Called when a drag ends, so the next drag starts a fresh measurement. Without this, three
    /// small nudges that each leave the line visible would add up and trip the threshold.
    func onScrollEnded() {
        if following {
            drift = 0
        }
    }

    func syncNow() {
        idleTask?.cancel()
        drift = 0
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
