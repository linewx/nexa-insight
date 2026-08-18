#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

struct StudyView: View {
    let episodeId: Int
    let store: EpisodeStore
    let backendBaseURL: URL
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = StudyViewModel()
    @StateObject private var player: LocalAudioPlayback
    @State private var audioRefreshState: AudioRefreshState = .idle
    @State private var shadowingSentence: SentenceDTO?
    /// Incremented by "Back to current" so the transcript scrolls on the press itself.
    @State private var syncRequest = 0
    @State private var liveSession: LiveClassSession?
    // How far the screen is dragged during a back-swipe. Drives the follow-the-finger
    // offset so the gesture has the visual feedback the system one would give.
    @State private var backSwipeOffset: CGFloat = 0
    /// Whether the notes drawer is open. Opened by dragging in from the RIGHT edge — the
    /// left edge is the back gesture, and two things on one edge is one too many.
    @State private var showNotes = false
    /// How far the open drawer has been dragged back out, so it follows the finger.
    /// Separate from `showNotes` because the drawer is always mounted and merely
    /// translated — see the overlay.
    @State private var notesDragOffset: CGFloat = 0
    // Intensive-listening state. Loop lives here rather than on a row so only one
    // sentence can ever loop; speed mirrors the player's rate for the badge.
    @State private var loop: SentenceLoop = .off
    /// Where a practice preview should stop, and what to call then. A tuple rather than a
    /// dedicated type because it lives for one sentence and nothing else reads it.
    @State private var segmentEnd: (endMs: Int, done: () -> Void)?
    @State private var speed: Double = 1
    @State private var savedPositionMs: Int?
    // Nil until the header capsule is used: the mode then follows the persisted
    // preference, and the capsule overrides it for this sitting only.
    @State private var modeOverride: StudyMode?
    @State private var expandedExpressionID: Int?
    // Which paragraphs have their card stack open. A set, not a single id: several
    // paragraphs can be open at once, and closing one should not close the rest.
    @State private var expandedCardSentenceIds: Set<Int> = []
    @State private var paragraphNotes: [StoredParagraphNote] = []
    @State private var practiceExpression: LearningExpressionDTO?
    /// The conversation in progress, if any. One paragraph at a time: holding a
    /// different one closes this conversation before moving the anchor.
    ///
    /// Replaces `askingSentence` plus the composer's sheet state. The old pair could
    /// only say "a finger is down on this line"; a conversation has to survive the
    /// finger lifting, which is where the answer, the follow-up and the whole point of
    /// it live.
    @State private var readingAsk: ReadingAsk?
    @State private var noteError: String?

    /// One instance for the life of the screen, so rows can compare it with `===`.
    /// `@State` holds it across body evaluations; its closures are refreshed on each one
    /// (see `TranscriptBlock.currentActions`). A `let` would be recreated whenever
    /// SwiftUI re-inits the view struct, which is exactly what must not happen.
    @State private var rowActions = RowActions()
    private let sentences: [SentenceDTO]

    /// Every expression on this episode, automatic and hand-made alike, as the store
    /// currently holds them.
    ///
    /// One list read from the store, not an init snapshot unioned with this sitting's
    /// additions. That split could not express a delete: `store.learningExpressions`
    /// already returns the manual rows, so a card made in an earlier sitting lived in
    /// the immutable snapshot, and removing it from the additions list left the card
    /// on screen until the episode was reopened.
    ///
    /// Seeded in `init` rather than filled by `onAppear`: empty on the first frame
    /// would make `annotated` false exactly when the rows are first built, and the
    /// reading branch that carries the tap and hold gestures would never be taken.
    @State private var learningExpressions: [LearningExpressionDTO]

    // Cached, not computed per redraw. The player publishes its position every
    // 200ms, so a computed property here runs five times a second for the whole
    // episode — with 681 sentences and 137 expressions that was the stutter.
    @State private var cachedIndex = LearningExpressionLogic.Index([])
    @State private var cachedCardIndex = ParagraphCards.Index(expressions: [], notes: [])
    private let episode: EpisodeDTO?

    init(episodeId: Int, store: EpisodeStore, backendBaseURL: URL, settings: AppSettings) {
        self.episodeId = episodeId
        self.store = store
        self.backendBaseURL = backendBaseURL
        self.settings = settings
        self.sentences = store.sentences(for: episodeId)
        _learningExpressions = State(initialValue: store.learningExpressions(for: episodeId))
        self.episode = store.downloadedEpisodes().first { $0.id == episodeId }
        let relative = store.localAudioPath(for: episodeId) ?? "audio/\(episodeId).mp3"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Resume where the learner left off. Nothing persisted a position before,
        // so a 3h46m episode restarted at 0:00 every time it was reopened.
        let resumeMs = Resume.startPosition(
            savedMs: store.playbackPosition(for: episodeId),
            durationMs: self.episode?.durationMs) ?? 0
        _player = StateObject(wrappedValue: LocalAudioPlayback(
            fileURL: base.appendingPathComponent(relative),
            initialPositionMs: resumeMs))
    }

    /// The mode in force: this sitting's override, else the persisted preference.
    private var mode: StudyMode {
        modeOverride ?? (settings.opensInReading ? .reading : .listening)
    }

    /// Whether expressions are marked in the transcript. Both modes annotate — the
    /// modes differ in the controls a sentence offers, not in how the text looks —
    /// so this is now only about whether there is anything to mark.
    private var annotated: Bool { !learningExpressions.isEmpty }
    var current: SentenceDTO? { vm.currentSentence(sentences: sentences, cursorMs: player.currentMs) }

    var body: some View {
        StudyWorkspace(
            episode: episode,
            sentences: sentences,
            current: current,
            audioRefreshState: audioRefreshState,
            following: vm.following,
            syncRequest: syncRequest,
            player: player,
            onSentenceTap: { sentence in
                switch SentencePlaybackToggle.action(
                    tapped: sentence, playingId: current?.id,
                    isPlaying: player.playbackState == .playing) {
                case .play(let ms): playIntent(seekTo: ms)
                case .stop: player.pause()
                }
            },
            onShadow: { sentence in shadowingSentence = sentence },
            onSync: {
                vm.syncNow()
                syncRequest += 1
            },
            onManualScroll: { vm.onManualScroll() },
            onRefreshAudio: { Task { await refreshAudio() } },
            onTalk: startDiscussion,
            onSeekIntent: { ms in playIntent(seekTo: ms) },
            loop: loop,
            speed: speed,
            onReplay: {
                if let ms = IntensiveListening.replayTarget(current) { playIntent(seekTo: ms) }
            },
            onToggleLoop: { sentence in loop = loop.toggled(sentence) },
            onStep: { sentence in playIntent(seekTo: sentence.startMs) },
            onCycleSpeed: {
                speed = IntensiveListening.cycledSpeed(after: speed)
                player.speed(speed)
            },
            mode: mode,
            annotated: annotated,
            onToggleAnnotations: {
                let next = mode.toggled
                modeOverride = next
                if next == .listening {
                    // Leaving reading closes any open card: its controls are gone, and a
                    // card with no way to practise from it is a dead end.
                    expandedExpressionID = nil
                    // And closes any open conversation. Listening has no per-paragraph
                    // hold, so a panel left open would sit there with no way to follow up
                    // — its own "继续长按追问" pointing at a gesture that is gone.
                    finishConversation()
                }
            },
            learningExpressions: learningExpressions,
            expressionIndex: cachedIndex,
            cardIndex: cachedCardIndex,
            expandedExpressionID: $expandedExpressionID,
            onPracticeExpression: { practiceExpression = $0 },
            noteRows: paragraphNotes.map {
                (id: $0.noteId, sentenceId: $0.sentenceId, question: $0.question, answer: $0.answer)
            },
            expandedCardSentenceIds: expandedCardSentenceIds,
            onToggleCards: { id in
                if expandedCardSentenceIds.contains(id) {
                    expandedCardSentenceIds.remove(id)
                } else {
                    expandedCardSentenceIds.insert(id)
                }
            },
            onDeleteCard: deleteCard,
            readingAsk: readingAsk,
            onHoldStart: beginAsking,
            onHoldEnd: endAsking,
            onEndConversation: finishConversation,
            discussionSession: liveSession,
            onEndDiscussion: endDiscussion,
            rowActions: rowActions
        )
        // Drives the loop. Without this the loop control would toggle a flag and
        // playback would sail past the sentence end — the rewind has to be applied
        // as the position advances.
        .onChange(of: player.currentMs) { _, ms in
            // Stops a practice sentence at its end. Checked before the loop, so a sentence
            // being previewed for shadowing is not also rewound by a loop left on.
            if let pending = segmentEnd, ms >= pending.endMs {
                segmentEnd = nil
                player.pause()
                pending.done()
            }
            if let target = loop.rewindTarget(for: current, at: ms) {
                player.seek(target)
            }
            // Throttled: writing on every tick would hit SwiftData several times a
            // second for the whole session.
            if Resume.shouldPersist(newMs: ms, lastSavedMs: savedPositionMs) {
                savedPositionMs = ms
                store.savePlaybackPosition(ms, for: episodeId)
            }
        }
        // The notes, and the indexes built from them, read once on appear rather
        // than on the 200ms position tick. Rebuilding the index five times a second
        // was the reading-mode stutter. Every writer in THIS view calls the same
        // refresh, so there is no count to watch — except the teacher's, which writes
        // through LiveClassSession and cannot call it.
        .onAppear {
            refreshExpressionCaches()
            // Opening IS the visit, which is what the library sorts by. Not left to
            // savePlaybackPosition: that only fires once playback passes ten seconds, so
            // opening an episode to read a paragraph would never have counted.
            store.markVisited(episodeId)
        }
        // Leaving mid-sentence is the common case, so the exact position is
        // written on the way out rather than only at throttle boundaries.
        .onDisappear {
            if player.currentMs >= Resume.minimumMs {
                store.savePlaybackPosition(player.currentMs, for: episodeId)
            }
            // Leaving closes the conversation, so returning does not find a stale panel
            // still showing turns from last time. Nothing is lost by closing now: cards
            // are written the moment you ask for one, not on the way out.
            finishConversation()
        }
        .onChange(of: annotated) { _, showing in
            // A card left open with no highlight to anchor it would float free.
            if !showing { expandedExpressionID = nil }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Hidden, not merely transparent. Every attempt to keep the bar present for
        // the sake of the system pop gesture cost more than it bought: transparent
        // still reserved its height (an empty strip above the screen's own header),
        // and reclaiming that height via .ignoresSafeArea pulled content under the
        // notch instead. The bar is hidden and back-swipe is handled below.
        .toolbar(.hidden, for: .navigationBar)
        // Study is pushed from the Library tab, so it owns the whole screen until
        // back navigation restores Library and its tab bar.
        .toolbar(.hidden, for: .tabBar)
        .task { startDiscussion() }
        // Hiding the bar also disables interactivePopGestureRecognizer, so the
        // back-swipe is re-implemented here. Interactive (tracks the finger, snaps
        // back if released short) rather than the earlier .onEnded-only version,
        // which gave no feedback and silently failed on any vertical drift.
        .offset(x: backSwipeOffset)
        .simultaneousGesture(edgeSwipeBackGesture)
        .simultaneousGesture(notesDrawerGesture)
        // Slides in from the RIGHT, the edge the finger pulled it from. A sheet was wrong
        // twice over: it rises from the bottom whatever gesture summoned it, and only one
        // .sheet per view is honoured so it never appeared at all.
        //
        // Driven by an OFFSET rather than a transition. An insertion transition has to
        // animate a view being added to the hierarchy, which stutters on a screen this
        // busy; a view that is always mounted and merely translated is one property
        // animating, and it can also follow the finger.
        .overlay {
            ZStack(alignment: .trailing) {
                if showNotes {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .onTapGesture { closeNotes() }
                        .transition(.opacity)
                }
                NotesDrawer(
                    expressions: learningExpressions,
                    notes: paragraphNotes.map {
                        (id: $0.noteId, sentenceId: $0.sentenceId, question: $0.question, answer: $0.answer)
                    },
                    sentenceStarts: Dictionary(
                        sentences.map { ($0.id, $0.startMs) }, uniquingKeysWith: { first, _ in first }),
                    onDelete: deleteCard,
                    onClear: clearNotes,
                    onJump: { ms in
                        closeNotes()
                        playIntent(seekTo: ms)
                    },
                    onPractice: { expression in
                        // The drawer STAYS. Practice is a half sheet over it, so closing that
                        // sheet returns to the notes the card came from. Dismissing the
                        // drawer here dropped the learner back on the transcript instead,
                        // which loses their place in a list they were working through.
                        practiceExpression = expression
                    },
                    onClose: closeNotes)
                // Full width. A gap at the left showed a strip of transcript that could
                // not be read or touched — it looked like the drawer had failed to cover
                // the page rather than like a deliberate peek at it.
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .bottom)
                // Parked off-screen when closed, so it is mounted and ready rather than
                // being built as it appears.
                .offset(x: showNotes ? notesDragOffset : UIScreen.main.bounds.width)
                // Swipe right ANYWHERE in the drawer to dismiss it, mirroring the swipe
                // that opened it. Kept off the notes list's own vertical scroll by the same
                // direction test: twice as far sideways as up or down, so drifting a scroll
                // does not throw the drawer away mid-read.
                .gesture(
                    DragGesture(minimumDistance: 16, coordinateSpace: .local)
                        .onChanged { value in
                            guard value.translation.width > abs(value.translation.height) * 2
                            else { return }
                            // Rightward only: leftward inside an open drawer is nothing.
                            notesDragOffset = max(0, value.translation.width)
                        }
                        .onEnded { value in
                            let rightwards = value.translation.width
                            guard rightwards > abs(value.translation.height) * 2 else {
                                // A drag that turned out to be a scroll leaves the drawer
                                // where it was rather than half-open.
                                if notesDragOffset != 0 {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                                        notesDragOffset = 0
                                    }
                                }
                                return
                            }
                            let far = rightwards > 90 || value.predictedEndTranslation.width > 160
                            if far {
                                closeNotes()
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                                    notesDragOffset = 0
                                }
                            }
                        })
            }
            // Nothing to hit when closed: an off-screen drawer must not swallow taps meant
            // for the transcript, and its scrim is gone by then anyway.
            .allowsHitTesting(showNotes)
        }
        .sheet(item: $shadowingSentence) { s in
            PracticeView(
                subject: .init(episodeId: episodeId, text: s.sourceText, chinese: s.chinese,
                               expressionId: nil, sentenceId: s.id,
                               // The speaker's own voice for a transcript sentence. Synthesis
                               // resolves to Apple's most compressed offline voice, and
                               // shadowing that teaches the wrong intonation.
                               audio: .original(startMs: s.startMs, endMs: s.endMs)),
                store: store,
                onPlayOriginal: { start, end, done in playSegment(from: start, to: end, then: done) })
                .presentationDetents([.medium])
        }
        // Its own layer. This screen carries two item-driven sheets — a transcript sentence and
        // a card example — and only one presentation per view survives, so whichever lost would
        // simply never open. Found by grepping for the pattern after the ➕ bug rather than
        // by anyone reporting it, which is how this trap keeps hiding.
        .background {
            Color.clear
                .sheet(item: $practiceExpression) { expression in
                    PracticeView(
                        subject: .init(episodeId: episodeId, text: expression.example,
                                       chinese: expression.exampleChinese,
                                       expressionId: expression.id, sentenceId: nil),
                        store: store)
                        .presentationDetents([.medium])
                }
        }
        .onChange(of: practiceExpression?.id) { _, newValue in
            // The sentence is about to be spoken aloud, so the episode cannot keep playing
            // underneath it. This was an `onStartRecording` callback the old view invoked at
            // record time; now that playback starts on its own, pausing belongs here.
            if newValue != nil { player.pause() }
        }
        .onChange(of: shadowingSentence?.id) { _, newValue in
            if newValue != nil { player.pause() }
        }
        // Watching the controller has to happen in a view that OBSERVES it. `@State`
        // holds a reference without subscribing to objectWillChange, so an `.onChange`
        // on `liveSession?.controller?.transcript` here would never fire — this body is
        // not re-evaluated when the controller publishes. That is why DiscussionBar
        // takes an @ObservedObject, and why this needs its own observer.
        .background {
            if let controller = liveSession?.controller {
                ReadingTurnObserver(controller: controller, active: readingAsk != nil) { event in
                    switch event {
                    case let .heard(text): readingAsk?.heard(text)
                    case let .answered(text): readingAsk?.answered(text)
                    case .turnEnded: readingAsk?.finished()
                    }
                }
            }
            // A note the teacher was asked to save is written by the SESSION, not by this
            // view, so nothing here would rebuild the indexes the rows draw from — the
            // card would exist and stay invisible until the episode was reopened.
            //
            // Its own observer for the same reason as above: `liveSession` is `@State`,
            // which holds a reference without subscribing, so an `.onChange` on
            // `liveSession?.savedNotes` written in this body would never fire.
            if let session = liveSession {
                SavedNoteObserver(session: session, onSaved: refreshExpressionCaches)
            }
        }
        // Bound to the value, not `.constant(...)`: a constant binding cannot be
        // written back, so dismissing left `noteError` set and the alert could
        // never be shown a second time — the first failure was the only one you
        // ever saw.
        .alert(
            "\u{63d0}\u{95ee}\u{51fa}\u{4e86}\u{95ee}\u{9898}",
            isPresented: Binding(get: { noteError != nil }, set: { if !$0 { noteError = nil } }),
            presenting: noteError
        ) { _ in
            Button("\u{597d}") { noteError = nil }
        } message: { message in
            Text(message)
        }
    }

    /// Deletes one card. Only what the learner made by hand can go: automatic rows
    /// are replaced by a reprocess, so removing one would not stick.
    private func deleteCard(_ card: ParagraphCards.Card) {
        do {
            switch card {
            case .expression(let expression):
                guard card.isDeletable else { return }
                try store.deleteManualExpression(expression.id)
            case .note(let id, _, _):
                try store.deleteParagraphNote(id)
            }
            // Both branches rebuild. The note branch used to only drop the row from
            // `paragraphNotes`, and the rows read from `cachedCardIndex` — so the
            // card stayed on screen, looking like the delete had done nothing.
            refreshExpressionCaches()
        } catch {
            noteError = error.localizedDescription
        }
    }

    /// Re-reads both lists from the store and rebuilds the indexes the rows draw from.
    ///
    /// The store is the source of truth for both; anything that mutates either must
    /// come through here, or the rows keep drawing the previous index.
    private func refreshExpressionCaches() {
        learningExpressions = store.learningExpressions(for: episodeId)
        paragraphNotes = store.paragraphNotes(for: episodeId)
        cachedIndex = LearningExpressionLogic.Index(learningExpressions)
        cachedCardIndex = ParagraphCards.Index(
            expressions: learningExpressions,
            notes: paragraphNotes.map {
                (id: $0.noteId, sentenceId: $0.sentenceId, question: $0.question, answer: $0.answer)
            })
    }

    /// Holding a paragraph opens a spoken conversation about that paragraph.
    ///
    /// Goes through the realtime session rather than recording a file and uploading
    /// it. That is what makes the teacher answer out loud, makes a follow-up possible,
    /// and makes what you said visible — the one-shot HTTP path could do none of the
    /// three, because each hold was a fresh stateless request that returned JSON.
    ///
    /// Playback pauses for the duration either way: otherwise the mic hears the
    /// episode mixed with your voice.
    private func beginAsking(_ sentence: SentenceDTO) {
        guard let session = liveSession else {
            // No session at all. Say so once rather than letting a hold do nothing,
            // which reads as the gesture being broken.
            noteError = "\u{8bfe}\u{5802}\u{8fd8}\u{6ca1}\u{8fde}\u{4e0a}\u{ff0c}\u{7a0d}\u{540e}\u{518d}\u{957f}\u{6309}\u{63d0}\u{95ee}\u{3002}"
            return
        }
        // The server ends an idle stream after five minutes and nothing notices, so a
        // stale session has to be rebuilt before it can carry a turn.
        //
        // Reconnecting takes seconds, and the finger is DOWN now — it will be long gone
        // before the new channel opens, so there is no turn left to start and the hold is
        // lost. The earlier version returned here and said nothing on success, which made
        // every hold on a timed-out session feel like the gesture had stopped working.
        //
        // So say what is happening, and do not pretend the question was heard. Asking
        // again once connected is one more press; a press that silently does nothing is
        // indistinguishable from a broken app.
        guard let controller = session.controller, session.canCarryATurn else {
            noteError = "\u{8bfe}\u{5802}\u{8fde}\u{63a5}\u{5df2}\u{65ad}\u{5f00}\u{ff0c}\u{6b63}\u{5728}\u{91cd}\u{8fde}\u{ff0c}\u{7a0d}\u{540e}\u{518d}\u{957f}\u{6309}\u{3002}"
            Task {
                await session.reconnectIfNeeded()
                if !session.canCarryATurn, let reason = session.error {
                    noteError = reason
                }
            }
            return
        }
        // A follow-up continues the same conversation; a hold on a different paragraph
        // closes the previous one first, so the panel does not follow the anchor to a
        // paragraph its turns were never about.
        if let existing = readingAsk, existing.sentenceId != sentence.id {
            finishConversation()
        }
        if player.playbackState == .playing { player.pause() }
        if readingAsk?.sentenceId == sentence.id {
            guard readingAsk?.acceptsFollowUp == true else { return }
            readingAsk?.held()
        } else {
            readingAsk = ReadingAsk(sentenceId: sentence.id, atMs: sentence.startMs)
        }
        controller.pressReadingAsk(atMs: sentence.startMs)
    }

    private func endAsking() {
        // Only a hold that is actually recording can be released. `onHoldEnd` fires on
        // EVERY release — a scroll, a tap, a press too brief to pass the threshold —
        // and with a finished conversation still open on this paragraph, releasing it
        // again would strand the panel: phase would go to `waiting` while the floor
        // stayed `.idle`, so the observer that lands it back on `idle` never fires and
        // "在想…" would sit there forever.
        guard let controller = liveSession?.controller,
              readingAsk?.phase == .recording else { return }
        readingAsk?.released()
        controller.releaseReadingAsk()
    }

    /// Ends the conversation.
    ///
    /// No longer sediments anything. Cards are written when you ASK for one — the teacher
    /// calls save_note and it lands immediately — so extracting again here would mean
    /// every conversation produced cards twice: once because you asked, once because a
    /// model decided afterwards.
    ///
    /// The automatic path is kept in the tree (`KnowledgePointExtractor`,
    /// `ExtractionPrompt.conversationRules`, `OnDemandExtractionClient.knowledgePoints`)
    /// rather than deleted, because "explicit only" is a behaviour experiment: if asking
    /// turns out to be easy to forget, automatic sedimenting comes back as a supplement.
    /// That is the difference from the dead code removed earlier, which was unreachable
    /// rather than merely unused.
    private func finishConversation() {
        readingAsk = nil
    }

    // Interactive edge-swipe back. Only the horizontal component is read, so a
    // little vertical drift no longer cancels the gesture the way the original
    // `staysMostlyHorizontal` check did. The finger is tracked live and the screen
    // snaps back when released short, which is the feedback that tells the learner
    // the gesture exists at all.
    /// Drag in from the RIGHT edge to open the notes.
    ///
    /// Mirrors the back gesture on the opposite edge rather than sharing it: the left edge
    /// already means "leave this episode", and hanging a second meaning on the same drag
    /// would make both feel unreliable. `.global` because the trigger is the screen's edge,
    /// and the row is inset from it.
    ///
    /// Not interactive (no follow-the-finger offset) because the drawer is a sheet, and a
    /// sheet cannot be dragged in halfway — it either presents or it does not, so tracking
    /// the finger would promise a motion it cannot deliver.
    /// Swipe left ANYWHERE to open the notes — not only from the edge.
    ///
    /// The edge is the usual way to keep a horizontal gesture out of a scroll view's way,
    /// but the notes are worth reaching without aiming. What replaces it is a DIRECTION
    /// test: the drag has to be decisively horizontal, so the small sideways wobble in a
    /// vertical scroll through 681 rows cannot trigger it.
    ///
    /// Below the header, so the scrubber keeps its own drag.
    private var notesDrawerGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                guard value.startLocation.y > 96 else { return }
                let leftwards = -value.translation.width
                let vertical = abs(value.translation.height)
                // Twice as far sideways as up or down. A scroll that drifts is not a swipe.
                guard leftwards > vertical * 2 else { return }
                guard leftwards > 60 || -value.predictedEndTranslation.width > 120 else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                openNotes()
            }
    }

    /// Opens the notes drawer. The animation lives here rather than on the view, so the
    /// slide is driven by the state change that causes it.
    private func openNotes() {
        notesDragOffset = 0
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { showNotes = true }
    }

    private func closeNotes() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { showNotes = false }
        // Reset AFTER the slide out, or the next open would start mid-drag.
        notesDragOffset = 0
    }

    /// Clears the notes the learner made on this episode.
    private func clearNotes() {
        do {
            try store.clearManualNotes(for: episodeId)
            refreshExpressionCaches()
            // Nothing left to expand, and a card id kept here would point at a row that
            // no longer exists.
            expandedExpressionID = nil
            expandedCardSentenceIds = []
        } catch {
            noteError = error.localizedDescription
        }
    }

    private var edgeSwipeBackGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                // Start only from the leading edge, and below the header so the
                // scrubber keeps its own drag.
                guard value.startLocation.x <= 32, value.startLocation.y > 96 else { return }
                backSwipeOffset = max(0, value.translation.width)
            }
            .onEnded { value in
                guard value.startLocation.x <= 32, value.startLocation.y > 96 else { return }
                let committed = value.translation.width > 90
                    || value.predictedEndTranslation.width > 160
                if committed {
                    dismiss()
                    backSwipeOffset = 0
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        backSwipeOffset = 0
                    }
                }
            }
    }

    // Joining does not interrupt the source: the session connects while the
    // podcast keeps playing, and the model is told where playback currently is.
    // The learner speaking is what pauses it (see ClassroomController).
    //
    // Because nothing audible changes at this moment, the tap needs a haptic to
    // land — otherwise "the teacher is here now" is a claim only the dock makes.
    // Auto-connects when the study screen appears, so the session is ready by the
    // time the learner holds to talk.
    //
    // Creating it is NOT connecting it. `start()` used to be a `.task` on
    // DiscussionBar, which reading hides — so in reading the session existed, the
    // controller was never built, and every hold reported "课堂还没连上". Connecting
    // belongs to whoever owns the session, not to a bar that may not be on screen.
    private func startDiscussion() {
        guard liveSession == nil else { return }
        let session = LiveClassSession(
            store: store, keychain: KeychainStore(), episodeId: episodeId, playback: player)
        liveSession = session
        Task { await session.start() }
    }

    // Playback driven by the learner (play button, scrubber, tapping a line).
    // With a class connected this MUST go through the controller: taking the floor
    // for the podcast is what silences the teacher. Calling player.play() directly
    // left both playing at once, because the floor never moved.
    private func playIntent(seekTo positionMs: Int?) {
        guard let controller = liveSession?.controller else {
            if let positionMs { player.seek(positionMs) }
            player.play()
            return
        }
        controller.userStartedPlayback(seekTo: positionMs)
    }

    // No pauseIntent here: pausing is only reachable from the dock, which has the
    // controller and calls userPausedPlayback() directly.

    /// Plays one sentence of the episode and stops at its end.
    ///
    /// The practice sheet cannot hold its own player — two AVPlayers on one audio session
    /// fight — so it asks for a window and StudyView drives it. Bounded playback is what makes
    /// the real voice usable at all: a segment averages 11.5s on the hotel vlog and runs to
    /// 33s, so unbounded "listen to this sentence" plays the paragraph around it.
    private func playSegment(from startMs: Int, to endMs: Int, then done: @escaping () -> Void) {
        segmentEnd = (endMs, done)
        player.seek(startMs)
        player.play()
    }

    private func endDiscussion() {
        liveSession?.end()
        liveSession = nil
    }

    private func refreshAudio() async {
        audioRefreshState = .refreshing
        print("[NexaAudio] refresh started for episode \(episodeId), backend \(backendBaseURL.absoluteString)")
        do {
            let client = BackendClient(baseURL: backendBaseURL)
            var bundle = try await client.bundle(episodeId)
            print("[NexaAudio] bundle fetched, hasAudio=\(bundle.hasAudio)")
            if !bundle.hasAudio {
                guard let sourceURL = episode?.sourceUrl else {
                    audioRefreshState = .failed("This source has no original URL, so audio cannot be prepared again.")
                    return
                }
                let (_, job) = try await client.importEpisode(url: sourceURL)
                audioRefreshState = .processing(job.stage, job.progress)
                bundle = try await waitForPreparedAudio(client: client)
            }
            try await downloadAudio(bundle: bundle, client: client)
        } catch {
            print("[NexaAudio] refresh failed: \(error.localizedDescription)")
            audioRefreshState = .failed(audioRefreshFailureMessage(for: error))
        }
    }

    private func audioRefreshFailureMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet,
                    .networkConnectionLost, .timedOut:
                return "Could not reach the Nexa backend at \(backendBaseURL.host ?? backendBaseURL.absoluteString). Your source is still safe. Connect to Tailscale, then try Refresh audio again."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private func waitForPreparedAudio(client: BackendClient) async throws -> BundleDTO {
        for _ in 0..<120 {
            let job = try await client.episodeJob(episodeId)
            audioRefreshState = .processing(job.stage, job.progress)
            if job.status == "failed" {
                throw NSError(domain: "AudioRefresh", code: 1, userInfo: [NSLocalizedDescriptionKey: job.error ?? "Audio preparation failed."])
            }
            let bundle = try await client.bundle(episodeId)
            if bundle.hasAudio {
                return bundle
            }
            if job.status == "complete" {
                throw NSError(domain: "AudioRefresh", code: 2, userInfo: [NSLocalizedDescriptionKey: "Processing completed, but the backend did not expose an audio file. Try Add to Nexa again."])
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw NSError(domain: "AudioRefresh", code: 3, userInfo: [NSLocalizedDescriptionKey: "Audio preparation is still running. You can leave this page and refresh again later."])
    }

    private func downloadAudio(bundle: BundleDTO, client: BackendClient) async throws {
        let destination = AudioFiles.audioURL(forEpisode: episodeId)
        try await client.downloadAudio(episodeId, to: destination)
        _ = try store.saveBundle(bundle, localAudioPath: AudioFiles.relativePath(forEpisode: episodeId))
        player.reloadFromDisk()
        audioRefreshState = .ready
    }
}

private enum AudioRefreshState: Equatable {
    case idle
    case refreshing
    case processing(String, Int)
    case waiting(String)
    case ready
    case failed(String)
}

// Annotations layer over intensive listening rather than replacing it. As an
// exclusive StudyMode, turning reading on removed tap-to-seek and the
// per-sentence controls — the very things a definition makes you want, since the
// reason to read the note is usually to hear the line again.


private struct StudyWorkspace: View {
    let episode: EpisodeDTO?
    let sentences: [SentenceDTO]
    let current: SentenceDTO?
    let audioRefreshState: AudioRefreshState
    let following: Bool
    /// Bumped on every "Back to current" press. A counter rather than a flag because two
    /// presses in a row must each scroll, and onChange sees no change in `true` -> `true`.
    let syncRequest: Int
    @ObservedObject var player: LocalAudioPlayback
    let onSentenceTap: (SentenceDTO) -> Void
    let onShadow: (SentenceDTO) -> Void
    let onSync: () -> Void
    /// The learner dragged the transcript. Passed in rather than read from a view model,
    /// because this subview has neither — it takes closures, like every other action here.
    let onManualScroll: () -> Void
    let onRefreshAudio: () -> Void
    let onTalk: () -> Void
    // Seeking is the only playback action routed from here (the scrubber in the top
    // bar). Play/pause live in the dock, which talks to the controller directly.
    // Still an intent rather than a raw player call so a connected class moves the
    // floor (see ClassroomController.userStartedPlayback).
    var onSeekIntent: (Int) -> Void = { _ in }
    var loop: SentenceLoop = .off
    var speed: Double = 1
    var onReplay: () -> Void = {}
    var onToggleLoop: (SentenceDTO) -> Void = { _ in }
    var onStep: (SentenceDTO) -> Void = { _ in }
    var onCycleSpeed: () -> Void = {}
    var mode: StudyMode = .listening
    let annotated: Bool
    let onToggleAnnotations: () -> Void
    let learningExpressions: [LearningExpressionDTO]
    let expressionIndex: LearningExpressionLogic.Index
    let cardIndex: ParagraphCards.Index
    @Binding var expandedExpressionID: Int?
    let onPracticeExpression: (LearningExpressionDTO) -> Void
    var noteRows: [(id: Int, sentenceId: Int, question: String, answer: String)] = []
    var expandedCardSentenceIds: Set<Int> = []
    var onToggleCards: (Int) -> Void = { _ in }
    var onDeleteCard: (ParagraphCards.Card) -> Void = { _ in }
    var readingAsk: ReadingAsk?
    var onHoldStart: (SentenceDTO) -> Void = { _ in }
    var onHoldEnd: () -> Void = {}
    var onEndConversation: () -> Void = {}
    let discussionSession: LiveClassSession?
    let onEndDiscussion: () -> Void
    /// Passed straight through to the transcript. Owned by `StudyView` so its identity
    /// survives body evaluations — see `RowActions`.
    let rowActions: RowActions
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTopBar(
                episode: episode,
                current: current,
                player: player,
                durationMs: episode?.durationMs,
                audioRefreshState: audioRefreshState,
                onRefreshAudio: onRefreshAudio,
                onSeekIntent: onSeekIntent,
                speed: speed,
                mode: mode,
                annotated: annotated,
                onToggleAnnotations: onToggleAnnotations
            )
            studySurface
        }
        .background(NXColor.background(scheme))
    }

    // The join affordance and the discussion dock both float OVER the transcript
    // rather than pushing it: the transcript keeps one fixed bottom inset, so
    // joining never reflows what the learner is reading.
    private var studySurface: some View {
        ZStack(alignment: .bottom) {
            transcriptScrollArea(
                horizontalPadding: compact ? NXSpacing.x4 : NXSpacing.x8,
                // 1080pt of single-column text is far past a comfortable reading
                // measure; 680 keeps lines readable and leaves the width for a
                // second column later.
                contentMaxWidth: compact ? .infinity : 680,
                // Clears the bottom bar plus breathing room, so scrolling to the
                // end never strands text beneath it. Reading hides that bar, so the
                // same inset would leave a screen-third of dead space under the last
                // paragraph — it shrinks to the breathing room alone.
                bottomInset: mode.showsPlaybackControls ? 140 : 32
            )

            // Floating, and pinned above the dock rather than sitting at the
            // end of the transcript — where you had to scroll to the bottom to
            // find the button that takes you back to the middle.
            if !following {
                VStack {
                    Spacer(minLength: 0)
                    Button(action: onSync) {
                        HStack(spacing: NXSpacing.x1) {
                            Image(systemName: "scope").font(.system(size: 12, weight: .semibold))
                            Text("Back to current").font(NXFont.control)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, NXSpacing.x3)
                        .frame(height: 34)
                        .background(NXColor.primary, in: Capsule())
                        .nxFloatingShadow(scheme)
                    }
                    .buttonStyle(.plain)
                    // Clear of BOTH the dock and the home indicator. 16pt put the capsule
                    // almost on the indicator and 92 had it touching the bar above it —
                    // "贴的太紧" was about a real gap of a few points.
                    .padding(.bottom, discussionSession == nil ? NXSpacing.x12 : 116)
                }
                .transition(.opacity)
            }

            // Reading hides the BAR, not the class. It used to hide both, on the
            // reasoning that reading was eye work with no use for a teacher; reading now
            // asks the same teacher the same way, it just does it by holding a paragraph
            // and shows the exchange under that paragraph. The bar's own controls —
            // hold-to-talk aimed at the playing position, the Live entry — belong to ear
            // work, and the session they talk to is the one reading is already using.
            if let discussionSession, mode.showsPlaybackControls {
                // Edge-to-edge, pinned to the bottom: the bar is part of the page
                // chrome, not a card floating on top of it. No outer padding.
                DiscussionBar(session: discussionSession, player: player)
            }
        }
        .animation(.easeOut(duration: 0.18), value: discussionSession != nil)
        .animation(.easeOut(duration: 0.18), value: following)
    }

    private func transcriptScrollArea(horizontalPadding: CGFloat, contentMaxWidth: CGFloat, bottomInset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcriptContent
                    .frame(maxWidth: contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, horizontalPadding)
                    // Breathing room under the header. Was 64 to clear a floating
                    // search field; with the field gone that much is dead space.
                    .padding(.top, NXSpacing.x4)
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity)
            }
            // What tells us the learner has scrolled away from the playing line.
            //
            // `onManualScroll` existed and was never called from anywhere, so `following`
            // was permanently true and "Back to current" — button, action and all — could
            // never render. This is the missing wire.
            //
            // A gesture-based signal rather than per-row geometry: putting a
            // GeometryReader on TranscriptRow would break its Equatable conformance and
            // bring back the 1400-rebuilds-per-second scrolling problem, which cost real
            // work to fix. `.simultaneously` so it observes without consuming — the
            // ScrollView keeps handling the drag.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        // Vertical only. A sideways drag is the notes-drawer swipe (leftward
                        // past 60pt), and treating that as "reading elsewhere" would drop
                        // following — and reveal "Back to current" — every time the drawer is
                        // opened, which has nothing to do with where the transcript is.
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        onManualScroll()
                    }
            )
            .onChange(of: current?.id) { _, newValue in
                if following, let newValue {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            // Pressing the button has to MOVE the page, now, not just re-arm following.
            //
            // `syncNow()` only set the flag, and the actual scroll lived in the onChange
            // above — which fires when the playing sentence CHANGES. So the button did
            // nothing visible until the next line began, up to several seconds later, and
            // read as broken. This is what makes the press land.
            .onChange(of: syncRequest) { _, _ in
                guard let id = current?.id else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            TranscriptBlock(
                sentences: sentences,
                current: current,
                onSentenceTap: onSentenceTap,
                onShadow: onShadow,
                loop: loop,
                speed: speed,
                onReplay: onReplay,
                onToggleLoop: onToggleLoop,
                onStep: onStep,
                onCycleSpeed: onCycleSpeed,
                mode: mode,
                annotated: annotated,
                learningExpressions: learningExpressions,
                expressionIndex: expressionIndex,
                cardIndex: cardIndex,
                expandedExpressionID: $expandedExpressionID,
                onPracticeExpression: onPracticeExpression,
                noteRows: noteRows,
                expandedCardSentenceIds: expandedCardSentenceIds,
                onToggleCards: onToggleCards,
                onDeleteCard: onDeleteCard,
                readingAsk: readingAsk,
                onHoldStart: onHoldStart,
                onHoldEnd: onHoldEnd,
                onEndConversation: onEndConversation,
                rowActions: rowActions
            )
        }
    }
}

private struct WorkspaceTopBar: View {
    let episode: EpisodeDTO?
    let current: SentenceDTO?
    @ObservedObject var player: LocalAudioPlayback
    let durationMs: Int?
    let audioRefreshState: AudioRefreshState
    let onRefreshAudio: () -> Void
    // Only seeking lives up here now (the scrubber). Play/pause moved to the dock,
    // so this bar no longer starts or stops playback. Seeks still go through an
    // intent rather than the player so a connected class moves the floor.
    var onSeekIntent: (Int) -> Void = { _ in }
    var speed: Double = 1
    var mode: StudyMode = .listening
    let annotated: Bool
    let onToggleAnnotations: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    private var compact: Bool { horizontalSizeClass == .compact }
    private var playing: Bool { player.playbackState == .playing }
    private var progress: Double {
        guard let durationMs, durationMs > 0 else { return 0 }
        return min(1, max(0, Double(player.currentMs) / Double(durationMs)))
    }
    private var displayedMs: Int {
        guard let durationMs, durationMs > 0, isScrubbing else { return player.currentMs }
        return Int(scrubValue * Double(durationMs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            HStack(alignment: .center, spacing: NXSpacing.x3) {
                // Which episode, shown the way the row you tapped showed it. The
                // clock alone said where you were in the audio but never what the
                // audio was — fine on arrival, not after an hour of transcript or
                // a return from the background.
                //
                // The same mark as the library row rather than a second treatment
                // of one thing: recognition is the whole point of an image here.
                if let episode {
                    SourceThumbnail(episode: episode, size: 32)
                }

                // One line, still: title and clock share the row the chevron and
                // clock used to. Stacking the channel under the title is what cost
                // three lines of fixed chrome before, and the title is the part
                // that identifies the episode.
                VStack(alignment: .leading, spacing: 1) {
                    Text(episode?.title ?? "Study")
                        .font(NXFont.subsectionTitle)
                        .foregroundStyle(NXColor.text(scheme))
                        // Truncates rather than wraps: a second line would grow the
                        // bar by the height this redesign set out to reclaim.
                        .lineLimit(1)

                    Text("\(formatTime(displayedMs)) / \(Resume.clockText(durationMs ?? 0))")
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .monospacedDigit()
                }

                Spacer(minLength: NXSpacing.x3)

                // The rate is the one piece of playback state that is otherwise
                // invisible from up here, and only when it is not 1×.
                if let badge = IntensiveListening.speedBadge(speed) {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(NXColor.primary)
                }

                // Names the mode you are IN, not the one you would switch to. The
                // old capsule always read 精读 and used tint to say whether it was
                // on, which meant reading the colour to know where you were.
                Button(action: onToggleAnnotations) {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(mode.label)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(mode == .reading ? NXColor.primary : NXColor.textSecondary(scheme))
                    .padding(.horizontal, NXSpacing.x2)
                    .frame(height: 28)
                    .background(
                        mode == .reading ? NXColor.primary.opacity(0.1) : NXColor.surface2(scheme),
                        in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\u{5f53}\u{524d}\(mode.label)\u{ff0c}\u{5207}\u{6362}\u{5230}\(mode.toggled.label)")

            }

            if shouldShowCompactStatus {
                CompactAudioStatus(audioRefreshState: audioRefreshState, player: player, onRefreshAudio: onRefreshAudio)
            }

        }
        .padding(.horizontal, compact ? NXSpacing.x4 : NXSpacing.x6)
        .padding(.top, compact ? NXSpacing.x3 : NXSpacing.x4)
        .padding(.bottom, (compact ? NXSpacing.x3 : NXSpacing.x4) + 9)
        .background(NXColor.surface1(scheme))
        .overlay(alignment: .bottom) {
            HeaderScrubber(
                progress: isScrubbing ? scrubValue : progress,
                enabled: (durationMs ?? 0) > 0,
                onScrub: { next in
                    scrubValue = next
                    isScrubbing = true
                },
                onCommit: { next in
                    scrubValue = next
                    isScrubbing = false
                    if let durationMs {
                        onSeekIntent(Int(next * Double(durationMs)))
                    }
                }
            )
            .padding(.bottom, -9)
        }
        .onChange(of: player.currentMs) { _, _ in
            if !isScrubbing { scrubValue = progress }
        }
        // The chevron was the only way out that was not a gesture, and the
        // edge-swipe replacing it is hand-rolled (the navigation bar is hidden, so
        // interactivePopGestureRecognizer is off) — VoiceOver cannot perform it.
        // This restores the standard two-finger-Z escape without adding chrome.
        .accessibilityAction(.escape) { dismiss() }
    }

    private var shouldShowCompactStatus: Bool {
        switch audioRefreshState {
        case .idle:
            return player.errorMessage != nil || !player.hasLocalFile
        case .ready:
            return false
        case .refreshing, .processing, .waiting, .failed:
            return true
        }
    }
}

private struct HeaderScrubber: View {
    let progress: Double
    let enabled: Bool
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(1, max(0, progress))
            let width = geometry.size.width
            let x = width * clamped

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.clear)
                Rectangle()
                    .fill(NXColor.border(scheme))
                    .frame(height: 1)
                Rectangle()
                    .fill(NXColor.primary.opacity(enabled ? 0.78 : 0.24))
                    .frame(width: max(0, x), height: 1)
                Circle()
                    .fill(NXColor.primary.opacity(enabled ? 1 : 0.35))
                    .frame(width: dragging ? 8 : 6, height: dragging ? 8 : 6)
                    .offset(x: min(max(0, x - (dragging ? 4 : 3)), max(0, width - (dragging ? 8 : 6))))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled, width > 0 else { return }
                        dragging = true
                        onScrub(min(1, max(0, value.location.x / width)))
                    }
                    .onEnded { value in
                        guard enabled, width > 0 else {
                            dragging = false
                            return
                        }
                        let next = min(1, max(0, value.location.x / width))
                        onCommit(next)
                        dragging = false
                    }
            )
        }
        .frame(height: 18)
        .padding(.horizontal, 0)
        .accessibilityLabel("Playback progress")
    }
}

private struct CompactAudioStatus: View {
    let audioRefreshState: AudioRefreshState
    @ObservedObject var player: LocalAudioPlayback
    let onRefreshAudio: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch audioRefreshState {
        case .refreshing:
            statusText("Checking audio")
        case .processing(let stage, let progress):
            statusText("\(stageDisplayName(stage)) \(progress)%")
        case .waiting:
            actionStatus("Audio preparing")
        case .failed:
            actionStatus("Audio failed")
        case .ready:
            EmptyView()
        case .idle:
            if player.errorMessage != nil || !player.hasLocalFile {
                actionStatus("Audio unavailable")
            } else {
                EmptyView()
            }
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(NXFont.auxiliary)
            .foregroundStyle(NXColor.textTertiary(scheme))
            .lineLimit(1)
    }

    private func actionStatus(_ text: String) -> some View {
        HStack(spacing: NXSpacing.x2) {
            Text(text)
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textTertiary(scheme))
                .lineLimit(1)
            Button("Refresh", action: onRefreshAudio)
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.primary)
                .buttonStyle(.plain)
        }
    }
}

// Touch needs to be acknowledged: a plain button gives no feedback at all, which
// on a phone reads as "did that register?"
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Rebuilds the card indexes when the teacher saves a note.
///
/// The note is written by `LiveClassSession`, so nothing in `StudyView` knows it
/// happened. And it cannot be watched from that view's body: `liveSession` is held in
/// `@State`, which keeps a reference without subscribing to the object, so an `.onChange`
/// there never fires. Observing needs a view that declares `@ObservedObject` — the same
/// trap as `ReadingTurnObserver`, hit twice now.
private struct SavedNoteObserver: View {
    @ObservedObject var session: LiveClassSession
    let onSaved: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: session.savedNotes) { old, new in
                guard new > old else { return }
                onSaved()
            }
    }
}

/// Turns the controller's published changes into reading-conversation events.
///
/// Exists because of an ownership detail with teeth: `StudyView` holds the session in
/// `@State`, which keeps a reference but does NOT subscribe to an ObservableObject. An
/// `.onChange(of: controller.transcript.count)` written there never fires, because that
/// body is not re-evaluated when the controller publishes — the conversation would have
/// stayed empty on screen while working perfectly underneath. Observing requires a view
/// that declares @ObservedObject, so this is that view.
///
/// Renders nothing; it is mounted in a `.background` purely to have somewhere to observe
/// from.

private struct ReadingTurnObserver: View {
    enum Event {
        case heard(String)
        case answered(String)
        case turnEnded
    }

    @ObservedObject var controller: ClassroomController
    /// False when no conversation is open, so turns from listening mode's quick-ask are
    /// ignored rather than appended to a conversation that does not exist.
    let active: Bool
    let onEvent: (Event) -> Void

    var body: some View {
        Color.clear
            // The transcript is the whole episode's and shared with listening mode, so
            // only the newly appended tail belongs to this hold.
            .onChange(of: controller.transcript.count) { old, new in
                guard active, new > old else { return }
                for turn in controller.transcript.suffix(new - old) {
                    switch turn.role {
                    case .user: onEvent(.heard(turn.text))
                    case .assistant: onEvent(.answered(turn.text))
                    case .system: break
                    }
                }
            }
            // A turn ends when the floor LEAVES the learner or the teacher — the
            // transition matters, not the destination.
            //
            // Watching only the new value reported a turn ending before one had begun.
            // `.idle` is also the resting floor between conversations, so a hold that
            // arrived while the floor was settling fired `finished()` on a conversation
            // with no turns in it yet, which is precisely the `misheard` condition:
            // every hold reported "没听清" without a word having been lost.
            .onChange(of: controller.floor) { old, new in
                guard active, old == .teacher || old == .user else { return }
                guard new != .teacher, new != .user else { return }
                onEvent(.turnEnded)
            }
    }
}

// The persistent bottom bar (Doubao-style). Always present over the transcript,
// no connect step and no close button — the session auto-connects in the
// background and stays for the life of the screen. States: connecting → ready
// (a large hold-to-talk button + a Live entry) → error.
private struct DiscussionBar: View {
    @ObservedObject var session: LiveClassSession
    @ObservedObject var player: LocalAudioPlayback

    var body: some View {
        Group {
            if let controller = session.controller {
                ConnectedBarContent(
                    controller: controller,
                    notice: session.notice,
                    connected: session.connected,
                    livePositionMs: player.currentMs,
                    // Live is gated on headphones; read the route at tap time
                    // rather than caching it, since it changes when a cable or
                    // AirPods come and go.
                    liveAvailable: { liveModeAvailable(player.currentRoute()) },
                    onLiveUnavailable: {
                        session.showNotice(liveUnavailableMessage(player.currentRoute()))
                    },
                    playing: player.playbackState == .playing,
                    // A class is connected here, so playback goes through the
                    // controller: taking the floor for the podcast is what
                    // silences the teacher.
                    onPlayIntent: { controller.userStartedPlayback() },
                    onPauseIntent: { controller.userPausedPlayback() }
                )
            } else {
                ConnectingBar(error: session.error)
            }
        }
        // Content stays readable-width and centered on wide screens, but the
        // panel surface itself runs edge-to-edge (see bottomPanel).
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .modifier(BottomPanelChrome())
    }
}

// The bottom bar reads as part of the page, not a card floating on it: a full-
// width panel pinned to the bottom edge, rounded only on top, separated from the
// transcript by the same hairline the transcript uses between rows plus a soft
// upward shadow. Content padding respects the horizontal margin and the home
// indicator safe area.
private struct BottomPanelChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, NXSpacing.x3)
            .padding(.top, NXSpacing.x3)
            .padding(.bottom, NXSpacing.x2)
            .frame(maxWidth: .infinity)
            // The surface extends under the home indicator so the panel reaches
            // the screen edge, but the content above keeps its safe-area inset —
            // the controls never touch the indicator. Only the background ignores
            // the safe area, not the content.
            .background(
                NXColor.surface1(scheme)
                    .overlay(alignment: .top) {
                        Rectangle().fill(NXColor.border(scheme)).frame(height: 1)
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: NXRadius.surface, topTrailingRadius: NXRadius.surface))
                    .shadow(color: Color.black.opacity(scheme == .dark ? 0.28 : 0.06), radius: 8, y: -2)
                    .ignoresSafeArea(edges: .bottom)
            )
    }
}

private struct ConnectedBarContent: View {
    @ObservedObject var controller: ClassroomController
    let notice: String
    let connected: Bool
    let livePositionMs: Int
    // Evaluated at tap time: headphones can be plugged or unplugged at any point.
    var liveAvailable: () -> Bool = { false }
    var onLiveUnavailable: () -> Void = {}
    // Playback state and intents for the in-dock play button.
    var playing: Bool = false
    var onPlayIntent: () -> Void = {}
    var onPauseIntent: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    // `live` = in continuous Live mode; the big button becomes a passive
    // indicator and the Live pill is the way back out. `talking` = a
    // hold-to-talk press is in progress.
    @State private var live = false
    @State private var talking = false
    // Unplugging headphones mid-Live would drop straight into the feedback loop
    // (teacher's voice → mic → VAD → another answer), so leaving the headphone
    // route exits Live automatically.
    private let routeChanged = NotificationCenter.default.publisher(
        for: AVAudioSession.routeChangeNotification)
    // Slide-up-to-cancel: armed once the press drags up past the threshold.
    // Releasing while armed drops the turn instead of sending it.
    @State private var cancelArmed = false

    // Slender: the copy is small throughout, so a shorter capsule reads as one
    // long, calm control rather than a chunky button.
    private let controlHeight: CGFloat = 50

    var body: some View {
        // Surface, edge, and shadow now come from BottomPanelChrome; this is just
        // the content.
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            statusLine
            actions
        }
        // Headphones gone (unplugged, AirPods out) while Live is running: exit
        // immediately. Staying in Live on the speaker means the teacher's voice
        // trips the mic into an endless self-answer loop.
        .onReceive(routeChanged) { _ in
            guard live, !liveAvailable() else { return }
            controller.exitLive()
            live = false
            onLiveUnavailable()
        }
    }

    // One centered status line above the controls: whose turn it is right now.
    private var statusLine: some View {
        HStack(spacing: NXSpacing.x2) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
            Text(line)
                .font(NXFont.control)
                .foregroundStyle(NXColor.textSecondary(scheme))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NXSpacing.x2)
    }

    // One capsule with the hold-to-talk label centered on the WHOLE dock, and the
    // Live icon floating at the left edge (ChatGPT style). Holding anywhere on the
    // capsule talks; the Live glyph is a small tap target layered on top, so it
    // stays independently tappable without pushing the label off-center.
    // Playback on the LEFT, Live on the RIGHT, hold-to-talk filling the middle.
    // The play button lives down here because the one in the top bar is a thumb
    // stretch away on a tall phone.
    //
    // These are laid out side by side rather than layered over the talk area on
    // purpose: a tap target inside a long-press target means a press held 0.2s too
    // long starts a turn instead of toggling playback. Mis-firing playback just
    // starts audio; mis-firing a turn interrupts the teacher, takes the floor and
    // sends a stray turn to the server. So each gesture gets its own region.
    private var actions: some View {
        HStack(spacing: 0) {
            // Present in Live too. Voice can drive playback there ("continue",
            // "pause", "go to 10:30"), but that's a slower path when the learner just
            // wants to stop the audio — and it depends on the model actually calling
            // the tool. The tap stays as the direct, always-works route.
            playSegment
            seam
            talkSegment
            seam
            liveSegment
        }
        .frame(height: controlHeight)
        .background(talkFill, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(live ? 0 : 0.18), lineWidth: 1))
        .scaleEffect(talking ? 1.01 : 1)
        .animation(.easeOut(duration: 0.14), value: talking)
        .animation(.easeOut(duration: 0.14), value: controller.floor)
    }

    // Hairline divider between regions, so the three targets read as separate
    // controls inside one capsule rather than one wide button.
    private var seam: some View {
        Rectangle()
            .fill(seamColor)
            .frame(width: 1, height: controlHeight - 20)
    }

    // Play/pause, mirroring the top bar's button but within thumb reach. Goes
    // through the intent closures, so with a class connected it moves the floor
    // (starting playback silences the teacher) instead of poking the player.
    private var playSegment: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            playing ? onPauseIntent() : onPlayIntent()
        } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(live ? NXColor.text(scheme) : Color.white)
                .frame(width: 52, height: controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(playing ? "暂停" : "播放")
    }

    // Icon-only, no label — the waveform/stop glyph carries the meaning, matching
    // the reference apps. Tapping it toggles Live.
    private var liveSegment: some View {
        Button(action: toggleLive) {
            Image(systemName: live ? "stop.fill" : "waveform")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(live ? NXColor.text(scheme) : Color.white)
                .frame(width: 52, height: controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(live ? "退出 Live" : "进入 Live")
    }

    // The middle action. It takes the space between the play and Live buttons and
    // centers its label in THAT, not in the whole capsule — with a 52pt button on
    // each end, centering on the capsule would read as off-center.
    // Two mutually-exclusive modes:
    //  - Live: passive indicator (no gesture), shows the floor message.
    //  - otherwise (normal / talking): hold-to-talk, which also interrupts the
    //    teacher (pressing to talk IS the interrupt).
    private var talkSegment: some View {
        Text(talkLabel)
            .font(NXFont.controlEmphasis)
            // Only Live uses a surface fill; every other state (including while the
            // teacher answers) is the primary fill, which needs white text.
            .foregroundStyle(live ? NXColor.text(scheme) : Color.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: controlHeight)
            .contentShape(Rectangle())
            .gesture(centerGesture)
            .accessibilityLabel(centerAccessibilityLabel)
            .accessibilityHint(centerAccessibilityHint)
    }

    // Which gesture the center strip carries, by state. nil in Live (passive).
    // Outside Live it is ALWAYS hold-to-talk — including while the teacher is
    // answering, because pressing to talk is itself the interrupt (see
    // pressQuickAsk). No separate interrupt button.
    private var centerGesture: AnyGesture<Void>? {
        if live { return nil }
        return AnyGesture(holdToTalk.map { _ in () })
    }

    // True while the teacher holds the floor outside Live. Only affects wording —
    // the gesture stays hold-to-talk, since a press cuts the teacher off.
    private var teacherAnswering: Bool { !live && controller.floor == .teacher }

    private var seamColor: Color {
        live ? NXColor.border(scheme) : Color.white.opacity(0.22)
    }

    private var talkLabel: String {
        if live { return floorMessage }
        if talking { return cancelArmed ? "松开 取消" : "上滑取消 · 松开发送" }
        // The teacher is talking, but the control is still hold-to-talk: pressing
        // cuts them off and listens. Say so instead of offering a second button.
        if teacherAnswering { return "老师在说 · 按住打断" }
        return "按住 说话"
    }

    // Stays the primary (actionable) fill while the teacher answers — it IS
    // pressable then, so greying it out would read as disabled.
    private var talkFill: Color {
        if live { return NXColor.surface2(scheme) }
        if cancelArmed { return NXColor.error }
        return talking ? NXColor.primary.opacity(0.85) : NXColor.primary
    }

    private var centerAccessibilityLabel: String {
        if live { return "Live 进行中" }
        if teacherAnswering { return "按住 打断老师并说话" }
        return "按住 说话"
    }

    private var centerAccessibilityHint: String {
        if live { return "随时开口;点 Live 退出" }
        if teacherAnswering { return "按住会立刻停下老师并开始听你说,松开发送" }
        return "按住说话,松开发送"
    }

    // A real hold (0.18s) before a turn starts, so a stray tap sends nothing.
    // Release sends and asks for one answer.
    // Drag up past this far (points) to arm cancel. Comfortably above finger
    // jitter, reachable without lifting.
    private let cancelThreshold: CGFloat = 60

    private var holdToTalk: some Gesture {
        LongPressGesture(minimumDuration: 0.18)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case let .second(true, drag) = value else { return }
                if !talking {
                    talking = true
                    cancelArmed = false
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    controller.pressQuickAsk()
                }
                // Negative height = dragging up. Toggle the armed state on
                // threshold crossings, with a light tick each way as feedback.
                let armed = (drag?.translation.height ?? 0) < -cancelThreshold
                if armed != cancelArmed {
                    cancelArmed = armed
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            .onEnded { _ in
                guard talking else { return }
                talking = false
                if cancelArmed {
                    controller.cancelQuickAsk()
                } else {
                    controller.releaseQuickAsk()
                }
                cancelArmed = false
            }
    }

    // Live is only offered on headphones. On the speaker the teacher's own voice
    // reaches the mic and self-triggers the VAD into an endless answer loop, and
    // the mic can't be closed to stop it because an open mic is what Live is (see
    // AudioRouteLogic). Refuse with the reason instead of entering a broken mode.
    private func toggleLive() {
        if live {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            controller.exitLive()
            live = false
            return
        }
        guard liveAvailable() else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            onLiveUnavailable()
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        controller.enterLive()
        live = true
    }

    private var statusDotColor: Color {
        switch controller.floor {
        case .user: return NXColor.primary
        case .teacher: return .orange
        case .player: return .green
        case .idle: return NXColor.textTertiary(scheme)
        }
    }

    // Frozen while the learner holds the floor, so the timestamp stops ticking
    // at the line they interrupted instead of chasing live playback.
    private var cursorMs: Int {
        classroomCursorPosition(livePositionMs, controller.frozenPositionMs, 0)
    }

    private var trimmedNotice: String {
        notice.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var latestTurn: TutorTurn? {
        controller.transcript.last.flatMap {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
    }

    // One line, tiered: a playback action just taken wins (transient,
    // self-clearing), then the latest thing either party said, then a status
    // message. In Live the fallback names the floor holder so a glance tells the
    // learner whose turn it is; outside Live it's the classroom state message.
    private var line: String {
        if !trimmedNotice.isEmpty { return trimmedNotice }
        if let latestTurn { return latestTurn.text }
        return statusMessage
    }

    // Ambient status for the line above the controls — names whose turn it is
    // WITHOUT repeating the button's own instruction (the button already says
    // "按住 说话" / "Live"). In self-study it just reports the mode.
    private var statusMessage: String {
        switch controller.floor {
        case .user: return "在听你说…"
        case .teacher: return "老师在说…"
        case .player: return live ? "播客播放中" : "自学中 · 播客播放中"
        case .idle: return "Live · 等你开口"
        }
    }

    // The big button's label while in Live (it turns passive there). Terse — it
    // sits inside a capsule next to the waveform, so no room for a full sentence.
    private var floorMessage: String {
        switch controller.floor {
        case .user: return "在听你说…"
        case .teacher: return "老师在说…"
        case .player: return "播放中 · 开口插话"
        case .idle: return "直接开口说话"
        }
    }
}

// While the session comes up, or if it failed. No close button — the bar is
// persistent and retries on the next screen visit.
private struct ConnectingBar: View {
    let error: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Surface, edge, and shadow now come from BottomPanelChrome; this is just
        // the content. Kept at the same height as the connected control row so the
        // panel doesn't resize when the session finishes connecting.
        HStack(spacing: NXSpacing.x2) {
            VoiceActivityIcon(phase: error == nil ? .connecting : .ended, connected: false)
            Text(error ?? "正在接通语音老师…")
                .font(NXFont.control)
                .foregroundStyle(error == nil ? NXColor.textSecondary(scheme) : NXColor.error)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 58)
        .padding(.horizontal, NXSpacing.x2)
    }
}

// Three bars whose rhythm says who holds the floor. Driven by the classroom
// phase rather than real audio levels: the phase already carries that fact, and
// the realtime transport stays a pure event pipe.
private struct VoiceActivityIcon: View {
    let phase: ClassroomPhase
    let connected: Bool
    var showsChip: Bool = true
    var tint: Color? = nil
    @State private var pulsing = false

    private struct Rhythm {
        let period: Double
        let rest: CGFloat
        let peaks: [CGFloat]
    }

    private var rhythm: Rhythm? {
        switch phase {
        case .userSpeaking:
            return Rhythm(period: 0.28, rest: 7, peaks: [17, 11, 19])
        case .discussing, .teacherSpeaking:
            return Rhythm(period: 0.5, rest: 8, peaks: [14, 18, 12])
        case .connecting, .resuming:
            return Rhythm(period: 0.8, rest: 6, peaks: [12, 12, 12])
        default:
            // Listening to the source, or ended: at rest, waiting to be interrupted.
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(barColor)
                    .frame(width: 3, height: height(index))
                    .animation(animation(index), value: pulsing)
                    .animation(.easeOut(duration: 0.2), value: phase)
            }
        }
        .frame(width: showsChip ? 28 : 22, height: 28)
        .background(showsChip ? NXColor.primary.opacity(rhythm == nil ? 0.08 : 0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: NXRadius.small))
        .onAppear { pulsing = true }
        .accessibilityHidden(true)
    }

    private var barColor: Color {
        if let tint { return tint.opacity(rhythm == nil ? 0.6 : 1) }
        guard connected || rhythm != nil else { return NXColor.textTertiary(.dark).opacity(0.55) }
        return NXColor.primary.opacity(rhythm == nil ? 0.55 : 1)
    }

    private func height(_ index: Int) -> CGFloat {
        guard let rhythm else { return 8 }
        return pulsing ? rhythm.peaks[index] : rhythm.rest
    }

    private func animation(_ index: Int) -> Animation? {
        guard let rhythm else { return nil }
        return .easeInOut(duration: rhythm.period)
            .repeatForever(autoreverses: true)
            .delay(Double(index) * rhythm.period / 3)
    }
}

private struct TranscriptBlock: View {
    let sentences: [SentenceDTO]
    let current: SentenceDTO?
    let onSentenceTap: (SentenceDTO) -> Void
    let onShadow: (SentenceDTO) -> Void
    var loop: SentenceLoop = .off
    var speed: Double = 1
    var onReplay: () -> Void = {}
    var onToggleLoop: (SentenceDTO) -> Void = { _ in }
    var onStep: (SentenceDTO) -> Void = { _ in }
    var onCycleSpeed: () -> Void = {}
    var mode: StudyMode = .listening
    let annotated: Bool
    let learningExpressions: [LearningExpressionDTO]
    /// Supplied by the owner, not rebuilt here. The player publishes its position
    /// every 200ms, so anything computed in a redraw runs five times a second for
    /// as long as audio plays; the index depends only on the expression list.
    let expressionIndex: LearningExpressionLogic.Index
    /// Same reason, and this one mattered most: grouping cards per row cost 31.6ms
    /// for the transcript, nearly two frames on its own.
    let cardIndex: ParagraphCards.Index
    @Binding var expandedExpressionID: Int?
    let onPracticeExpression: (LearningExpressionDTO) -> Void
    var noteRows: [(id: Int, sentenceId: Int, question: String, answer: String)] = []
    var expandedCardSentenceIds: Set<Int> = []
    var onToggleCards: (Int) -> Void = { _ in }
    var onDeleteCard: (ParagraphCards.Card) -> Void = { _ in }
    var readingAsk: ReadingAsk?
    var onHoldStart: (SentenceDTO) -> Void = { _ in }
    var onHoldEnd: () -> Void = {}
    var onEndConversation: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    /// Handed to every row so `TranscriptRow ==` can compare it by identity rather than
    /// being impossible to write. Owned by `StudyView`, which keeps one for the life of
    /// the screen; see `RowActions` for why the identity has to be stable.
    let rowActions: RowActions

    /// Refreshes the shared mailbox with this evaluation's callbacks, then returns it.
    /// Called once per body, above the row loop — the closures change, the identity does
    /// not, which is exactly the pair of properties the rows need.
    private func currentActions() -> RowActions {
        rowActions.tap = onSentenceTap
        rowActions.shadow = onShadow
        rowActions.replay = onReplay
        rowActions.toggleLoop = onToggleLoop
        rowActions.step = onStep
        rowActions.cycleSpeed = onCycleSpeed
        rowActions.selectExpression = { id in
            expandedExpressionID = expandedExpressionID == id ? nil : id
        }
        rowActions.practiceExpression = onPracticeExpression
        rowActions.toggleCards = onToggleCards
        rowActions.deleteCard = onDeleteCard
        rowActions.holdStart = onHoldStart
        rowActions.holdEnd = onHoldEnd
        rowActions.endConversation = onEndConversation
        return rowActions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            NXSectionHeader(title: "Transcript")
            // Both hints here were wrong. One promised that 精读 content "will be
            // generated when you import or re-parse a video" — nothing generates it any
            // more. The other counted the batch-extracted words and told you to tap a
            // blue one, which stopped opening anything when the links were removed.
            //
            // What is true now: an empty transcript has no notes because none were
            // asked for, and the way to get one is to hold a paragraph and say so.
            if !annotated {
                Text("\u{957f}\u{6309}\u{6bb5}\u{843d}\u{63d0}\u{95ee}\u{ff0c}\u{8bf4}\u{300c}\u{8bb0}\u{4e00}\u{4e0b}\u{300d}\u{5c31}\u{4f1a}\u{5b58}\u{6210}\u{5361}\u{7247}\u{5e76}\u{5728}\u{539f}\u{6587}\u{9ad8}\u{4eae}\u{3002}")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .padding(.bottom, NXSpacing.x2)
            }
            if sentences.isEmpty {
                // Reachable only for an episode with no transcript at all. It used
                // to also cover a search that matched nothing, which is why it read
                // as being about a search.
                Text("\u{8fd9}\u{4e2a}\u{8282}\u{76ee}\u{8fd8}\u{6ca1}\u{6709}\u{6587}\u{7a3f}\u{3002}")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .padding(.vertical, NXSpacing.x4)
            } else {
                // Refreshed once here, not per row: the identity the rows compare must
                // be one instance for the whole list.
                let actions = currentActions()
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Enumerated, so a row's neighbours are an index step rather
                    // than a search. previousSentence/nextSentence each ran
                    // firstIndex(where:) over all 681 sentences, for every visible
                    // row, on every redraw — two more full scans per row on top of
                    // the expression scan.
                    //
                    // They only feed the listening controls, which reading never
                    // shows, so reading skips them entirely.
                    ForEach(Array(sentences.enumerated()), id: \.element.id) { offset, sentence in
                        let selected = sentence.id == current?.id
                        let stepping = selected && mode.showsPlaybackControls
                        let previous = stepping && offset > 0 ? sentences[offset - 1] : nil
                        let next = stepping && offset + 1 < sentences.count ? sentences[offset + 1] : nil
                        TranscriptRow(
                            sentence: sentence,
                            selected: selected,
                            actions: actions,
                            // Only the selected row uses these, and only it should
                            // depend on them: passing the live speed and loop state
                            // to all 681 rows meant every rate change, and every
                            // 200ms position tick, re-evaluated the whole list to
                            // discover that 679 rows had not changed.
                            looping: selected && loop.isLooping(sentence),
                            speed: selected ? speed : 1,
                            canStepBack: previous != nil,
                            canStepForward: next != nil,
                            mode: mode,
                            annotated: annotated,
                            // Indexed, and only for rows that actually carry a
                            // highlight: the scan-every-expression version ran for
                            // every visible row on every frame.
                            // Always at least one segment: an empty list renders an
                            // empty Text, so a cold index would blank the whole
                            // transcript for a frame. Rows with no highlight skip
                            // the segmentation entirely and pass the line as-is.
                            expressionSegments: annotated && expressionIndex.has(sentenceId: sentence.id)
                                ? LearningExpressionLogic.segments(
                                    for: sentence.sourceText, sentenceId: sentence.id, index: expressionIndex)
                                : [.init(text: sentence.sourceText, expressionID: nil)],
                            expandedExpression: expandedExpressionID.flatMap { id in
                                learningExpressions.first { $0.id == id }
                            },
                            cards: cardIndex.cards(for: sentence.id),
                            cardsExpanded: expandedCardSentenceIds.contains(sentence.id),
                            // Only the paragraph being talked about carries the
                            // conversation, so every other row is unchanged by it.
                            ask: readingAsk?.sentenceId == sentence.id ? readingAsk : nil,
                            previous: previous,
                            next: next
                        )
                        // The row is Equatable, so this is what lets an unchanged one be
                        // skipped instead of rebuilt. Without it the conformance is
                        // inert: SwiftUI only consults == through EquatableView.
                        .equatable()
                        .id(sentence.id)
                        // By index: `sentences.last` walks the array for every
                        // row, on every redraw.
                        if offset + 1 < sentences.count {
                            Divider().overlay(NXColor.border(scheme))
                        }
                    }
                }
            }
        }
    }
}

/// Everything a transcript row can do, as one reference the rows share.
///
/// Exists so `TranscriptRow` can be `Equatable`. It carried fourteen closures, and
/// closures are not comparable — so SwiftUI could never find a row equal to itself and
/// rebuilt every visible one whenever the parent re-evaluated. Measured while scrolling:
/// 843-1344 row bodies per second, against 4-8 at rest.
///
/// A class, not a struct, so identity is the comparison: one instance is made per
/// transcript and every row points at the same one, which makes `==` a pointer check
/// rather than something that cannot be written at all.
///
/// Every action takes its subject as a PARAMETER. That is the load-bearing rule, not a
/// style choice: an equal row keeps the actions it was built with, so a closure that had
/// captured this row's sentence — or the loop and speed of the moment — would go on
/// acting on stale values after the row was skipped. Nothing per-row is captured here,
/// so there is nothing to go stale.
/// A mailbox, deliberately: one instance lives for the screen's lifetime while its
/// contents are replaced on every body evaluation.
///
/// Both halves are load-bearing, and each fixes what the other would break.
///
/// The identity must be STABLE, because rows compare it with `===`. Handing out a fresh
/// instance per body would leave every row unequal to itself, the conformance would be
/// decoration, and the rebuilds would continue exactly as they do today.
///
/// The closures must be CURRENT, because they are rebuilt by the parent on every body
/// evaluation and the newer ones may close over newer state. Freezing the set from first
/// appearance would leave rows acting on a stale snapshot — a subtler bug than the one
/// being fixed, and much harder to see.
private final class RowActions {
    var tap: (SentenceDTO) -> Void = { _ in }
    var shadow: (SentenceDTO) -> Void = { _ in }
    var replay: () -> Void = {}
    var toggleLoop: (SentenceDTO) -> Void = { _ in }
    var step: (SentenceDTO) -> Void = { _ in }
    var cycleSpeed: () -> Void = {}
    var selectExpression: (Int) -> Void = { _ in }
    var practiceExpression: (LearningExpressionDTO) -> Void = { _ in }
    var toggleCards: (Int) -> Void = { _ in }
    var deleteCard: (ParagraphCards.Card) -> Void = { _ in }
    var holdStart: (SentenceDTO) -> Void = { _ in }
    var holdEnd: () -> Void = {}
    var endConversation: () -> Void = {}
}

private struct TranscriptRow: View, Equatable {
    let sentence: SentenceDTO
    let selected: Bool
    /// Shared by every row, compared by identity. See `RowActions`.
    let actions: RowActions
    // Intensive-listening controls, shown only under the sentence being played.
    var looping: Bool = false
    var speed: Double = 1
    var canStepBack: Bool = true
    var canStepForward: Bool = true
    var mode: StudyMode = .listening
    let annotated: Bool
    let expressionSegments: [LearningExpressionLogic.Segment]
    let expandedExpression: LearningExpressionDTO?
    var cards: [ParagraphCards.Card] = []
    var cardsExpanded: Bool = false
    /// The conversation about THIS paragraph, or nil when it is about another one.
    var ask: ReadingAsk?
    /// The neighbours a step moves to. Values rather than closures over them, so the row
    /// stays comparable; nil when this row is not the one showing the controls.
    var previous: SentenceDTO?
    var next: SentenceDTO?
    @Environment(\.colorScheme) private var scheme

    /// Compares only what the row DRAWS. `actions` is identical for every row, and
    /// `scheme` is an environment value SwiftUI already invalidates on.
    static func == (a: TranscriptRow, b: TranscriptRow) -> Bool {
        a.sentence == b.sentence
            && a.selected == b.selected
            && a.looping == b.looping
            && a.speed == b.speed
            && a.canStepBack == b.canStepBack
            && a.canStepForward == b.canStepForward
            && a.mode == b.mode
            && a.annotated == b.annotated
            && a.expressionSegments == b.expressionSegments
            && a.expandedExpression == b.expandedExpression
            && a.cards == b.cards
            && a.cardsExpanded == b.cardsExpanded
            && a.ask == b.ask
            && a.previous?.id == b.previous?.id
            && a.next?.id == b.next?.id
            && a.actions === b.actions
    }
    /// Set the instant a finger lands, cleared shortly after it lifts. Without it
    /// neither gesture acknowledged anything: reading has no buttons, so the text
    /// itself has to say it was touched.
    @State private var pressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Whether a row carries the ask-by-holding gesture is a MODE question, not a
            // content one. It used to hang off `annotated`, so an episode with no
            // highlights had no gesture at all and holding did nothing by construction —
            // survivable only while reading was the default and you entered it on
            // annotated episodes. `readingContent` renders plain text when there is
            // nothing to mark (see `attributed`), so the content branch is gone.
            //
            // Listening keeps its hold for the DOCK, which asks about wherever playback
            // is. Two hold targets under one finger is one too many: a press on the text
            // and a press on the bar would start competing turns, and the row would win
            // the ones aimed at neither. So in listening the row is a plain tap — play
            // this line — and asking belongs to the bar.
            if mode.showsPlaybackControls {
                readingContent
                    .contentShape(Rectangle())
                    .onTapGesture {
                        flashPress()
                        actions.tap(sentence)
                    }
            } else {
                readingContent
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // A brief flash, distinct from the sustained tint a hold
                        // gets: one says "registered", the other says "listening".
                        flashPress()
                        actions.tap(sentence)
                    }
                    .onLongPressGesture(
                        minimumDuration: 0.35,
                        perform: {
                            // Recording starts HERE, not on the press. `onPressingChanged`
                            // fires the instant a finger lands — before the threshold, and
                            // therefore on every scroll — and starting the recorder there
                            // put `AVAudioSession.setActive` plus an `AVAudioRecorder` on
                            // the main thread at the start of every swipe: measured on
                            // device at 203-353ms a touch, ten touches over one scroll.
                            // That was the reading-mode stutter.
                            //
                            // The haptic belongs at the same moment for the same reason it
                            // always did: the threshold passing is when the hold became a
                            // question, and now it is also when the mic opened.
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            actions.holdStart(sentence)
                        },
                        onPressingChanged: { pressing in
                            // Release still has to be seen here — `perform:` fires once
                            // the threshold passes with no matching release. A release
                            // with no recording in flight is a no-op, which is what a
                            // scroll or a tap now produces.
                            pressed = pressing
                            if !pressing { actions.holdEnd() }
                        })
            }

            // The live conversation, above the settled cards: it is what is happening
            // now, and it may yet become one of them.
            conversation

            // Collapsed to one line by default. A paragraph can carry several
            // cards — a word looked up, then a question about the grammar, then one
            // about the argument — and stacking them all open pushes the text you
            // are reading off the screen.
            if annotated, !cards.isEmpty {
                cardStack
            }

            // One row, on one sentence. Putting these in the bottom bar would mean
            // seven controls in a 50pt capsule; putting them on every row would
            // repeat them hundreds of times. The sentence you are working on is
            // the only place they mean anything.
            //
            // Reading shows none of them: a page you are reading with a button bar
            // under one line is a page with a button bar in it. Tap plays, hold
            // asks, and the gestures carry what the buttons used to.
            if selected, mode.showsPlaybackControls {
                controlRow
            }
        }
        // One background and one tint for four states. Every row carried two
        // backgrounds, two overlays and two animations whose values are constant for
        // all but the one or two rows that are selected, pressed or being asked
        // about — and each modifier is a node SwiftUI walks per row, per frame.
        .background(rowTint)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(NXColor.primary).frame(width: 2)
            }
        }
        .animation(.easeOut(duration: 0.12), value: pressed)
    }

    /// Held while asking, the paragraph lifts instead of a sheet covering it, so the
    /// text stays in front of you. `pressed` is the lighter, shorter-lived version —
    /// the finger is down but the hold has not yet become a question — and
    /// `selected` is faintest, since it merely follows playback.
    private var rowTint: Color {
        if ask != nil { return NXColor.primary.opacity(0.10) }
        if pressed { return NXColor.primary.opacity(0.06) }
        if selected { return NXColor.primary.opacity(0.045) }
        return .clear
    }

    @ViewBuilder private var cardStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A tap gesture, not a Button. The summary is the ONLY thing a collapsed
            // stack draws, and it is drawn for every card row on every rebuild — a
            // Button brings hit testing and its own accessibility element to each one.
            // Measured at 130-282 stack rebuilds per second while scrolling. Same
            // reasoning as the highlight links, which were removed for the same cost.
            HStack(spacing: NXSpacing.x2) {
                Text(ParagraphCards.summary(count: cards.count) ?? "")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.primary)
                Spacer(minLength: 0)
                Image(systemName: cardsExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NXColor.textTertiary(scheme))
            }
            .padding(.vertical, NXSpacing.x2)
            .contentShape(Rectangle())
            .onTapGesture { actions.toggleCards(sentence.id) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(ParagraphCards.summary(count: cards.count) ?? "")
            .accessibilityHint(cardsExpanded
                               ? "\u{6536}\u{8d77}\u{5361}\u{7247}"
                               : "\u{5c55}\u{5f00}\u{5361}\u{7247}")

            if cardsExpanded {
                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    ForEach(cards) { card in
                        switch card {
                        case .expression(let expression):
                            ExpressionInlineCard(
                                expression: expression,
                                onPractice: { actions.practiceExpression(expression) },
                                onDelete: card.isDeletable ? { actions.deleteCard(card) } : nil)
                        case .note(_, let question, let answer):
                            ParagraphNoteCard(
                                question: question, answer: answer,
                                onDelete: { actions.deleteCard(card) })
                        }
                    }
                }
                .padding(.bottom, NXSpacing.x2)
            }
        }
        .padding(.horizontal, NXSpacing.x4)
        .padding(.bottom, NXSpacing.x2)
    }

    /// Tints the row briefly, so a tap is acknowledged even though reading mode
    /// shows no buttons to depress.
    private func flashPress() {
        pressed = true
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            pressed = false
        }
    }

    /// The conversation about this paragraph: what was heard, what came back, and
    /// which of those is still pending.
    ///
    /// Sits under the text rather than over it. A sheet would cover the paragraph being
    /// discussed, which is the one thing that must stay visible while discussing it.
    @ViewBuilder private var conversation: some View {
        if let ask {
            VStack(alignment: .leading, spacing: NXSpacing.x2) {
                ForEach(Array(ask.turns.enumerated()), id: \.offset) { _, turn in
                    HStack(alignment: .top, spacing: NXSpacing.x2) {
                        // The learner's turn is marked, and shown VERBATIM as the server
                        // heard it. Without it, an answer to a misheard question is
                        // indistinguishable from a wrong answer.
                        Image(systemName: turn.role == .user ? "person.fill" : "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(turn.role == .user ? NXColor.textTertiary(scheme) : NXColor.primary)
                            .frame(width: 12)
                        Text(turn.text)
                            .font(NXFont.auxiliary)
                            .foregroundStyle(turn.role == .user
                                             ? NXColor.textSecondary(scheme)
                                             : NXColor.text(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                phaseRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(NXSpacing.x3)
            .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.control))
            .padding(.top, NXSpacing.x2)
            .transition(.opacity)
        }
    }

    /// What is happening right now, in words. `waiting` is the state the old flow had
    /// no representation for: release cleared the waveform and left the page looking
    /// idle for several seconds, so there was no way to tell a slow answer from a
    /// dropped one.
    @ViewBuilder private var phaseRow: some View {
        if let ask {
            HStack(spacing: NXSpacing.x2) {
                switch ask.phase {
                case .recording:
                    Circle().fill(NXColor.primary).frame(width: 6, height: 6)
                    Text("\u{5728}\u{542c}\u{2026}")
                case .waiting:
                    ProgressView().controlSize(.mini)
                    Text("\u{5728}\u{60f3}\u{2026}")
                case .answering:
                    EmptyView()
                case .misheard:
                    Text("\u{6ca1}\u{542c}\u{6e05}\u{ff0c}\u{518d}\u{957f}\u{6309}\u{8bf4}\u{4e00}\u{904d}\u{3002}")
                case .idle:
                    // Closing no longer decides whether a card is kept — asking does, and
                    // the card is already written by then. So this is just "I'm done
                    // here", and the hint says what actually keeps something.
                    Button(action: actions.endConversation) {
                        Text("\u{6536}\u{8d77}")
                            .font(NXFont.auxiliary)
                            .foregroundStyle(NXColor.primary)
                    }
                    .buttonStyle(.plain)
                    Text("\u{7ee7}\u{7eed}\u{957f}\u{6309}\u{8ffd}\u{95ee}\u{ff0c}\u{6216}\u{8bf4}\u{300c}\u{8bb0}\u{4e00}\u{4e0b}\u{300d}\u{5b58}\u{6210}\u{5361}\u{7247}")
                }
            }
            .font(NXFont.auxiliary)
            .foregroundStyle(NXColor.textTertiary(scheme))
        }
    }

    private var timestamp: some View {
        Text(formatTime(sentence.startMs))
            .font(NXFont.auxiliary)
            .foregroundStyle(selected ? NXColor.primary : NXColor.textTertiary(scheme))
            .monospacedDigit()
            .frame(width: 52, alignment: .leading)
    }

    private var readingContent: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            timestamp
            VStack(alignment: .leading, spacing: NXSpacing.x2) {
                InlineExpressionText(
                    segments: expressionSegments,
                    onSelect: actions.selectExpression,
                    selected: selected)
                chineseText
            }
        }
        // Tighter under a selected line, so the control row beneath it reads as belonging
        // to that line rather than floating between two. Inherited from the listening
        // variant this replaced.
        .padding(.top, NXSpacing.x4).padding(.bottom, selected ? NXSpacing.x2 : NXSpacing.x4)
        .padding(.leading, NXSpacing.x4).padding(.trailing, NXSpacing.x2)
    }

    @ViewBuilder private var chineseText: some View {
        if !sentence.chinese.isEmpty {
            Text(sentence.chinese).font(NXFont.body).foregroundStyle(NXColor.textSecondary(scheme)).lineSpacing(2)
        }
    }

    /// Listening only. Reading shows no control row at all — tap plays, hold asks —
    /// so there is nothing to branch on here.
    private var controlRow: some View {
        HStack(spacing: NXSpacing.x1) {
            action("arrow.left.to.line", "上一句", enabled: canStepBack, action: { if let previous { actions.step(previous) } })
            action("arrow.counterclockwise", "重听这句", action: actions.replay)
            action("repeat", "循环这句", on: looping, action: { actions.toggleLoop(sentence) })
            action("waveform.badge.mic", "跟读", action: { actions.shadow(sentence) })

            // The rate lives on a label rather than an icon: the current value IS
            // the information, and it only differs from 1× when you changed it.
            Button(action: actions.cycleSpeed) {
                Text(IntensiveListening.speedBadge(speed) ?? "1×")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(speed == 1 ? NXColor.textSecondary(scheme) : NXColor.primary)
                    .frame(height: 32)
                    .padding(.horizontal, NXSpacing.x2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("播放速度 \(IntensiveListening.speedBadge(speed) ?? "1×")")

            Spacer(minLength: 0)

            action("arrow.right.to.line", "下一句", enabled: canStepForward, action: { if let next { actions.step(next) } })
        }
        .padding(.leading, NXSpacing.x4)
        .padding(.trailing, NXSpacing.x2)
        .padding(.bottom, NXSpacing.x3)
    }

    @ViewBuilder
    private func action(
        _ systemName: String,
        _ label: String,
        on: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint(on: on, enabled: enabled))
                // 32pt tall, 36 wide: below Apple's 44pt ideal, but these sit
                // inside a row the learner is already looking at, and full-size
                // targets here would push the next sentence off screen.
                .frame(width: 36, height: 32)
                .background(on ? NXColor.primary.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: NXRadius.small))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func tint(on: Bool, enabled: Bool) -> Color {
        if !enabled { return NXColor.textTertiary(scheme).opacity(0.4) }
        return on ? NXColor.primary : NXColor.textSecondary(scheme)
    }
}

private struct InlineExpressionText: View {
    let segments: [LearningExpressionLogic.Segment]
    let onSelect: (Int) -> Void
    /// The line being played is weighted, which is how you find your place after looking
    /// away. It used to come from `listeningContent`; that variant is gone, so the weight
    /// has to be carried here or every line would look the same.
    var selected: Bool = false
    @Environment(\.colorScheme) private var scheme

    // One native Text, not a subview per word. Wrapping is SwiftUI's job: the
    // hand-rolled flow this replaced could only break *between* subviews, so a
    // long run overflowed the row instead of wrapping. Highlighted expressions
    // carry a custom-scheme link that OpenURLAction turns back into a selection,
    // which is what lets a single Text hold many tap targets.
    /// True when this line carries no highlight, which is most of them: 209
    /// expressions over 681 sentences leaves roughly two thirds plain.
    private var isPlain: Bool {
        segments.count == 1 && segments[0].expressionID == nil
    }

    var body: some View {
        if isPlain {
            // A plain line needs no AttributedString at all. Building one for every
            // row meant paying the annotated path on the majority of rows with
            // nothing annotated.
            Text(segments[0].text)
                .font(NXFont.body)
                .fontWeight(selected ? .medium : .regular)
                .foregroundStyle(NXColor.text(scheme))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // Styled runs, and no link. A link makes SwiftUI treat the Text as
            // interactive, and that machinery is what an episode with expressions
            // paid on every row of every frame — the difference the learner noticed
            // between a transcript with highlights and one without. Building the
            // string is not the cost (0.148ms for a screenful); rendering an
            // interactive one is.
            //
            // Nothing is lost: the card stack under each paragraph lists every card,
            // so tapping a highlight had become a second door to the same room.
            // No .font or .foregroundStyle here. A view-level modifier OVERRIDES the
            // per-run attributes of an AttributedString, so setting either one flattened
            // the highlight back to body text: the runs were computed correctly, coloured
            // correctly, and then styled out of existence one line later. The base style
            // for unhighlighted runs is set inside `attributed` instead.
            Text(attributed)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The line, with its highlighted runs in the accent colour.
    ///
    /// Both the base style AND the highlight live in here. They have to: a `.font` or
    /// `.foregroundStyle` applied to the `Text` overrides every run's own attributes, so
    /// styling the view flattened the highlights away — which is exactly what made a
    /// correctly-saved card show no colour in the transcript.
    private var attributed: AttributedString {
        var output = LearningExpressionLogic.attributedSentence(segments: segments) { run in
            run.foregroundColor = NXColor.primary
            run.font = NXFont.body.weight(.semibold)
            run.underlineStyle = nil
        }
        // Applied only where the highlight left them unset, so it cannot undo the accent.
        for run in output.runs where run.attributes.foregroundColor == nil {
            output[run.range].foregroundColor = NXColor.text(scheme)
        }
        for run in output.runs where run.attributes.font == nil {
            output[run.range].font = NXFont.body
        }
        return output
    }
}

/// A free-form question and its answer.
///
/// Deliberately plainer than a vocabulary card: there is no pronunciation to show,
/// nothing to shadow, and no highlight in the text above — the subject was the
/// passage, so the card is just what was asked and what came back.
/// Every note on this episode, in one place, reachable from the right edge.
///
/// The cards already exist under their paragraphs, so this is not a second home for them
/// — it is the answer to "what have I actually collected here", which the transcript
/// cannot give: the notes are scattered across hundreds of lines, and finding one means
/// remembering where it was.
///
/// Scoped to the current episode on purpose. A cross-episode review surface belongs on
/// the home tab, not inside one episode.
private struct NotesDrawer: View {
    let expressions: [LearningExpressionDTO]
    let notes: [(id: Int, sentenceId: Int, question: String, answer: String)]
    /// Where each card sits in the transcript, so tapping one can jump there.
    let sentenceStarts: [Int: Int]
    let onDelete: (ParagraphCards.Card) -> Void
    let onClear: () -> Void
    let onJump: (Int) -> Void
    let onPractice: (LearningExpressionDTO) -> Void
    let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var confirmingClear = false

    /// Only what the learner made can be cleared, so the button hides when there is
    /// nothing of theirs — offering it on an episode of purely automatic cards would
    /// promise an action that does nothing.
    private var clearableCount: Int {
        expressions.filter { $0.source == "manual" }.count + notes.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expressions.isEmpty && notes.isEmpty {
                NXEmptyState(
                    title: "\u{8fd8}\u{6ca1}\u{6709}\u{7b14}\u{8bb0}",
                    message: "\u{957f}\u{6309}\u{6bb5}\u{843d}\u{63d0}\u{95ee}\u{ff0c}\u{7136}\u{540e}\u{8bf4}\u{300c}\u{8bb0}\u{4e00}\u{4e0b}\u{300d}\u{ff0c}\u{5361}\u{7247}\u{4f1a}\u{51fa}\u{73b0}\u{5728}\u{8fd9}\u{91cc}\u{3002}")
                    .padding(.horizontal, NXSpacing.x4)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NXColor.background(scheme))
    }

    private var header: some View {
        HStack(spacing: NXSpacing.x3) {
            Button(action: onClose) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\u{6536}\u{8d77}\u{7b14}\u{8bb0}")

            Text("\u{7b14}\u{8bb0}")
                .font(NXFont.subsectionTitle)
                .foregroundStyle(NXColor.text(scheme))
            Spacer(minLength: 0)
            if clearableCount > 0 {
                Button { confirmingClear = true } label: {
                    Text("\u{6e05}\u{7a7a}")
                        .font(NXFont.auxiliary)
                        // The system red, not a design-system token: there is no danger
                        // colour in NXColor, and inventing one for a single label would
                        // put a second opinion about "destructive" in the codebase.
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, NXSpacing.x4)
        .padding(.vertical, NXSpacing.x3)
        // Destructive and not obviously reversible, so it asks. The count is in the
        // question because "clear notes" reads very differently at 2 and at 40.
        .confirmationDialog(
            "\u{6e05}\u{7a7a} \(clearableCount) \u{6761}\u{7b14}\u{8bb0}\u{ff1f}",
            isPresented: $confirmingClear, titleVisibility: .visible
        ) {
            Button("\u{6e05}\u{7a7a}", role: .destructive, action: onClear)
            Button("\u{53d6}\u{6d88}", role: .cancel) {}
        } message: {
            Text("\u{81ea}\u{52a8}\u{6807}\u{6ce8}\u{7684}\u{91cd}\u{70b9}\u{4e0d}\u{4f1a}\u{88ab}\u{5220}\u{9664}\u{3002}")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: NXSpacing.x3) {
                ForEach(expressions) { expression in
                    row(sentenceId: expression.occurrences.first?.sentenceId) {
                        ExpressionInlineCard(
                            expression: expression,
                            onPractice: { onPractice(expression) },
                            onDelete: expression.source == "manual"
                                ? { onDelete(.expression(expression)) }
                                : nil)
                    }
                }
                ForEach(notes, id: \.id) { note in
                    row(sentenceId: note.sentenceId) {
                        ParagraphNoteCard(
                            question: note.question, answer: note.answer,
                            onDelete: { onDelete(.note(id: note.id, question: note.question, answer: note.answer)) })
                    }
                }
            }
            .padding(.horizontal, NXSpacing.x4)
            .padding(.bottom, NXSpacing.x8)
        }
    }

    /// A card plus the line it came from. Tapping jumps there and closes the drawer:
    /// a note usually raises the question "what was that in", and the answer is the
    /// transcript.
    @ViewBuilder private func row<Content: View>(
        sentenceId: Int?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: NXSpacing.x1) {
            if let sentenceId, let startMs = sentenceStarts[sentenceId] {
                Button { onJump(startMs) } label: {
                    HStack(spacing: NXSpacing.x1) {
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text(formatTime(startMs)).monospacedDigit()
                    }
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            content()
        }
    }
}

private struct ParagraphNoteCard: View {
    let question: String
    let answer: String
    let onDelete: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            HStack(alignment: .firstTextBaseline, spacing: NXSpacing.x2) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NXColor.textTertiary(scheme))
                Text(question.isEmpty ? "\u{63d0}\u{95ee}" : question)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                CardDeleteButton(action: onDelete)
            }
            Text(answer)
                .font(NXFont.body)
                .foregroundStyle(NXColor.text(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NXSpacing.x3)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
        .overlay(
            RoundedRectangle(cornerRadius: NXRadius.surface)
                .stroke(NXColor.border(scheme), lineWidth: 1))
    }
}

private struct CardDeleteButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NXColor.textTertiary(scheme))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\u{5220}\u{9664}\u{5361}\u{7247}")
    }
}

private struct ExpressionInlineCard: View {
    let expression: LearningExpressionDTO
    let onPractice: () -> Void
    /// Nil for cards from batch extraction: a reprocess replaces those, so a delete
    /// would not stay deleted and offering one would be a lie.
    var onDelete: (() -> Void)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            HStack(alignment: .firstTextBaseline) {
                Text(expression.text).font(NXFont.bodyMedium).foregroundStyle(NXColor.text(scheme))
                if let pronunciation = expression.pronunciation, !pronunciation.isEmpty {
                    Text("/\(pronunciation)/").font(NXFont.auxiliary).foregroundStyle(NXColor.textTertiary(scheme))
                }
                Spacer()
                Text(ExpressionCardCopy.typeLabel(expression.type))
                    .font(NXFont.auxiliary).foregroundStyle(NXColor.primary)
                if let onDelete {
                    CardDeleteButton(action: onDelete)
                }
            }
            Text(expression.chinese).font(NXFont.body).foregroundStyle(NXColor.textSecondary(scheme))

            // A reduction or an ellipsis is only worth a card because of the gap
            // between what reached the ear and what was said, so that comparison
            // leads rather than sitting below the gloss.
            // The sense group: the unit a native speaker takes in at once. Shown before
            // anything explanatory, because knowing where the expression BEGINS and ENDS is
            // what makes it usable — "throw shade" alone leaves you unable to build a
            // sentence with it.
            if let group = expression.restored {
                labelled("\u{6574}\u{5757}", group, mono: true)
            }

            // The misreading, named beside the real meaning. This is the whole point of a
            // card for a word you already "know": every word familiar, the reading still
            // wrong, and nothing to prompt you to check. Naming it is what prevents it.
            if let literal = expression.heardAs {
                wrongReading(literal)
            }

            if let mistake = expression.commonMistake {
                mistakeContrast(wrong: mistake, right: expression.text)
            }
            // "为什么难" is gone. It explained a difficulty the learner had already felt —
            // they stopped to ask — and one sentence only ever produced a label like
            // "弱读脱落". Nothing populates whyHard now.
            //
            // "什么时候用" became "怎么用": the old prompt said only "Give when_to_use" and
            // got "日常对话中使用" back, which is true of everything. It now carries the
            // frame — what comes before, what comes after.
            if let usage = expression.whenToUse {
                labelled("\u{600e}\u{4e48}\u{7528}", usage)
            }

            VStack(alignment: .leading, spacing: NXSpacing.x1) {
                Text(expression.example).font(NXFont.bodyMedium).foregroundStyle(NXColor.text(scheme))
                Text(expression.exampleChinese).font(NXFont.auxiliary).foregroundStyle(NXColor.textSecondary(scheme))
            }
            Button("跟读例句并评测", action: onPractice)
                .font(NXFont.control).foregroundStyle(NXColor.primary).buttonStyle(.plain)
        }
        .padding(NXSpacing.x4)
        .background(NXColor.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: NXRadius.surface))
        .overlay(RoundedRectangle(cornerRadius: NXRadius.surface).stroke(NXColor.primary.opacity(0.16), lineWidth: 1))
    }

    /// Heard on the left, actually said on the right — the whole point of the item.
    /// The reading you would have arrived at, marked as the wrong one.
    ///
    /// Replaces the old heard-versus-actual arrow, which assumed a MISHEARING. The failure
    /// this card now covers is different and more invisible: nothing was misheard, the
    /// everyday sense was simply the wrong one here.
    private func wrongReading(_ literal: String) -> some View {
        HStack(alignment: .top, spacing: NXSpacing.x2) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NXColor.textTertiary(scheme))
            VStack(alignment: .leading, spacing: 1) {
                Text("\u{5bb9}\u{6613}\u{7406}\u{89e3}\u{6210}")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
                Text(literal)
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, NXSpacing.x1)
        .accessibilityLabel("容易理解成 \(literal)")
    }

    /// The Chinese-English attempt this replaces. Dictionaries cannot give this.
    private func mistakeContrast(wrong: String, right: String) -> some View {
        VStack(alignment: .leading, spacing: NXSpacing.x1) {
            Label(wrong, systemImage: "xmark")
                .font(NXFont.auxiliary).foregroundStyle(NXColor.error)
            Label(right, systemImage: "checkmark")
                .font(NXFont.auxiliary).foregroundStyle(NXColor.primary)
        }
        .accessibilityLabel("常见错误 \(wrong)，正确说法 \(right)")
    }

    @ViewBuilder private func labelled(_ title: String, _ body: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: NXSpacing.x1) {
            Text(title).font(NXFont.auxiliary).foregroundStyle(NXColor.textTertiary(scheme))
            Text(body)
                .font(NXFont.auxiliary).foregroundStyle(NXColor.textSecondary(scheme))
                .monospaced(mono)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func stageDisplayName(_ stage: String) -> String {
    switch stage {
    case "metadata":
        return "Reading source"
    case "audio", "audio_backfill":
        return "Preparing audio"
    case "transcription":
        return "Generating transcript"
    case "translation":
        return "Translating"
    case "indexing":
        return "Preparing discussion"
    case "complete":
        return "Complete"
    default:
        return stage.replacingOccurrences(of: "_", with: " ").capitalized
    }
}


#endif
