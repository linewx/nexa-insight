import Foundation

@MainActor
final class ShadowingViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var recordings: [StoredRecording] = []
    @Published var feedbackError: String?
    @Published var requestingFeedback = false

    private let store: EpisodeStore
    private let keychain: KeychainStore
    private let recorder: ShadowingRecording
    private var activeRelativePath: String?

    init(store: EpisodeStore, keychain: KeychainStore, recorder: ShadowingRecording) {
        self.store = store; self.keychain = keychain; self.recorder = recorder
    }

    static func canRequestFeedback(hasKey: Bool) -> Bool { hasKey }

    func reload(sentenceId: Int) { recordings = store.recordings(sentenceId: sentenceId) }

    func orderedRecordings() -> [StoredRecording] {
        recordings.sorted { ($0.isBest ? 1 : 0, $0.createdAt) > ($1.isBest ? 1 : 0, $1.createdAt) }
    }

    func startRecording(episodeId: Int, sentenceId: Int) {
        let target = RecordingFiles.recordingURL(episodeId: episodeId, sentenceId: sentenceId)
        activeRelativePath = target.relative
        do { try recorder.start(to: target.url); isRecording = true }
        catch { feedbackError = error.localizedDescription }
    }

    func stopRecording(episodeId: Int, sentenceId: Int) {
        _ = recorder.stop()
        isRecording = false
        if let relative = activeRelativePath {
            _ = try? store.addRecording(episodeId: episodeId, sentenceId: sentenceId, localFilePath: relative)
            activeRelativePath = nil
        }
        reload(sentenceId: sentenceId)
    }

    func markBest(recording: StoredRecording, sentenceId: Int) {
        try? store.markBest(recordingId: recording.persistentModelID)
        reload(sentenceId: sentenceId)
    }

    func requestFeedback(recording: StoredRecording, sentenceText: String, sentenceId: Int) async {
        feedbackError = nil
        guard let key = keychain.get(.openAIKey), Self.canRequestFeedback(hasKey: !key.isEmpty) else {
            feedbackError = "Add your OpenAI API key in Settings to get feedback."
            return
        }
        requestingFeedback = true
        defer { requestingFeedback = false }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(recording.localFilePath)
        let client = OpenAITutorClient(apiKey: key)
        do {
            let text = try await client.shadowingFeedback(sentence: sentenceText, recordingURL: url)
            try store.setFeedback(recordingId: recording.persistentModelID, feedback: text)
            reload(sentenceId: sentenceId)
        } catch {
            feedbackError = error.localizedDescription
        }
    }
}
