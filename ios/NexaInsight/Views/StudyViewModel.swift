import CoreGraphics
import Foundation

@MainActor
final class StudyViewModel: ObservableObject {
    @Published var following = true
    private var idleTask: Task<Void, Never>?

    func currentSentence(sentences: [SentenceDTO], cursorMs: Int) -> SentenceDTO? {
        activeSentence(sentences, cursorMs) ?? sentences.first
    }

    /// The learner dragged the transcript, so stop following the playing line.
    ///
    /// Took offsets before and compared them to where the playing line would be — and was
    /// never called from anywhere, so `following` stayed true forever and the "Back to
    /// current" button could not render. The drag itself is the signal: if a finger moved the
    /// page, they are reading somewhere else.
    ///
    /// Deliberately NOT auto-resuming after a delay any more. Ten seconds is a normal amount
    /// of time to spend on one paragraph, and the page yanking itself back mid-sentence is
    /// worse than a button you have to press. Following resumes when the learner asks for it,
    /// or when they tap a line — both explicit.
    func onManualScroll() {
        idleTask?.cancel()
        following = false
    }

    func syncNow() {
        idleTask?.cancel()
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
