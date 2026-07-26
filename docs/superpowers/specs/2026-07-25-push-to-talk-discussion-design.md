# Push-to-Talk Discussion — Design

Date: 2026-07-25
Status: proposed

## Problem

The discussion UI currently exposes one action — "join" — which starts a
persistent VAD-based live session where the model listens continuously and
interrupts whenever the learner speaks. That is the right model for an
extended back-and-forth, but it is heavy for the common case: the learner
wants to ask one quick question about what they just heard, get an answer,
and keep listening.

We want two distinct actions on one control, using gestures the user already
knows (WeChat / iMessage hold-to-talk + slide-to-lock):

- **Hold to talk**: press and hold the button, speak, release. Release ends
  the turn and requests one answer. Lightweight, no mode to enter or exit.
- **Slide up to lock**: while holding, slide up to enter the persistent live
  session — the current behaviour (continuous VAD, speak any time, voice can
  control playback such as "skip ahead thirty minutes"). Tap the icon (or an
  explicit end control) to leave.

## Constraints carried from prior decisions

- **Voice-first, restrained visuals.** The transcript is the subject; the
  discussion surface is a floating element, not a chat panel. No text-entry
  field.
- **Position-independent surface.** Voice can move playback at any time, so
  the discussion has no fixed screen anchor. Content shown is transient and
  about "now", never pinned to a specific transcript row. (This is why the
  self-shrinking/expanding dock survives and row-anchored designs do not.)
- **Playback control is voice-only.** The dock carries no scrub/skip
  controls; seeking happens through the model's playback tools.
- **PTT is NOT in the reference (english_learning).** The reference is
  pure continuous VAD. PTT is a new capability built on the ported
  architecture; "match the reference" does not apply to the PTT path.

## Key insight: the reducer does not change

`classroomReducer` already models "learner speaks → teacher answers":

- `.speechStarted(atMs:)` → `userSpeaking` (freezes playback at that ms)
- `.discussionStarted` → `discussing`
- `.teacherStarted` / `.teacherFinished` → `teacherSpeaking` → `discussionPaused`
- `.resumed` → `resuming` → (on next connected/podcast) `podcastPlaying`

Today these events originate from the model's VAD. PTT drives the SAME events
from the finger instead:

- **Press** → controller freezes and emits `.speechStarted(cursor)`.
- **Release** → controller commits the mic buffer and emits
  `.discussionStarted`, then requests one response.

So the 70-test reducer is untouched. What changes is the transport (how turns
are detected) and the controller entry points that drive it.

## Resolved design questions

1. **First-connect latency.** Lazy connect with a "hold-ring" fill. The first
   hold opens the WebRTC session; a ring fills around the button to cover the
   few seconds of SDP/ICE/data-channel setup, completing with a haptic that
   means "you can speak now." The session stays open afterwards, so subsequent
   holds are instant. Idle 60s with no interaction closes it.
2. **After release.** Text first, audio second. The dock renders the AI's
   transcribed answer immediately (works in the simulator, unit-testable).
   Wiring `remoteAudioTrack` to actual playback is the next step and needs a
   device to verify; it is out of scope for the first PTT commit.
3. **Leaving locked (live) mode.** Tap the icon to exit. PTT turns end
   naturally on release, so only the locked mode needs an explicit exit.

## Transport changes

`ClassroomTransport` currently assumes continuous VAD with
`create_response: true`. PTT needs manual turn boundaries.

Add to the protocol:

- `func setTurnMode(_ mode: TurnMode)` where `TurnMode` is `.pushToTalk`
  (semantic_vad off or `create_response:false`, no auto-response) or
  `.continuous` (current config).
- `func beginListening()` — enable the local mic audio track
  (`RTCAudioTrack.isEnabled = true`); in PTT mode also clear any stale input
  buffer.
- `func endTurnAndRespond()` — in PTT mode: `input_audio_buffer.commit` then
  `response.create`; disable the mic track.

Session config by mode:

| mode         | turn_detection                                   | mic between turns |
|--------------|--------------------------------------------------|-------------------|
| pushToTalk   | semantic_vad with `create_response: false`       | disabled          |
| continuous   | semantic_vad `create_response: true` (unchanged) | enabled           |

Switching happens via `session.update` at the moment of slide-to-lock.

The stub transport gets no-op implementations of the new methods so the app
still builds without WebRTC.

## Controller entry points

`ClassroomController` gains two methods that the view calls:

- `func beginUserTurn()` → `transport.beginListening()`, `freeze(cursor(),
  .speechStarted)`, `onContextRefresh(frozen)`. (Reuses existing freeze +
  refresh; same as today's VAD `.speechStarted` handling.)
- `func endUserTurn()` → `transport.endTurnAndRespond()`, emit
  `.discussionStarted`.

`LiveClassSession` starts the session in `.pushToTalk` mode. Slide-to-lock
calls a `switchToContinuous()` that flips the transport mode and lets the
existing VAD flow take over.

## Gesture + view

One control, replacing `FloatingDiscussionButton`'s plain tap:

- **Tap** (no hold): show a brief hint "按住说话 / Hold to talk". No connect.
- **Long-press begin**: if not connected, start connect and run the hold-ring
  fill; once ready (or immediately if warm), haptic + `beginUserTurn()`. The
  button grows; the waveform icon animates as the live indicator.
- **Drag up past a threshold while holding**: commit to locked mode. On the
  next release, do NOT end the turn — instead `switchToContinuous()` and keep
  the session open. Show a "connected" affordance.
- **Release without locking**: `endUserTurn()`. Button falls back; the dock
  expands to show the answer; after idle it shrinks to the icon.

The expand/collapse is the same self-shrinking dock already designed: event
-driven growth (holding = listening, answer arriving = expanded), automatic
shrink to the pulsing icon when idle. Position-independent, so voice-driven
seeks never fight it.

Locked-mode exit: tap the icon → `session.end()`.

## What is explicitly deferred

- Remote audio playback (`remoteAudioTrack` → `AVAudioEngine`/player). Next
  commit; needs device verification.
- Idle-auto-shrink tuning (the 4s/60s numbers are starting points).
- Force-collapse gesture (swipe the dock down without disconnecting).

## Verification plan

- Unit-test the controller's `beginUserTurn`/`endUserTurn` against a fake
  transport: press freezes + refreshes context + enables mic; release commits
  + requests response + emits discussionStarted.
- Unit-test transport mode config selection (which `turn_detection` /
  `create_response` per mode) at the pure-logic level where possible.
- Build the app target (real WebRTC branch) and drive the gesture states in
  the simulator with seeded data; verify the hold-ring, expand/collapse, and
  the text answer path. Live audio round-trip stays unverified until a device
  session is possible.
