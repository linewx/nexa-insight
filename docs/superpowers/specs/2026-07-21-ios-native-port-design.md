# Nexa Insight — iOS Native Port Design

Date: 2026-07-21

## Goal

Rebuild the `nexa_insight` desktop web app (Nexa Insight) as a native iOS app
in a **new, self-contained project** (`nexa_insight_ios/`) that does not
depend on or modify the original `nexa_insight` project.

The app is **single-user (personal use only)**. Because of this, the entire
reason the original backend proxied realtime traffic — protecting a long-lived
API key from clients — goes away. The user's API keys live in the iOS Keychain,
and the phone talks to remote AI APIs directly.

The result: a **thin backend** does only the heavy import/transcription work
(YouTube download, transcription, translation, chaptering) that cannot run on a
phone. Once an episode is imported and downloaded to the phone, **the classroom
and all study features run entirely on-device + direct-to-remote-AI, with no
connection to the user's own backend.**

## Architecture

```
nexa_insight_ios/                    ← new, independent project; does NOT touch nexa_insight
├── backend/          Thin backend (Python, trimmed & copied from the existing pipeline)
│   └── Sole job: YouTube URL → import/transcribe → packaged episode for the phone to pull
└── ios/              iOS app (Swift/SwiftUI). After import, fully local + direct-to-remote-AI.
```

### Runtime data flow

```
① Import (occasional connection to the backend)
   iPhone ──YouTube URL──▶ backend
   backend: yt-dlp download → captions/transcription → translation → chapters
   backend ──packaged episode (mp3 audio + bilingual sentences JSON)──▶ iPhone local storage

② Class / study (NO connection to the user's own backend)
   iPhone local:  audio playback + bilingual subtitles + shadowing recordings
   iPhone ──user's key, direct──▶ Qwen Realtime (WebRTC live voice class)
   iPhone ──user's key, direct──▶ OpenAI/LLM (text tutor, shadowing feedback)
```

### Key simplification

Single-user means keys are stored in the iOS Keychain and the phone connects to
remote APIs directly. The backend no longer proxies SDP or issues ephemeral
tokens. It does import/transcription only.

## Backend (thin)

**Sole responsibility:** YouTube URL → import/transcribe → packaged episode the
phone can pull.

### Copied & reused from the existing project (valuable, hard to rewrite)

- `pipeline.py` — yt-dlp download, caption scraping, ffmpeg splitting,
  transcription, batched translation (with recursive split on mismatch),
  chaptering. Reused nearly verbatim.
- `settings.py` — trimmed to only what import/transcription needs (OpenAI key,
  transcription/text models, base URL, data dir, database URL).
- `models.py` / `repositories.py` — keep only `Episode`, `ImportJob`,
  `ImportChunk`, `Chapter`, `Sentence`.

### Dropped (these responsibilities move to the iOS device)

- `Discussion` / `DiscussionTurn` (text tutor persistence)
- `ClassSession` / `ClassEvent` (voice classroom persistence)
- `ShadowingRecording` (recording storage)
- `realtime.py` (SDP proxy)
- `tutor.py` classroom/realtime/feedback methods and all class-session /
  webrtc / discussion / realtime endpoints

### Endpoints (trimmed set)

- `POST /api/episodes/import` — take YouTube URL, create episode + import job
- `GET /api/episodes/{id}/job` — poll import progress (stage, progress, status, error)
- `GET /api/episodes` / `GET /api/episodes/{id}` — list / detail
- `POST /api/jobs/{id}/retry` — retry a failed job
- **`GET /api/episodes/{id}/bundle`** (new, key) — return the packaged episode:
  metadata + all sentences (bilingual + timestamps) + chapters, so the phone
  pulls everything in one request
- **`GET /api/episodes/{id}/audio`** (new) — download the mp3 audio file to the phone

### Decisions

- **Audio format: mp3.** The existing pipeline already produces mp3; iOS
  `AVPlayer`/`AVAudioPlayer` plays mp3 natively. Backend produces mp3, phone
  downloads and plays it locally. No transcoding.
- **Keep the worker + job-polling model.** Transcribing an episode is slow
  (~10+ min), so async import with progress polling is a better experience and
  reuses the existing `claim_next_job` → `pipeline.run` loop.
- **Deployment:** runs on the user's Mac by default. A Dockerfile can be added
  later if remote hosting is wanted; not required for the core design.

## Guiding principle: replicate interaction logic, redesign visuals freely

The **visual/UI layer may be redesigned freely** to fit iOS conventions. But the
**interaction logic must faithfully replicate `nexa_insight`** — that
behavior was iterated on and optimized over many phases (see the original
project's `task_plan.md` / `progress.md`), and its subtle rules are deliberate,
not incidental. Do not "improve" or simplify interaction behavior on your own.

Interaction rules to preserve exactly (non-exhaustive):

- Voice-first cursor freeze: speaking freezes the cursor; only an explicit resume
  command releases playback. Speech, questions, empty activations, teacher-audio
  completion, seeks, and replay commands all leave the class paused at a visible
  frozen cursor.
- A verified learner voice command is the only path that can resume playback.
- "Continue / 继续 / 我们继续 / 回到播客 / let's continue" defaults to *resume
  playback* (tool call, empty spoken reply) — NOT "continue the discussion".
  "Explain that / 解释一下刚才那句 / 这句什么意思" is discussion (speak, no tool).
- A playback command never carries a spoken monologue (so the teacher's voice
  never plays over the resumed podcast).
- Single authoritative current-context window: exactly one fresh transcript
  window is attached; earlier positions are explicitly overridden.
- Position-moving tools refresh the model's context to the new spot.
- The captured study-room position is authoritative until the player reports
  ready; speech-start freezes that position before context refresh.
- Malformed/empty model responses degrade to a short clarification, never silence
  and never a crash.

When an interaction detail is ambiguous, mirror the existing `nexa_insight`
implementation (`useClassroomTeacher.ts`, `QwenClassroom.ts`, `classroom.ts`,
`classroomConfig.ts`, `domain.ts`) rather than inventing behavior.

## iOS app

### Stack

Swift + SwiftUI, `AVFoundation` (audio playback + recording), WebRTC
(GoogleWebRTC / webrtc-sdk Swift package) for the live class, SwiftData or
SQLite for local storage, Keychain for API keys.

### Local data model (mirrors the backend tables after download)

- `Episode` — id, title, channel, duration, thumbnail, local audio file path, import status
- `Chapter` — title, summary, start_ms, end_ms
- `Sentence` — position, start_ms, end_ms, speaker, source_text, chinese
- `ShadowingRecording` — sentence_id, local file path, is_best, feedback — **local only**
- `ClassSession` / `ClassEvent` — class record, transcripts, report — **local only**

### Screens (mapped from the existing web features)

Visuals may be redesigned for iOS; the interaction behavior of each screen must
follow the original (see the guiding principle above).

1. **Shelf / Home** — list of downloaded episodes + "Import new episode"
   (enter YouTube URL → connect backend → show progress → pull bundle + audio to local storage)
2. **Study (Classroom)** — audio player + bilingual subtitle follow/browse/tap-to-seek.
   This is the core of the existing `ClassroomView`.
3. **Shadowing** — pick a sentence → record → store locally → call LLM with the
   local key when feedback is requested
4. **Live Class** — WebRTC direct to Qwen; the `useClassroomTeacher` orchestration ported here
5. **Settings** — enter API keys (OpenAI, DashScope, etc.), stored in Keychain

### Important difference from the web version

Classroom context (`classroom_context`, `sentence_window`) was computed by the
backend `repositories.py`. With episodes now fully local, this logic —
"slice the sentence window near the current position + current chapter +
episode map" — is **ported into Swift and runs on-device.** The algorithm is
straightforward (slice the sentence array by `position_ms`); the existing
algorithm is carried over directly.

## Voice classroom port (the hardest part)

Port the orchestration in `useClassroomTeacher.ts` + `QwenClassroom.ts` to
Swift. Invariants preserved:

- **Omni-direct single-model path.** Qwen Omni alone hears the learner's voice,
  reasons, replies by voice, and calls playback tools. The qwen-max HTTP
  "teacher brain" is a legacy path (`OMNI_DIRECT = true` in the live web app) and
  is **not ported.**
- **WebRTC direct to Qwen.** `RTCPeerConnection` uses the local DashScope key to
  do SDP negotiation directly with the Qwen `webrtc/realtime` endpoint — **not
  through the backend.** This is the key win of this architecture.
- **Voice-first cursor freeze invariant.** When the learner starts speaking
  (`speech_started`), freeze the playback cursor, pause, and refresh the context
  window to the current position. Only an explicit resume command releases
  playback. The `classroomReducer` state machine is carried over.
- **Playback tool execution.** The model returns `resume/pause/previous/next/
  seek_to_timestamp` etc. as function calls; Swift drives `AVPlayer` directly,
  then returns the tool result.
- **Context refresh.** The "single authoritative current context" strategy
  (`composeInstructions` + injecting a conversation item) is carried over; only
  the data source changes from a backend API to a local sentence slice.
- **Dual-track recording.** Both learner and teacher audio tracks are recorded
  and stored locally (previously uploaded to the backend, now stored on-device).

## Error handling & security

- **API keys** live in the iOS Keychain — never hardcoded, never in git. Entered
  on the Settings screen.
- **Import failure:** job polling reaching `failed` shows the error + a retry
  button (reuses the backend retry endpoint).
- **Network:** import needs the backend; class/text-tutor need remote AI. Both
  handle offline with clear messaging. Keys on-device is an accepted trade-off
  for single-user personal use; documented explicitly.
- **Class degradation:** a malformed tool call or empty reply from the model
  must not crash — degrade to a short clarifying question (existing fallback
  behavior carried over).

## Testing & verification

- **Backend:** keep and trim the existing pytest suite (import pipeline,
  episode/job/bundle endpoints).
- **iOS:** XCTest over pure logic — context-window slicing, `classroomReducer`
  state machine, playback target-position computation, direct-command matching.
  These are ported from the existing TS tests (`classroom.test.ts`, etc.).
- WebRTC / audio needing a real device is validated manually.

## Out of scope (this iteration)

- The legacy qwen-max HTTP teacher-brain path (not ported).
- A configurable second realtime voice provider (the original project's pending
  Phase 8).
- Offline import/transcription on-device (import always uses the backend).
