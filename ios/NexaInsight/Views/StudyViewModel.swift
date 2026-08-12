import CoreGraphics
import Foundation

@MainActor
final class StudyViewModel: ObservableObject {
    @Published var following = true
    private var idleTask: Task<Void, Never>?

    func currentSentence(sentences: [SentenceDTO], cursorMs: Int) -> SentenceDTO? {
        activeSentence(sentences, cursorMs) ?? sentences.first
    }

    func onManualScroll(currentOffset: CGFloat, targetOffset: CGFloat) {
        guard isManualScrollAway(currentScrollTop: currentOffset, targetScrollTop: targetOffset, tolerancePx: 24) else { return }
        following = false
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled { await MainActor.run { self?.following = true } }
        }
    }

    func syncNow() {
        idleTask?.cancel()
        following = true
    }

    func tap(sentence: SentenceDTO, playback: Playback) {
        playback.seek(sentence.startMs)
        playback.play()
    }
}
