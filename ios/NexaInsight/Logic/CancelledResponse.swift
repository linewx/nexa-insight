import Foundation

/// Which events survive from a response the app cancelled.
///
/// The server reports `response.done` for a cancelled response exactly as it does for one that
/// finished. Treated as "the teacher finished", that event hands the floor and the scene phase
/// onward — so holding to talk mid-answer showed "Live 等你开口" while the controller had
/// already been told the turn was over, and nothing responded. Observed on device: a
/// `pressQuickAsk` at 95800ms, a `response.cancel`, then the cancelled turn's `response.done`
/// arriving four events later and closing out the hold that had just begun.
///
/// The turn-ended signal is dropped and everything else is kept, because tool calls ride on
/// the same frame: a note the teacher saved a moment before the cancel must still be written.
/// Dropping the frame wholesale loses it silently, which is worse than the bug being fixed.
///
/// Pure so the rule is testable without WebRTC, which the transport needs and the test target
/// does not have.
enum CancelledResponse {
    /// - Parameters:
    ///   - events: everything parsed from the frame.
    ///   - wasCancelled: whether the app cancelled the response this frame belongs to.
    static func forwarded(_ events: [RealtimeEvent], wasCancelled: Bool) -> [RealtimeEvent] {
        guard wasCancelled else { return events }
        return events.filter { event in
            if case .responseDone = event { return false }
            return true
        }
    }
}
