from __future__ import annotations

import json
import re
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Protocol
from urllib.parse import parse_qs, urlparse

from openai import OpenAI

from .repositories import Repository, has_slot
from .settings import Settings


@dataclass
class MediaMetadata:
    youtube_id: str
    title: str
    channel: str
    duration_ms: int
    thumbnail_url: str | None
    stream_url: str | None = None
    stream_url_expires_at: datetime | None = None


@dataclass
class TranscriptSegment:
    start_ms: int
    end_ms: int
    speaker: str | None
    text: str


# Chinese prose, or nothing. Used by BOTH the adapter (register notes) and the pipeline (这集里),
# so it lives at module level: an earlier version was a classmethod on ImportPipeline that
# OpenAIAdapter called through `self`, which would have raised on the first real enrichment.
_HAN = re.compile(r"[\u4e00-\u9fff]")


def chinese_prose(value: object) -> str | None:
    """The value if it reads as Chinese prose, else None.

    Fields asked for in Chinese come back in English often enough to matter: one run produced
    196 of 196 cards whose 这集里 was raw transcript, and another put an English register note
    in 常见用法. The card renders whatever is there, so a wrong-language value is worse than an
    empty one — it occupies the section that was meant to explain something.

    A Chinese gloss quoting English terms still passes; a mostly-English sentence does not.
    """
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    return text if len(_HAN.findall(text)) >= max(2, len(text) // 10) else None


class MediaAdapter(Protocol):
    def metadata(self, url: str) -> MediaMetadata: ...
    def stream(self, url: str) -> tuple[str | None, datetime | None]: ...
    def captions(self, url: str, destination: Path) -> tuple[list[TranscriptSegment], list[TranscriptSegment] | None]: ...
    def download_audio(self, url: str, destination: Path) -> Path: ...
    def is_constant_bitrate(self, audio: Path) -> bool: ...
    def split_audio(self, audio: Path, output_dir: Path) -> list[Path]: ...


class AIAdapter(Protocol):
    def transcribe(self, path: Path, offset_ms: int) -> list[TranscriptSegment]: ...
    def translate(self, texts: list[str]) -> list[str]: ...
    def chapters(self, sentences: list[TranscriptSegment]) -> list[dict]: ...
    def classify_material(self, sentences: list[TranscriptSegment]) -> str: ...
    def hidden_traps(self, sentences: list[TranscriptSegment]) -> list[dict]: ...
    def teaching_traps(self, sentences: list[TranscriptSegment]) -> list[dict]: ...
    def is_compositional(self, text: str, meaning: str) -> bool: ...
    def garbled(self, texts: list[str]) -> set[str]: ...
    def generic_usage(self, texts: list[str]) -> dict[str, str]: ...
    def insight_chunk(self, lines: list[dict]) -> dict: ...
    def insight_synthesis(self, claims: list[dict], facts: list[dict]) -> dict: ...


class YtDlpMediaAdapter:
    YTDLP_TIMEOUT_SECONDS = 90
    YTDLP_DOWNLOAD_TIMEOUT_SECONDS = 900
    EXTRA_BIN_DIRS = ("/opt/homebrew/bin", "/usr/local/bin")

    def __init__(self):
        self.yt_dlp = self._resolve_binary("yt-dlp")
        self.ffmpeg = self._resolve_binary("ffmpeg")
        self.ffprobe = self._resolve_binary("ffprobe")
        self.js_runtime = self._resolve_optional_binary("deno") or self._resolve_optional_binary("node")

    @classmethod
    def _resolve_binary(cls, name: str) -> str:
        path = shutil.which(name)
        if path:
            return path
        for directory in cls.EXTRA_BIN_DIRS:
            candidate = Path(directory) / name
            if candidate.exists():
                return str(candidate)
        raise RuntimeError(f"{name} is not installed or is not on the backend PATH")

    @classmethod
    def _resolve_optional_binary(cls, name: str) -> str | None:
        try:
            return cls._resolve_binary(name)
        except RuntimeError:
            return None

    def _yt_dlp_command(self, *args: str, include_ffmpeg: bool = False) -> list[str]:
        command = [self.yt_dlp, *args]
        if include_ffmpeg:
            command.extend(["--ffmpeg-location", str(Path(self.ffmpeg).parent)])
        if self.js_runtime:
            command.extend(["--js-runtimes", f"{Path(self.js_runtime).stem}:{self.js_runtime}"])
        return command

    def _run(self, command: list[str], *, timeout: int | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
        try:
            return subprocess.run(
                command,
                check=check,
                capture_output=True,
                text=True,
                timeout=timeout or YtDlpMediaAdapter.YTDLP_TIMEOUT_SECONDS,
            )
        except FileNotFoundError as exc:
            raise RuntimeError(f"{command[0]} is not installed or is not on the backend PATH") from exc
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError("Timed out while contacting YouTube. Check the backend server's network or proxy.") from exc
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or exc.stdout or "").strip()
            if hint := self._known_failure(detail):
                raise RuntimeError(hint) from exc
            if detail:
                raise RuntimeError(f"yt-dlp failed: {detail[-1000:]}") from exc
            raise RuntimeError("yt-dlp failed while reading this YouTube URL") from exc

    @staticmethod
    def _known_failure(detail: str) -> str | None:
        """A sentence that says what to DO, for failures whose raw text does not.

        `HTTP Error 403: Forbidden` reached the learner verbatim and reads like the video is
        private or the network is blocked. It is neither: YouTube periodically changes how the
        media URL is signed, and a yt-dlp older than that change computes a signature the CDN
        rejects. Seen with 2026.07.04 against a public video whose formats listed fine —
        metadata worked, only the download 403'd, which is the fingerprint.
        """
        lowered = detail.lower()
        if "403" in lowered and "forbidden" in lowered:
            return ("YouTube refused the download (HTTP 403). This usually means yt-dlp is out "
                    "of date — YouTube changed how media URLs are signed. Update it "
                    "(`brew upgrade yt-dlp`) and retry.")
        if "sign in to confirm" in lowered or "not a bot" in lowered:
            return ("YouTube asked this server to prove it is not a bot. Retry later, or give "
                    "yt-dlp cookies from a signed-in browser session.")
        if "video unavailable" in lowered or "private video" in lowered:
            return "This video is private or unavailable, so there is nothing to import."
        return None

    def metadata(self, url: str) -> MediaMetadata:
        result = self._run(self._yt_dlp_command("--dump-single-json", "--skip-download", url))
        data = json.loads(result.stdout)
        stream_url, expires_at = self._best_stream(data)
        return MediaMetadata(data["id"], data.get("title", "Untitled"), data.get("channel", "Unknown"), int(data.get("duration", 0) * 1000), data.get("thumbnail"), stream_url, expires_at)

    def stream(self, url: str) -> tuple[str | None, datetime | None]:
        result = self._run(self._yt_dlp_command("--dump-single-json", "--skip-download", url))
        return self._best_stream(json.loads(result.stdout))

    @staticmethod
    def _best_stream(data: dict) -> tuple[str | None, datetime | None]:
        formats = data.get("formats") or []
        candidates = [
            item for item in formats
            if item.get("url")
            and item.get("vcodec") not in {None, "none"}
            and item.get("acodec") not in {None, "none"}
            and (item.get("protocol") in {"https", "m3u8_native", "m3u8"} or str(item.get("url", "")).startswith("https://"))
        ]
        progressive = [item for item in candidates if item.get("ext") == "mp4" and item.get("protocol") == "https"]
        hls = [item for item in candidates if str(item.get("protocol", "")).startswith("m3u8")]
        ordered = progressive or hls or candidates
        if not ordered:
            return None, None
        best = max(ordered, key=lambda item: (int(item.get("height") or 0), int(item.get("tbr") or 0)))
        stream_url = best["url"]
        return stream_url, YtDlpMediaAdapter._expires_at(stream_url)

    @staticmethod
    def _expires_at(stream_url: str) -> datetime | None:
        value = parse_qs(urlparse(stream_url).query).get("expire", [None])[0]
        if not value:
            return None
        try:
            return datetime.fromtimestamp(int(value), tz=timezone.utc)
        except ValueError:
            return None

    def download_audio(self, url: str, destination: Path) -> Path:
        destination.parent.mkdir(parents=True, exist_ok=True)
        template = str(destination.with_suffix(".%(ext)s"))
        self._run(
            self._yt_dlp_command("-x", "--audio-format", "mp3", "-o", template, url, include_ffmpeg=True),
            timeout=self.YTDLP_DOWNLOAD_TIMEOUT_SECONDS,
        )
        generated = destination.with_suffix(".mp3")
        # Re-encode to CONSTANT bitrate. yt-dlp yields a VBR MP3, and iOS AVPlayer
        # estimates the current time from byte-offset ÷ average bitrate — which
        # drifts mid-file on VBR (observed ~23s off near the end), desyncing audio
        # from subtitles. CBR makes byte↔time linear so the clock stays accurate.
        cbr = generated.with_name("source_cbr.mp3")
        subprocess.run(
            [self.ffmpeg, "-y", "-i", str(generated), "-c:a", "libmp3lame",
             "-b:a", "128k", "-vn", str(cbr)],
            check=True, capture_output=True,
        )
        cbr.replace(destination)
        if generated != destination:
            generated.unlink(missing_ok=True)
        return destination

    def is_constant_bitrate(self, audio: Path) -> bool:
        """Whether an existing file is already the CBR the player needs.

        Measured by packet-size variety, NOT by the declared bitrate or the
        presence of a Xing header — neither distinguishes CBR from VBR. A real
        CBR file yields 1-2 distinct packet sizes; the VBR file that caused the
        desync had 15.

        Returns False when ffprobe cannot read the file, so an unreadable file is
        re-downloaded rather than trusted.
        """
        try:
            result = subprocess.run(
                [self.ffprobe, "-v", "error", "-select_streams", "a:0",
                 "-show_entries", "packet=size", "-of", "csv=p=0", str(audio)],
                check=True, capture_output=True, text=True,
            )
        except (subprocess.CalledProcessError, FileNotFoundError):
            return False
        sizes = {line for line in result.stdout.split() if line}
        # An empty read means ffprobe found no audio packets at all.
        return 0 < len(sizes) <= 2

    def captions(self, url: str, destination: Path) -> tuple[list[TranscriptSegment], list[TranscriptSegment] | None]:
        # Only the source-language track is fetched now. The zh-Hans auto-caption
        # track is no longer used — Chinese comes from per-sentence AI translation
        # (see Pipeline._translate), which stays 1:1 aligned with the source. The
        # second tuple element is kept as None for the (source, chinese) contract.
        destination.mkdir(parents=True, exist_ok=True)
        template = str(destination / "captions.%(ext)s")
        command = self._yt_dlp_command(
            "--skip-download", "--write-subs", "--write-auto-subs",
            "--sub-langs", "en-orig,en", "--sub-format", "json3",
            "-o", template, url,
        )
        try:
            subprocess.run(command, check=False, capture_output=True, text=True, timeout=self.YTDLP_TIMEOUT_SECONDS)
        except FileNotFoundError as exc:
            raise RuntimeError("yt-dlp is not installed or is not on the backend PATH") from exc
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError("Timed out while fetching YouTube captions. Check the backend server's network or proxy.") from exc
        source_caption_path = next(iter(destination.glob("captions.en-orig.json3")), None) or next(iter(destination.glob("captions.en.json3")), None)
        source_text = self._parse_json3(source_caption_path) if source_caption_path else []
        return source_text, None

    @staticmethod
    def _parse_json3(path: Path) -> list[TranscriptSegment]:
        events = json.loads(path.read_text()).get("events", [])
        segments: list[TranscriptSegment] = []
        buffer = ""
        start_ms: int | None = None
        end_ms = 0
        for event in events:
            text = "".join(part.get("utf8", "") for part in event.get("segs", [])).strip()
            if not text or text == "[Music]":
                continue
            event_start = int(event.get("tStartMs", 0))
            if start_ms is None:
                start_ms = event_start
            end_ms = event_start + int(event.get("dDurationMs", 0))
            buffer = f"{buffer} {text}".strip()
            if text.rstrip().endswith((".", "?", "!")) or end_ms - start_ms >= 12_000:
                segments.append(TranscriptSegment(start_ms, end_ms, None, buffer))
                buffer, start_ms = "", None
        if buffer and start_ms is not None:
            segments.append(TranscriptSegment(start_ms, end_ms, None, buffer))
        return segments

    def split_audio(self, audio: Path, output_dir: Path) -> list[Path]:
        output_dir.mkdir(parents=True, exist_ok=True)
        subprocess.run([self.ffmpeg, "-y", "-i", str(audio), "-f", "segment", "-segment_time", "900", "-c", "copy", str(output_dir / "%03d.mp3")], check=True, capture_output=True)
        return sorted(output_dir.glob("*.mp3"))


class OpenAIAdapter:
    def __init__(self, settings: Settings):
        self.client = OpenAI(api_key=settings.openai_api_key, base_url=settings.openai_base_url)
        self.transcription_model = settings.transcription_model
        self.text_model = settings.text_model

    def transcribe(self, path: Path, offset_ms: int) -> list[TranscriptSegment]:
        with path.open("rb") as audio:
            result = self.client.audio.transcriptions.create(model=self.transcription_model, file=audio, response_format="verbose_json", timestamp_granularities=["segment"])
        return [TranscriptSegment(offset_ms + int(s.start * 1000), offset_ms + int(s.end * 1000), None, s.text.strip()) for s in result.segments]

    def _json(self, instruction: str, payload: object) -> object:
        response = self.client.chat.completions.create(
            model=self.text_model,
            messages=[
                {"role": "system", "content": instruction},
                {"role": "user", "content": json.dumps(payload, ensure_ascii=False)},
            ],
        )
        content = response.choices[0].message.content or ""
        return json.loads(self._json_text(content))

    @staticmethod
    def _json_text(content: str) -> str:
        text = content.strip()
        fenced = re.search(r"```(?:json)?\s*(.*?)\s*```", text, flags=re.DOTALL)
        if fenced:
            return fenced.group(1).strip()
        start = min((i for i in (text.find("{"), text.find("[")) if i != -1), default=-1)
        if start > 0:
            text = text[start:]
        return text

    def translate(self, texts: list[str]) -> list[str]:
        translated: list[str] = []
        for start in range(0, len(texts), 40):
            batch = texts[start:start + 40]
            result = self._json("Translate each source-language item into natural Simplified Chinese. Return JSON with key items containing a string array in the same order.", {"items": batch})
            translated.extend(result["items"])
        return translated

    def chapters(self, sentences: list[TranscriptSegment]) -> list[dict]:
        payload = [asdict(item) for item in sentences]
        result = self._json("Group this podcast transcript into coherent chapters. Return JSON with key chapters containing an array. Each chapter must have title, summary, start_ms and end_ms. Cover the full timeline without gaps.", {"sentences": payload})
        return list(result["chapters"])

    CLASSIFY_MATERIAL = (
        'Classify this transcript excerpt as exactly one of: "native" (made for '
        'native speakers — news, interviews, technical talk, where English is the '
        'medium and not the subject) or "teaching" (made to teach English — hosts '
        'explain vocabulary, slow down, define phrases, address learners directly). '
        'Return JSON: {"material": "native" or "teaching"}.'
    )

    # Two goals, so two prompts. The shipped single prompt asked for "useful words,
    # phrasal verbs, collocations..." and got greetings ("welcome back", "thanks so
    # much") and literal domain nouns ("training data center") on every source,
    # including a Patrick Collison interview. What was missing was any statement of
    # what makes an item worth studying — and any instruction to refuse.
    # For native speech the goal is UNDERSTANDING, and two kinds were too few for it: 720
    # sentences of an AI podcast produced 2 cards. Both additions are things that stop a
    # learner mid-listen, which is the only test that matters here:
    #
    # "coined" — a metaphor or label the speaker invented for this discussion ("nealism", a
    # "buttered slippery slide"). No dictionary has it and the audio never explains it. It was
    # tempting to filter these out as unportable — you will never meet them again — but that is
    # a PRODUCTION argument, and production is the teaching path's concern. Here, not knowing
    # one means not following the sentence.
    #
    # "unsayable" — established vocabulary they follow but could never produce ("hoover up",
    # "codified"). Passive, not active.
    #
    # NO EXAMPLE EXPRESSIONS BELOW, deliberately. An earlier draft named "blindsided",
    # "clunky" and "job displacement"; a batch containing none of the three returned all
    # three. The same failure as the pattern prompt — a named example comes back as a finding —
    # so the kinds are described by shape only, and `_is_grounded` enforces it in code because
    # the instruction alone did not.
    HIDDEN_TRAPS = (
        "You are scanning a native-speed transcript for a Chinese-speaking learner. The goal is "
        "UNDERSTANDING: find every place they would stall, misread, or follow without being "
        "able to use it themselves. Four kinds:\n"
        '- "shifted": the everyday sense of the words is easy AND WRONG in this context. Every '
        "word known, the sentence parses, the reading wrong.\n"
        '- "set_phrase": every word is familiar but the combination means something the words '
        "do not. The learner reads straight past it, confident and wrong.\n"
        '- "coined": a metaphor, label or term this speaker INVENTED for this discussion. No '
        "dictionary has it and the audio never explains it, so it stops the learner cold. "
        "Include it even though they will never meet it again — understanding THIS episode is "
        "the goal.\n"
        '- "unsayable": established vocabulary they would follow here but could never produce '
        "themselves. Passive, not active.\n"
        "EVERY item must be lifted from the lines given to you. Do not report an expression "
        "that is not present in this passage, however typical of the topic it seems.\n"
        "Skip discourse filler, grammar, and anything that looks like a TRANSCRIPTION ERROR "
        "rather than English: a garbled word teaches nothing.\n"
        "For each item return:\n"
        "  text — exactly as it appears\n"
        "  kind\n"
        "  chinese — what it MEANS, IN CHINESE, stated so it still holds outside this episode. "
        "It must contain NO reference to this conversation: no 此处, no 说话人, no 本集, no "
        "speaker, and no names from this discussion. Write the definition you would put in a "
        "dictionary. Everything about how THIS speaker used it goes in context_meaning instead — "
        'a card that defines "regulatory capture" as what one company is accused of teaches the '
        "accusation instead of the word.\n"
        "  context_meaning — IN CHINESE, what the speaker means by it HERE, and only when that "
        "differs from the general meaning. This is where their argument belongs; for a coined "
        "term it may be the whole meaning. Omit it when the two are the same. This field must "
        "be Chinese prose, NOT a quotation from the transcript.\n"
        "  example — the ONE sentence containing the expression, verbatim\n"
        "  example_chinese — that sentence in Chinese\n"
        "  sentence_position\n"
        'No quota. Return JSON with key "expressions".'
    )

    # Teaching material needs a different question asked of it.
    #
    # HIDDEN_TRAPS asks "would the learner misread this HERE", which finds nothing in a
    # transcript whose speaker explains as they go — the explanation is right there, so the
    # answer is always no. Measured: 0 items across a hotel-vocabulary vlog that plainly
    # contains "card on file", "put money down" and "go through with".
    #
    # So this asks the portable question instead: take the explanation away, meet it cold
    # months later, would it still stop them? The lesson is over in a minute; the phrase is
    # what carries.
    # The goal for a lesson is SPEAKING, so it asks for three kinds, not two. Vocabulary
    # alone leaves the learner able to recognise "late checkout" and still unable to ask for
    # one — the sentence they need is the frame around it.
    TEACHING_TRAPS = (
        "This transcript TEACHES English: the speaker explains things as they go, so asking "
        "whether the learner would misread it HERE finds nothing. Ask instead: take the "
        "explanation away, meet it cold months later — could they SAY this themselves?\n"
        "The goal is speaking, not recognition. Return three kinds:\n"
        '- "pattern": a sentence frame SOMEONE IN THIS TRANSCRIPT ACTUALLY SAID, with the '
        "variable part replaced by ___. Take their words and blank out only the part that "
        "changes between uses. This is the most valuable kind: knowing the word \"checkout\" "
        "does not let them ASK for a late one.\n"
        "  A pattern must be traceable to a line here. Do NOT write the frame you would teach "
        "for this topic — if the words are not in the transcript, leave it out. Give the frame, "
        "not the whole line of dialogue.\n"
        '- "set_phrase": familiar words whose combination means something the parts do not, or '
        "a fixed collocation a learner would word differently themselves.\n"
        '- "shifted": a word used in a sense other than its everyday one.\n'
        "Skip anything that looks like a TRANSCRIPTION ERROR rather than English.\n"
        "For each: text (the expression, or the frame with ___ for a pattern), kind, chinese "
        "(what it MEANS, in Chinese, stated so it holds outside this lesson), context_meaning "
        "(in Chinese, what it means HERE, and ONLY when that differs from the general meaning — "
        "for a pattern, what goes in the slot; omit when the two are the same), example (the ONE "
        "sentence containing it, verbatim), example_chinese, sentence_position.\n"
        'No quota. Return JSON with key "expressions".'
    )

    # Each word's ordinary sense, ALONE, with no phrase to belong to.
    #
    # This is the pair that makes the filter work, and it is deliberately not a judgement.
    # Asked to rate its own candidates, the model kept 9 of 10 — including "tip" and
    # "deposit" — and wrote justifications that just restated the word. Asked for a verdict
    # field it set "same": false on everything, including "stay together". A model given a
    # verdict to reach reaches it. Translation has nothing to pad and nothing to rationalise.
    WORD_GLOSSES = (
        "Translate each English word into Chinese IN ISOLATION — its most ordinary everyday "
        "sense, ignoring any phrase it might belong to. Return JSON with key \"glosses\", a "
        'list of {"word", "chinese"}.'
    )

    # Could the learner SAY it, not could they understand it.
    #
    # Comprehension was the wrong axis. Asked whether the parts lead to the meaning, this
    # dropped "king-size bed", "room key" and "complimentary breakfast" — all correct, and
    # all useless as a conclusion, because understanding is not the gap. Reading "luggage
    # cart" is effortless; producing it is not, and the learner says "luggage trolley".
    #
    # So the question is reversed: from the Chinese, in this situation, what English would
    # they actually reach for? Keep the expression when their own wording would not be it.
    LEARNER_ATTEMPTS = (
        "A Chinese learner wants to say the following in English, in the situation given. "
        "Write the 3 most likely things they would ACTUALLY produce — their own wording, not "
        "the idiomatic native phrase. They translate from Chinese and reach for words they "
        'already know.\nReturn JSON {"attempts": [str, str, str]}.'
    )

    NATIVE_WOULD_SAY = (
        "Would a native speaker use any of these learner attempts where the target expression "
        "belongs? Judge the WORDING, not grammar slips.\n"
        "would_produce=true only if an attempt uses essentially the same words as the target. "
        'A near-miss with a different noun or particle is false — "luggage trolley" is not '
        '"luggage cart", "room card" is not "room key", "delay check out" is not "late '
        'checkout".\nReturn JSON {"would_produce": bool}.'
    )

    def teaching_traps(self, sentences: list[TranscriptSegment]) -> list[dict]:
        payload = [{"position": i, "text": s.text} for i, s in enumerate(sentences)]
        return self._expression_list(self._json(self.TEACHING_TRAPS, {"sentences": payload}))

    GARBLED = (
        "Each item below was pulled from an automatic transcript. Say which ones are not real "
        'English — a mis-transcribed name or word, where the speaker said something else '
        '("onrem" for "on-prem", "Palanteer" for "Palantir").\n'
        "Real English includes rare words, jargon, and terms a speaker coined deliberately.\n"
        'Return JSON {"garbled": [the items that are mis-transcriptions]}.'
    )

    # One chunk of a native episode, read for what was ARGUED rather than what was said.
    #
    # Per-chunk rather than whole-transcript because the whole thing fits a single call (~26,500
    # tokens for a 102-minute episode) and would be flattened by it: the middle of a long text is
    # where detail goes missing. Each chunk is small enough to be read closely.
    INSIGHT_CHUNK = (
        "This is part of a podcast transcript. Report, IN CHINESE, what is ARGUED here — not a "
        "summary of what was said.\n"
        'Return JSON {"claims": [...], "facts": [...]}.\n'
        "Each claim: {\n"
        '  "claim": the position someone takes, in Chinese, one sentence;\n'
        '  "evidence": in Chinese, what they offer in support — and if they offer nothing, say '
        "so plainly. A claim with no stated grounds is worth knowing about AS one with no "
        "grounds;\n"
        '  "dispute": in Chinese, who disagrees and on what, or null if nobody does. This is a '
        "CONVERSATION: flattening several people into one agreeing voice is the most common way "
        "a summary misleads;\n"
        '  "at_ms": the millisecond offset of the line where the claim is made.\n'
        "}\n"
        "Each fact: {\n"
        '  "fact": in Chinese, a figure or concrete claim about the world;\n'
        '  "sourced": true only if a source, study or method is actually named in the audio. A '
        "number said off the cuff is not sourced, and marking it so would let the learner quote "
        "it as established;\n"
        '  "at_ms": millisecond offset.\n'
        "}\n"
        "Report only what is here. If this stretch is filler, advertising or small talk, return "
        "empty lists — padding it out costs the reader their time."
    )

    # The whole episode's shape, from the per-chunk findings.
    INSIGHT_SYNTHESIS = (
        "These are claims and facts extracted from one podcast, in order. Produce the page a "
        "listener reads INSTEAD of the hour, IN CHINESE.\n"
        'Return JSON {"thesis", "claims", "facts", "takeaways", "anchors"}.\n'
        '  "thesis": one sentence, under 40 characters, naming what this episode is actually '
        "about. Not a topic label — what is at stake in it.\n"
        '  "claims": the 3-5 that matter, each {"claim", "evidence", "dispute", "at_ms"}. Merge '
        "duplicates from different chunks, keep the earliest at_ms. Drop the rest: a page with "
        "everything on it is the transcript again.\n"
        '  "facts": 5-8, each {"fact", "sourced", "at_ms"}. Prefer figures the reader might '
        "repeat later.\n"
        '  "takeaways": at most 3, each one sentence. These must be INFERENCES — what follows '
        "from the episode that it does not itself say. Restating a claim in different words is "
        "not a takeaway; return an empty list rather than padding, because a reader who finds "
        "restatement here stops trusting the section.\n"
        '  "anchors": 2-4, each {"at_ms", "why"}: the moments worth hearing in the speakers\' own '
        "voices, for someone who has just read this in five minutes.\n"
        "Everything in Chinese except proper nouns. The whole page must be readable in 5-10 "
        "minutes — roughly 1500-2500 Chinese characters. Longer is not more useful; it is the "
        "problem this page exists to solve."
    )

    # Words a model writes when it means "nothing here". Stored verbatim they read as content.
    PLACEHOLDERS = frozenset({"null", "none", "nil", "n/a", "na", "-", "无", "暂无", "不适用"})

    GENERIC_USAGE = (
        "For each English expression below, say how it is used OUTSIDE any single conversation "
        "— what a Chinese learner needs in order to use it somewhere else.\n"
        "Give three things:\n"
        '  "usage": IN CHINESE, one short sentence on where it belongs — register, formality, '
        "what subjects it turns up in. Chinese, not English: the learner reads this to "
        "understand, and English here makes them decode the explanation as well as the "
        "expression.\n"
        '  "example": ONE natural ENGLISH sentence using the expression, on a subject unrelated '
        "to AI, podcasts or technology. This is what the learner will actually say, so it must "
        "be English they could reuse — a Chinese description of a situation teaches recognition "
        "and leaves them unable to produce anything. Keep the expression itself intact and "
        "unchanged.\n"
        '  "example_chinese": that English sentence translated into Chinese.\n'
        'Return "usage": null ONLY when the expression exists nowhere outside this one '
        "conversation — a metaphor this speaker invented on the spot, a label built for this "
        "argument alone. That bar is high and most expressions do not meet it.\n"
        "In particular, an expression made of ordinary words DOES have general usage even when "
        "the pairing feels new: rage baiting, golden vote, glitzy marketing, pearl-clutching and "
        "robo-taxi are all things people say elsewhere, and a learner can reuse every one of "
        "them. Answer for these.\n"
        "The point of null is to avoid teaching a usage that does not exist. It is not a way to "
        "skip an expression you are unsure about — an omission and a genuine coinage look "
        "identical to the learner, so guessing null costs them a section they needed.\n"
        'Return JSON {"items": [{"text", "usage", "example"}]}.'
    )

    def insight_chunk(self, lines: list[dict]) -> dict:
        """Claims and facts argued in one stretch of transcript."""
        try:
            result = self._json(self.INSIGHT_CHUNK, {"lines": lines})
        except Exception:
            return {"claims": [], "facts": []}
        if not isinstance(result, dict):
            return {"claims": [], "facts": []}
        return {
            "claims": [c for c in (result.get("claims") or []) if isinstance(c, dict)],
            "facts": [f for f in (result.get("facts") or []) if isinstance(f, dict)],
        }

    def insight_synthesis(self, claims: list[dict], facts: list[dict]) -> dict:
        """The page itself, from every chunk's findings."""
        try:
            result = self._json(self.INSIGHT_SYNTHESIS, {"claims": claims, "facts": facts})
        except Exception:
            return {}
        return result if isinstance(result, dict) else {}

    def generic_usage(self, texts: list[str]) -> dict[str, str]:
        """How each expression is used in general, keyed by expression.

        A separate call because the finder cannot answer this: it is looking at one transcript,
        and `_is_grounded` requires everything it returns to appear there. General usage must
        come from OUTSIDE the episode — the two requirements are opposites, and asking one call
        to satisfy both is how it ends up using one task's answer for the other.

        Batched, and never raises: a card without this section is still a card.
        """
        if not texts:
            return {}
        try:
            result = self._json(self.GENERIC_USAGE, {"expressions": texts})
        except Exception:
            return {}
        items = result.get("items") if isinstance(result, dict) else result
        if not isinstance(items, list):
            return {}
        usages: dict[str, str] = {}
        for item in items:
            if not isinstance(item, dict):
                continue
            text = str(item.get("text") or "").strip()
            usage = item.get("usage")
            # A model asked to return null sometimes writes the WORD instead, and one card
            # stored "null" as its 常见用法 section. Checking for emptiness alone missed it.
            if isinstance(usage, str) and usage.strip().lower() in self.PLACEHOLDERS:
                continue
            if not text or not isinstance(usage, str) or not usage.strip():
                # null usage is the honest answer for a one-off coinage, so it is kept out
                # rather than filled with something plausible.
                continue
            # Chinese, checked rather than trusted: one card's 常见用法 opened with "Informal,
            # often ironic or critical register; used in commentary (e.g., op-eds…)" — correct
            # content in the wrong language, which makes the learner read metalanguage instead
            # of an explanation. Dropped rather than kept, since the English example below it
            # still carries the section.
            if not chinese_prose(usage):
                continue
            body = usage.strip()
            # The English sentence is the point of this section: it is what the learner says.
            # An earlier version asked for the situation in Chinese and got 84 cards describing
            # a scene — "保健品公司请明星代言量子能量手环" — from which nothing can be spoken.
            example = item.get("example")
            if isinstance(example, str) and example.strip():
                body += "\n" + example.strip()
                gloss = item.get("example_chinese")
                if isinstance(gloss, str) and gloss.strip():
                    body += "\n" + gloss.strip()
            usages[text] = body
        return usages

    def garbled(self, texts: list[str]) -> set[str]:
        """Which of these are transcription errors rather than English.

        One call for the whole batch, because this is a cheap yes/no about spelling rather than
        a judgement about worth. Needed because the "coined" kind legitimises exactly what a
        garbled word looks like — a made-up-sounding term — and "palunteer" (Palantir),
        "onrem" (on-prem) and "obiated" all became cards on a real run.

        A dictionary was the obvious tool and the wrong one: /usr/share/dict/words rejects
        "blindsided", "codified" and "clunky" while accepting "alpha".
        """
        if not texts:
            return set()
        try:
            result = self._json(self.GARBLED, {"items": texts})
        except Exception:
            # Unchecked, not condemned: the finder had a reason to report these.
            return set()
        listed = result.get("garbled") if isinstance(result, dict) else result
        if not isinstance(listed, list):
            return set()
        return {str(item) for item in listed if isinstance(item, str)}

    def is_compositional(self, text: str, meaning: str) -> bool:
        """True when the learner would produce this expression themselves.

        Named for what the caller does with it — an expression they would already say needs
        no card. Two calls rather than one, and the first must not see the target: shown it,
        the model writes the target back as the learner's own attempt and everything looks
        producible.
        """
        # The CORE meaning, not the encyclopedia entry appended to it. 迷你吧（酒店房间内收费
        # 的小冰箱） describes the thing rather than translating it, which sends the attempts
        # off after a description instead of the phrase.
        attempts = self._json(
            self.LEARNER_ATTEMPTS,
            {"chinese": self._core_meaning(meaning), "situation": "this transcript"},
        )
        listed = attempts.get("attempts") if isinstance(attempts, dict) else attempts
        if not isinstance(listed, list):
            return False
        wordings = [str(a) for a in listed if isinstance(a, str) and a.strip()]
        if not wordings:
            return False
        verdict = self._json(
            self.NATIVE_WOULD_SAY, {"target": text, "learner_attempts": wordings}
        )
        return bool(verdict.get("would_produce")) if isinstance(verdict, dict) else False

    PARENTHETICAL = re.compile(r"[（(][^）)]*[）)]")

    @classmethod
    def _core_meaning(cls, meaning: str) -> str:
        """The translation without its explanatory aside.

        Also takes the first of several senses separated by ；/、 — the comparison is about
        whether the parts reach the meaning, and a list of alternatives is not one meaning.
        """
        stripped = cls.PARENTHETICAL.sub("", meaning).strip()
        for separator in ("；", ";", "，", "、"):
            if separator in stripped:
                stripped = stripped.split(separator)[0].strip()
        return stripped or meaning.strip()

    def hidden_traps(self, sentences: list[TranscriptSegment]) -> list[dict]:
        payload = [{"position": i, "text": s.text} for i, s in enumerate(sentences)]
        return self._expression_list(self._json(self.HIDDEN_TRAPS, {"sentences": payload}))

    @staticmethod
    def _expression_list(result: object) -> list[dict]:
        """The expressions out of either response shape.

        A bare array despite the schema has been observed; accepting both is the difference
        between dropping a whole batch and keeping it.
        """
        if isinstance(result, list):
            return list(result)
        for key in ("expressions", "items"):
            value = result.get(key) if isinstance(result, dict) else None
            if isinstance(value, list):
                return value
        return []

    def classify_material(self, sentences: list[TranscriptSegment]) -> str:
        payload = [sentence.text for sentence in sentences[:60]]
        result = self._json(self.CLASSIFY_MATERIAL, {"sentences": payload})
        material = result.get("material") if isinstance(result, dict) else None
        return "teaching" if material == "teaching" else "native"

class ImportPipeline:
    CHUNK_MS = 900_000

    def __init__(self, repo: Repository, settings: Settings, media: MediaAdapter, ai: AIAdapter):
        self.repo, self.settings, self.media, self.ai = repo, settings, media, ai

    def run(self, job_id: int) -> None:
        job = self.repo.get_job(job_id)
        episode = self.repo.get_episode(job.episode_id)
        root = self.settings.data_dir / "episodes" / str(episode.id)
        try:
            self.repo.upsert_job(job_id, stage="metadata", progress=5)
            metadata = self.media.metadata(episode.source_url)
            with self.repo.session() as session:
                stored = session.get(type(episode), episode.id)
                stored.title, stored.channel, stored.duration_ms, stored.thumbnail_url = metadata.title, metadata.channel, metadata.duration_ms, metadata.thumbnail_url
                stored.stream_url, stored.stream_url_expires_at = metadata.stream_url, metadata.stream_url_expires_at
                stored.status = "processing"
                stored.error = None
                session.commit()
            self.repo.upsert_job(job_id, stage="audio", progress=15)
            audio = root / "source.mp3"
            # Existence is not enough: a file left by a run that predates the CBR
            # re-encode (or that died mid-import) is VBR, and AVPlayer drifts on
            # VBR. Reusing it meant no retry could ever fix the desync, because
            # the re-encode lives inside download_audio. Observed on a real
            # import: 15 distinct packet sizes at 103kbps, against 128k CBR.
            if not audio.exists() or not self.media.is_constant_bitrate(audio):
                self.media.download_audio(episode.source_url, audio)
            self.repo.set_audio_path(episode.id, str(audio.relative_to(self.settings.data_dir)))
            if job.stage == "audio_backfill":
                with self.repo.session() as session:
                    stored = session.get(type(episode), episode.id)
                    stored.status = "ready"
                    stored.error = None
                    session.commit()
                self.repo.upsert_job(job_id, stage="complete", progress=100, status="complete")
                return
            self.repo.upsert_job(job_id, stage="transcription", progress=16)
            source_captions, _ = self.media.captions(episode.source_url, root / "captions")
            all_segments = source_captions
            if not all_segments:
                parts = self.media.split_audio(audio, root / "chunks")
                self.repo.upsert_job(job_id, stage="transcription", progress=17)
                completed = self.repo.completed_chunks(job_id)
                for index, part in enumerate(parts):
                    if index in completed:
                        raw = json.loads(completed[index].transcript_json or "[]")
                        segments = [TranscriptSegment(**item) for item in raw]
                    else:
                        segments = self.ai.transcribe(part, index * self.CHUNK_MS)
                        self.repo.save_chunk(job_id, index, index * self.CHUNK_MS, (index + 1) * self.CHUNK_MS, str(part), json.dumps([asdict(s) for s in segments]))
                    all_segments.extend(segments)
            # 20, not 70. The old numbers were assigned by stage ORDER rather than by how long
            # a stage takes, so the bar reached 88% eight seconds into a 124-second import and
            # then crawled. Measured shares on a reprocess: chapters 29% of the wait, the scan
            # 65%. These percentages now follow that.
            self.repo.upsert_job(job_id, stage="translation", progress=20)
            # Always translate each source sentence directly. Reusing YouTube's
            # zh-Hans auto-caption track (the old _align_chinese path) time-aligned
            # two INDEPENDENT caption timelines by interval overlap, which both
            # duplicated Chinese (adjacent source sentences overlap, so one zh
            # fragment landed in several) and drifted (the two tracks' offsets
            # diverge over the episode). AI per-sentence translation is 1:1 by
            # construction — no duplication, no drift.
            translations = self._translate(all_segments, root / "translations", job_id)
            self.repo.upsert_job(job_id, stage="indexing", progress=30)
            chapters = self._chapters(all_segments)
            # 36 between the two, because each of these is ONE model call and cannot report
            # partway through. Splitting the span at least distinguishes "still chaptering"
            # from "chaptering done, classifying" instead of one 29-second flat spot.
            self.repo.upsert_job(job_id, stage="indexing", progress=36)
            material_kind = self._material_kind(all_segments)
            self.repo.upsert_job(job_id, stage="learning", progress=40)
            self.repo.set_material_kind(episode.id, material_kind)
            # Scanned for the two failures a learner cannot ask about, and nothing else.
            # The full extraction this replaced pre-picked hundreds of expressions per
            # episode — a shelf nobody opened, and, since highlights are drawn from the
            # same rows, a transcript marked up with words nobody chose.
            #
            # material_kind decides which question gets asked: native speech is scanned for
            # senses that are wrong HERE, a lesson for expressions that would still stop the
            # learner once the explanation is gone.
            traps = self._hidden_traps(all_segments, material_kind, job_id)
            sentences = [{"start_ms": s.start_ms, "end_ms": s.end_ms, "speaker": s.speaker, "source_text": s.text, "chinese": cn} for s, cn in zip(all_segments, translations, strict=True)]
            self.repo.replace_learning_content(episode.id, chapters, sentences, traps)
            # The 洞察 page: what an hour of native material argued, in five minutes of Chinese.
            # Native only — a lesson's content IS the language, so there is no separate argument
            # to extract from it.
            if material_kind == "native":
                self.repo.upsert_job(job_id, stage="insight", progress=88)
                insight = self._insight(all_segments, job_id)
                if insight:
                    self.repo.set_insight(episode.id, json.dumps(insight, ensure_ascii=False))
            self.repo.upsert_job(job_id, stage="complete", progress=100, status="complete")
        except Exception as exc:
            self.repo.upsert_job(job_id, stage=self.repo.get_job(job_id).stage, progress=self.repo.get_job(job_id).progress, status="failed", error=str(exc))
            if not self.repo.has_learning_content(episode.id):
                self.repo.fail_episode(episode.id, str(exc))
            raise

    def _translate(self, segments: list[TranscriptSegment], cache_dir: Path, job_id: int) -> list[str]:
        cache_dir.mkdir(parents=True, exist_ok=True)
        batch_size = max(1, self.settings.translation_batch_size)
        total_batches = (len(segments) + batch_size - 1) // batch_size
        if total_batches == 0:
            return []

        batches: list[list[str] | None] = [None] * total_batches
        pending: list[tuple[int, list[str], Path]] = []
        for batch_index, start in enumerate(range(0, len(segments), batch_size)):
            texts = [item.text for item in segments[start:start + batch_size]]
            cache_path = cache_dir / f"{batch_index:03d}.json"
            batch = json.loads(cache_path.read_text()) if cache_path.exists() else None
            if isinstance(batch, list) and len(batch) == len(texts) and all(map(self._is_translated, texts, batch)):
                batches[batch_index] = batch
            else:
                pending.append((batch_index, texts, cache_path))

        completed = total_batches - len(pending)
        self.repo.upsert_job(job_id, stage="translation", progress=20 + int(10 * completed / total_batches))
        if pending:
            workers = max(1, min(self.settings.translation_concurrency, len(pending)))
            with ThreadPoolExecutor(max_workers=workers) as executor:
                futures = {
                    executor.submit(self._translate_exact, texts): (batch_index, cache_path)
                    for batch_index, texts, cache_path in pending
                }
                for future in as_completed(futures):
                    batch_index, cache_path = futures[future]
                    batch = future.result()
                    cache_path.write_text(json.dumps(batch, ensure_ascii=False))
                    batches[batch_index] = batch
                    completed += 1
                    progress = 20 + int(10 * completed / total_batches)
                    self.repo.upsert_job(job_id, stage="translation", progress=progress)

        translated: list[str] = []
        for batch_index, batch in enumerate(batches):
            if batch is None:
                raise ValueError(f"Translation batch {batch_index} did not complete")
            translated.extend(batch)
        return translated

    @staticmethod
    def _contains_cjk(text: object) -> bool:
        return isinstance(text, str) and any("\u4e00" <= character <= "\u9fff" for character in text)

    @staticmethod
    def _has_translatable_words(source: str) -> bool:
        """Is there prose here, or only codes, acronyms and numbers?

        A word needs two letters and at least one lowercase letter to count.
        "DEP40." and "IELTS" carry nothing to translate; "Goodbye." does.
        """
        for token in re.findall(r"[^\W\d_]+", source):
            if len(token) > 1 and token != token.upper():
                return True
        return False

    @classmethod
    def _is_translated(cls, source: str, translated: object) -> bool:
        """Accept a response with no Chinese only when none was possible.

        "DEP40." is a promo code: the model correctly echoes it, so demanding
        CJK rejected a right answer and failed the whole episode once recursion
        narrowed to that one sentence. An untranslated English sentence still
        fails, because it has real words and comes back with no Chinese.
        """
        if not isinstance(translated, str):
            return False
        return cls._contains_cjk(translated) or not cls._has_translatable_words(source)

    def _translate_exact(self, texts: list[str]) -> list[str]:
        try:
            batch = self.ai.translate(texts)
            if len(batch) == len(texts) and all(map(self._is_translated, texts, batch)):
                return batch
            if len(texts) == 1:
                raise ValueError("Translation API did not return Chinese translation")
        except Exception:
            if len(texts) == 1:
                raise
        if len(texts) == 1:
            raise ValueError("Translation API did not return exactly one item for one sentence")
        middle = len(texts) // 2
        return self._translate_exact(texts[:middle]) + self._translate_exact(texts[middle:])

    def _material_kind(self, sentences: list[TranscriptSegment]) -> str:
        """Which kind of source this is, defaulting to native if unknowable.

        A misclassification costs one batch of less-apt extraction; a raised
        exception would cost the whole import, so this never propagates.
        """
        try:
            return "teaching" if self.ai.classify_material(sentences) == "teaching" else "native"
        except Exception:
            return "native"

    def _remap_occurrence(occurrence: object, offset: int) -> dict | None:
        """Shift a batch-local position into the transcript's own numbering.

        The model reports offsets as JSON strings often enough that arithmetic on
        the raw value raises TypeError, and it sometimes omits a key entirely. An
        unusable occurrence is dropped rather than allowed to fail the import: the
        recursive retry above only guards the API call, so a bad value here would
        escape and lose every expression in the transcript.
        """
        if not isinstance(occurrence, dict):
            return None
        try:
            position = int(occurrence["sentence_position"])
            start = int(occurrence["start_offset"])
            end = int(occurrence["end_offset"])
        except (KeyError, TypeError, ValueError):
            return None
        return {**occurrence, "sentence_position": position + offset, "start_offset": start, "end_offset": end}

    # 40 lines per call: enough context to tell a shifted sense from an ordinary one,
    # small enough that one bad batch loses little. Sequential, not concurrent — this scan
    # returns nothing for most batches, so there is no long tail to parallelise away, and
    # the old version's thread pool existed for a workload that no longer exists.
    TRAP_BATCH = 40

    # How many times each batch is scanned.
    #
    # Not redundancy — coverage. One pass SAMPLES a batch rather than enumerating it: five
    # runs of the same 40 lines returned 16 distinct items with ZERO overlap, every one
    # appearing exactly once. A missing expression therefore looks like a filtering bug and is
    # usually a sampling one.
    #
    # Measured union growth on one batch: 11 items after one pass, 23 after two, 26, 31, 34,
    # 34. Pass two is the real win and it keeps creeping after that, so 3 is a cost choice
    # (3× a stage that runs once per import), not a convergence point. Raising it finds more.
    #
    # Honest limit: "unlimited in-n-out" — the expression that prompted this — still did not
    # appear in six passes. Rare items stay rare, and this makes the tail smaller rather than
    # empty. Asking the teacher directly is still the reliable way to get a specific one.
    TRAP_PASSES = 3

    # Expressions per general-usage call. NOT the whole episode at once: measured on ep8, one
    # call covering all 140 answered 18 of them while batches of 20 answered 79. A long list
    # gets skimmed, and the skipped ones look exactly like "this has no general usage".
    USAGE_BATCH = 20

    # Second-pass size for expressions the first pass skipped. Small enough that the model
    # answers each one rather than skimming past it.
    USAGE_RETRY_BATCH = 5

    # Shapes no expression has, checkable without a model call. Each was a real result:
    # "P level" and "M Club" are a parking sign and a lounge brand; "Stay close to me" and
    # "I want to see where you go" are whole lines of dialogue from a graded story.
    #
    # A LONE capital letter is a label. Not "I", which is both — matching it rejected every
    # first-person frame ("Could I get a late checkout" read as a brand name), and that is
    # most of what a learner needs to SAY.
    LABEL = re.compile(r"^(?!I$)[A-Z]$")
    IMPERATIVE = re.compile(r"^(stay|come|let|go|don't|do not|please)\b", re.IGNORECASE)
    PARTICLE_END = re.compile(r"\b(through|off|on|in|out|up|down|with|for)$", re.IGNORECASE)

    # A pattern is a frame with slots, so it is necessarily longer than a phrase: "Would you
    # like any help with ___" is six words and exactly the point. Phrases stay capped at four
    # to keep whole lines of dialogue out. Seven for a pattern, because eight and nine let
    # narrated lines through — "call ___ by just dialing up a number" was one.
    MAX_PHRASE_WORDS = 4
    MAX_PATTERN_WORDS = 7

    # The host DESCRIBING what hotels do. Information, not something to put in the learner's
    # mouth, and the one shape a regex calls reliably: "they will ask for your ___", "there's a
    # safe where you keep ___", "all of these things are called ___".
    NARRATION = re.compile(r"^(they|he|she|it|it's|there|there's|all of|these|those)\b", re.I)

    # Determiners and glue prepositions. A PARTICLE after a verb ("plug ___ in") carries the
    # meaning and a noun after the slot ("on the ___ floor") is the frame's whole point, so
    # neither is filler — counting them as such rejected both.
    FRAME_FILLER_WORDS = frozenset({
        "the", "a", "an", "to", "of", "your", "my", "our", "their", "them", "it",
        "is", "are", "be", "that", "this", "some", "any",
    })

    @classmethod
    def _mechanically_rejected(cls, text: str, kind: str = "set_phrase") -> str | None:
        """Why this cannot be a studiable expression, or None if it might be."""
        words = text.split()
        if not words:
            return "empty"
        if any(cls.LABEL.fullmatch(word) for word in words):
            return "label"
        limit = cls.MAX_PATTERN_WORDS if kind == "pattern" else cls.MAX_PHRASE_WORDS
        if len(words) > limit:
            return "sentence"
        # An instruction to the listener. Excluded only when it does NOT end in a particle,
        # so "go through" and "drop off" survive while "stay together" does not. A pattern is
        # exempt: "Let me know if ___" is an imperative frame worth having.
        if (kind != "pattern" and cls.IMPERATIVE.match(text) and len(words) > 1
                and not cls.PARTICLE_END.search(text)):
            return "imperative"
        # A capital inside the phrase is a name. "I" is the one ordinary exception.
        if len(words) > 1 and any(
            word[:1].isupper() and word.lower() != "i" for word in words[1:]
        ):
            return "proper noun"
        # A SINGLE capitalised word is also a name, and this rule only looked from the second
        # word on — so "Palanteer" and "Neotron" (garbled Palantir and Nvidia) became cards.
        # The transcript capitalises mid-sentence words only for names, since it is machine
        # punctuation rather than prose.
        if len(words) == 1 and words[0][:1].isupper() and words[0].lower() != "i":
            return "proper noun"
        if kind == "pattern":
            return cls._weak_frame(text)
        return None

    @classmethod
    def _weak_frame(cls, text: str) -> str | None:
        """Why this frame is not worth a card.

        Three-pass scanning raised coverage and exposed the quality gate as the bottleneck:
        one 122-line lesson produced 22 patterns, 16 of them weak. They shared shapes:
        third-person narration about what hotels do, two slots with no fixed frame left
        between them, and a slot glued to a single content word.
        """
        if cls.NARRATION.match(text.strip()):
            return "narration"
        # Two slots means the frame is mostly hole: "they have ___ where you can ___".
        if len(cls.SLOT.findall(text)) > 1:
            return "two slots"
        # Two clauses is a sentence someone said, not a frame to reuse.
        if re.search(r"\band\b", text, re.IGNORECASE):
            return "two clauses"
        body = re.sub(r"[^\w' ]", " ", cls.SLOT.sub(" ", text))
        content = [w for w in body.split() if w.lower() not in cls.FRAME_FILLER_WORDS]
        # "under the ___", "return ___", "tip the ___": a blank plus one word teaches the word,
        # which a phrase card already does better.
        if len(content) < 2:
            return "too bare"
        return None

    # Determiners and possessives, which vary between mentions of the same phrase.
    INFLECTION = re.compile(r"\b(a|an|the|your|his|her|their|its|my|our)\b")
    # A bare object pronoun at the END, which carries no meaning of its own: "obfuscate" and
    # "obfuscates it" arrived as two cards on a real run, differing only by this. Anchored to
    # the end so "it" inside a phrase ("call it a day") is untouched, and applied only when
    # something precedes it, so the pronoun alone is not stripped to nothing.
    TRAILING_OBJECT = re.compile(r"\s+(it|them|this|that)$", re.IGNORECASE)
    # Function words a frame varies freely: the slot absorbs whatever follows, so "drop me off
    # ___" and "drop me off at the ___" are one pattern written two ways.
    FRAME_FILLER = re.compile(r"\b(a|an|the|at|to|in|on|for|of|it|your|my|our|their|his|her)\b")

    @classmethod
    def _dedup_key(cls, text: str, kind: str = "set_phrase") -> str:
        """One key for what is really one expression.

        A real run produced both "tip your housekeeper" and "tip the housekeeper" as separate
        cards. Keying on exact text splits every phrase whose determiner the speaker varied,
        and the learner gets the same card twice.

        Patterns need more than that. Three passes over one transcript produced "drop me off
        ___", "drop me off at ___" and "drop me off at the ___" — one frame, three cards —
        plus "plug ___ in" beside "plug a ___". A frame's identity is its CONTENT words; the
        preposition and the slot's position are exactly what varies between two people saying
        the same thing.
        """
        lowered = text.casefold()
        if kind == "pattern":
            # The slot marker itself goes too: whether the blank sits mid-frame or at the end
            # is not a difference worth a second card.
            without_slots = cls.SLOT.sub(" ", lowered.replace("{", " ").replace("}", " "))
            stripped = cls.FRAME_FILLER.sub(" ", without_slots)
            return " ".join(stripped.split()).strip(" .?!,")
        # Stems, so a word's grammatical form is not a second card. A real native run produced
        # "intelligence sovereignty" beside "intelligent sovereignty" — one concept the speaker
        # kept rephrasing, and three passes each caught a different wording of it.
        #
        # NOT sorted for phrases: "check in" and "check out" must stay apart, and word order is
        # what distinguishes many pairs like them.
        stripped = cls.TRAILING_OBJECT.sub("", cls.INFLECTION.sub(" ", lowered).strip())
        return " ".join(cls._stem(word) for word in stripped.split())

    # Suffixes stripped when comparing two expressions. Crude on purpose: this only has to see
    # "intelligence" and "intelligent" as the same word, not do real morphology.
    # "es" is absent on purpose: stripping both letters made "obfuscates" -> "obfuscat" while
    # "obfuscate" kept its e, so the two never met. The plain "s" rule handles it and leaves the
    # stem-final e in place for both.
    STEM_SUFFIXES = ("ences", "ence", "ents", "ent", "ing", "ers", "er", "s", "ed", "ly")

    @classmethod
    def _stem(cls, word: str) -> str:
        for suffix in cls.STEM_SUFFIXES:
            # The length guard keeps short words intact: "es" off "yes", "s" off "is".
            if len(word) > len(suffix) + 3 and word.endswith(suffix):
                return word[: -len(suffix)]
        return word

    SLOT = re.compile(r"_+")

    @classmethod
    def _pattern_is_grounded(cls, text: str, transcript: str) -> bool:
        """Whether the frame's own words were actually said here.

        Patterns are the one kind the model will INVENT. Given "Could I get ___?" as an
        example in the prompt it returned exactly that, in two different batches, for a
        transcript containing neither "could I get" nor "do you have any" — generic hotel
        English rather than anything the learner heard. An invented frame also cannot anchor
        a highlight, so it is a card attached to nothing.
        """
        haystack = " ".join(transcript.casefold().split())
        # Each run of words between slots must appear. Checking the longest alone would pass
        # a frame whose other half was invented.
        segments = [
            " ".join(part.casefold().split())
            for part in cls.SLOT.split(text)
            if part.strip(" ?!.,")
        ]
        meaningful = [seg.strip(" ?!.,") for seg in segments if len(seg.strip(" ?!.,")) > 2]
        if not meaningful:
            return False
        return all(seg in haystack for seg in meaningful)

    @classmethod
    def _contains_garbled(cls, text: str, garbled: set[str]) -> bool:
        """Whether any flagged mis-transcription appears in this expression.

        Not exact matching. Asked about "monopsiny buyer situation", the model returns the
        garbled WORD — "monopsiny" — rather than the phrase it was given, so an exact-match
        filter removed nothing and the card survived a real run. Matched per word, since a
        phrase built on a mis-transcribed word is just as unusable as the word alone.
        """
        if not garbled:
            return False
        flagged_words = {
            word
            for item in garbled
            for word in re.sub(r"[^\w' ]", " ", item.casefold()).split()
        }
        words = set(re.sub(r"[^\w' ]", " ", text.casefold()).split())
        return bool(words & flagged_words)

    # A transcript speaker marker ANYWHERE, not just at the start: ">> When's the last time we
    # heard >> Unfortunately..." is two speakers in one blob, and stripping only the leading
    # marker left the second one in the middle of the "sentence".
    SPEAKER_MARKER = re.compile(r"\s*>>\s*")
    STUTTER = re.compile(r"\b(\w+)( \1\b)+", re.IGNORECASE)

    # Beyond this an "example" is a passage, not a sentence, and shows the learner nothing
    # about the expression's shape.
    MAX_EXAMPLE_CHARS = 220

    @classmethod
    def _example_line(cls, text: str, raw: object) -> str:
        """One sentence containing the expression, or a hard-capped fallback.

        The example is the one section a card cannot do without, so unlike 这集里 this cannot
        simply be dropped — but it must not be a paragraph either. When no sentence contains the
        expression, the raw text is truncated rather than stored whole.
        """
        passage = str(raw or "")
        line = cls._source_line(text, passage)
        if line and len(line) <= cls.MAX_EXAMPLE_CHARS:
            return line
        candidate = line or " ".join(cls.SPEAKER_MARKER.sub(" ", passage).split())
        if len(candidate) <= cls.MAX_EXAMPLE_CHARS:
            return candidate
        return candidate[: cls.MAX_EXAMPLE_CHARS].rsplit(" ", 1)[0] + "…"

    # Words that mean the sentence is talking ABOUT this episode rather than defining the
    # expression: "此处…", "说话人用它表示…". A company name is NOT evidence — "frontier labs"
    # legitimately means OpenAI, Anthropic and DeepMind, so naming them is the definition.
    EPISODE_DEICTIC = re.compile(
        r"此处|本集|这集里|本语境|该语境|说话人|主播|\bspeaker\b", re.IGNORECASE)

    # A qualifier the model puts in FRONT of the definition — "（本语境中）一种刻意夸张的姿态"
    # — where there is no earlier clause to cut back to. Dropping the bracket leaves the
    # definition itself intact.
    LEADING_QUALIFIER = re.compile(
        r"^\s*[（(][^）)]{0,24}(?:此处|本集|这集里|本语境|该语境|说话人|主播)[^）)]{0,24}[）)]\s*")

    @classmethod
    def _general_definition(cls, value: object) -> str | None:
        """The definition with this episode's argument cut off, or None.

        The prompt forbids folding the speaker's argument into the gloss and 22 of 132 cards did
        it anyway — "…夸张地做出惊恐姿态；此处被 speaker 用作批判性标签，特指 Anthropic 在 AI
        风险叙事中…". The learner then meets the word elsewhere and the card teaches them the
        accusation. 这集里 already holds that half, so this is duplication as well as pollution.

        Cut at the clause boundary rather than rejected: the part BEFORE the deixis is a good
        definition, and throwing it away would lose the only section every card needs.
        """
        text = chinese_prose(value)
        if not text:
            return None
        # Strip a leading "（本语境中）" first: it sits at position 1, so the clause-boundary
        # search below has nothing before it to cut back to and would keep the whole string.
        text = cls.LEADING_QUALIFIER.sub("", text).strip()
        match = cls.EPISODE_DEICTIC.search(text)
        if not match:
            return text
        # Prefer cutting at the last clause break before the deixis, so the definition ends
        # cleanly instead of mid-sentence.
        head = text[: match.start()]
        for sep in ("；", ";", "。", "，", ","):
            if sep in head:
                head = head.rsplit(sep, 1)[0]
                break
        head = head.strip(" ；;。，,、")
        # The deixis can sit INSIDE a parenthetical — "（源自…操作'双击'，此处为比喻）" — and
        # cutting there left an unclosed bracket on a real card. Drop the dangling opener.
        if head.count("（") > head.count("）"):
            head = head[: head.rindex("（")].strip(" ；;。，,、")
        if head.count("(") > head.count(")"):
            head = head[: head.rindex("(")].strip(" ；;。，,、")
        # Too little left to be a definition — better the original than a fragment. This also
        # covers a definition that OPENS with the deixis: "说话人临时创造的术语，指…" is not
        # pollution, it is what a coined term's definition looks like.
        return head if len(_HAN.findall(head)) >= 4 else text

    # Beyond this an "example" is a passage, not a sentence, and shows the learner nothing
    # about the expression's shape.
    MAX_EXAMPLE_CHARS = 220

    @classmethod
    def _example_line(cls, text: str, raw: object) -> str:
        """One sentence containing the expression, or a hard-capped fallback.

        The example is the one section a card cannot do without, so unlike 这集里 this cannot
        simply be dropped — but it must not be a paragraph either. When no sentence contains the
        expression, the raw text is truncated rather than stored whole.
        """
        passage = str(raw or "")
        line = cls._source_line(text, passage)
        if line and len(line) <= cls.MAX_EXAMPLE_CHARS:
            return line
        candidate = line or " ".join(cls.SPEAKER_MARKER.sub(" ", passage).split())
        if len(candidate) <= cls.MAX_EXAMPLE_CHARS:
            return candidate
        return candidate[: cls.MAX_EXAMPLE_CHARS].rsplit(" ", 1)[0] + "…"

    # Words that mean the sentence is talking ABOUT this episode rather than defining the
    # expression: "此处…", "说话人用它表示…". A company name is NOT evidence — "frontier labs"
    # legitimately means OpenAI, Anthropic and DeepMind, so naming them is the definition.
    EPISODE_DEICTIC = re.compile(r"此处|本集|这集里|说话人|主播|\bspeaker\b", re.IGNORECASE)
    HAN = re.compile(r"[\u4e00-\u9fff]")

    @classmethod
    def _chinese_only(cls, value: object) -> str | None:
        """A Chinese explanation, or nothing.

        Fields asked for in Chinese come back in English often enough to matter: one run
        produced 196 of 196 cards whose 这集里 was raw transcript. The card renders whatever is
        here, so a wrong-language value is worse than an empty one — it occupies the section
        that was supposed to explain what the speaker meant.
        """
        if not isinstance(value, str):
            return None
        text = value.strip()
        if not text:
            return None
        # A real Chinese gloss is mostly Han characters even when it quotes English terms.
        return text if len(cls.HAN.findall(text)) >= max(2, len(text) // 10) else None

    @classmethod
    def _source_line(cls, text: str, passage: str) -> str:
        """The ONE sentence containing this expression, cleaned up.

        The card shows this so the learner can see the expression's real shape — where it
        begins and ends, what it collocates with. A paragraph cannot do that: the field
        averaged 111 characters and ran to 1590 on a real episode, at which point it held the
        same text as the example field and neither was usable.

        Speaker markers and stutters are stripped because they are transcription artefacts, not
        English: ">> he did respond to me. I mean, I I want to center myself" is not a sentence
        anyone said.
        """
        # A speaker change is a sentence boundary even without punctuation, so split there too.
        cleaned = cls.STUTTER.sub(r"\1", cls.SPEAKER_MARKER.sub(" | ", passage)).strip(" |")
        needle = " ".join(text.casefold().split())
        sentences = [
            part.strip(" |")
            for chunk in cleaned.split("|")
            for part in re.split(r"(?<=[.!?])\s+", chunk)
            if part.strip(" |")
        ]
        for sentence in sentences:
            if needle and needle in " ".join(sentence.casefold().split()):
                return sentence
        # Not found. Return NOTHING rather than a guess: matching on the first word gave
        # "clear all the pathways" the line "Now, [clears throat] do it." — a wrong source line
        # is worse than an absent one, because the learner cannot tell it is wrong. An empty
        # value also means the card simply omits the section, which the view already handles.
        return ""

    @classmethod
    def _is_grounded(cls, text: str, transcript: str) -> bool:
        """Whether this expression was actually said in the passage it came from.

        Applies to every kind, not just frames. Naming example expressions in a prompt gets
        them returned verbatim: a draft of HIDDEN_TRAPS mentioned "blindsided", "clunky" and
        "job displacement", and a batch containing none of the three reported all three. The
        instruction "only report what is present" did not hold on its own, which is why this
        check lives in code.

        An ungrounded item is also a card anchored to nothing — the store locates an expression
        by searching the transcript for its text, so it would have no occurrence to highlight.
        """
        needle = " ".join(text.casefold().split()).strip(" ?!.,")
        if not needle:
            return False
        return needle in " ".join(transcript.casefold().split())

    def _report(self, job_id: int | None, stage: str, progress: int) -> None:
        """Progress, if there is a job to report it against.

        Optional because `_hidden_traps` is called directly in tests, where there is no job
        row — and a scan must never fail for want of somewhere to report to. Writes are
        best-effort for the same reason: this is called from a completion loop, and losing the
        bar is not worth losing the import.
        """
        if job_id is None:
            return
        try:
            self.repo.upsert_job(job_id, stage=stage, progress=progress)
        except Exception:
            pass

    def _scan_once(self, batch: list[TranscriptSegment], teaching: bool) -> list:
        """One finder call. Runs on a worker thread, so it must not touch shared state.

        AttributeError is NOT one of the failures worth absorbing: it means the adapter has no
        such method, which is a wiring mistake rather than a flaky provider. Swallowed once, it
        produced a complete import with zero cards and no trace anywhere — I had put both
        methods on the Protocol instead of the adapter, and this except turned that into "the
        material contains nothing".
        """
        try:
            return list(self.ai.teaching_traps(batch) if teaching else self.ai.hidden_traps(batch))
        except AttributeError:
            raise
        except Exception:
            # One failed pass costs a little coverage; the other passes still ran.
            return []

    # Lines per insight chunk. The whole transcript fits one call (~26,500 tokens for the
    # longest episode here), and that is exactly the temptation to avoid: the middle of a long
    # text is where a model stops reading closely. Roughly ten minutes of speech per chunk.
    INSIGHT_CHUNK_LINES = 80

    def _insight(self, segments: list, job_id: int) -> dict | None:
        """Read the episode for its argument, then shape it into one page.

        Two passes for a reason. A chunk pass reads closely enough to catch who disagreed with
        whom — the thing a single whole-transcript call flattens first. A synthesis pass then sees
        the shape across chunks, which no chunk can.
        """
        chunks = [segments[i:i + self.INSIGHT_CHUNK_LINES]
                  for i in range(0, len(segments), self.INSIGHT_CHUNK_LINES)]
        if not chunks:
            return None

        def read(chunk: list) -> dict:
            lines = [{"at_ms": seg.start_ms, "text": seg.text} for seg in chunk]
            try:
                return self.ai.insight_chunk(lines)
            except AttributeError:
                raise
            except Exception as exc:
                # One unreadable chunk costs its claims, not the page.
                print(f"insight chunk of {len(lines)} lines failed: {exc!r}", flush=True)
                return {"claims": [], "facts": []}

        claims: list[dict] = []
        facts: list[dict] = []
        workers = max(1, min(self.settings.scan_concurrency, len(chunks)))
        with ThreadPoolExecutor(max_workers=workers) as executor:
            for done, result in enumerate(executor.map(read, chunks), start=1):
                claims.extend(result.get("claims", []))
                facts.extend(result.get("facts", []))
                self._report(job_id, "insight", 88 + int(8 * done / len(chunks)))

        if not claims and not facts:
            return None
        page = self.ai.insight_synthesis(claims, facts)
        return self._clean_insight(page, total_ms=segments[-1].end_ms if segments else 0)

    # A page longer than this is the problem it exists to solve. 5-10 minutes of Chinese reading.
    MAX_INSIGHT_CHARS = 2600

    @staticmethod
    def _overlap_ratio(text: str, others: list[str]) -> float:
        """How much of `text` is already said in `others`, by character trigram."""
        grams = {text[i:i + 3] for i in range(max(0, len(text) - 2))}
        if not grams:
            return 1.0
        seen: set[str] = set()
        for other in others:
            seen |= {other[i:i + 3] for i in range(max(0, len(other) - 2))}
        return len(grams & seen) / len(grams)

    @classmethod
    def _clean_insight(cls, page: object, total_ms: int) -> dict | None:
        """The page, with the four rules enforced here rather than hoped for in the prompt.

        Every one of them has failed a prompt-only instruction elsewhere this session: fields came
        back in English, sections were padded, and a "don't restate" instruction is exactly the
        kind a model satisfies by rewording.
        """
        if not isinstance(page, dict):
            return None
        thesis = chinese_prose(page.get("thesis"))
        if not thesis:
            return None

        def offset(value: object) -> int | None:
            if not isinstance(value, (int, float)):
                return None
            ms = int(value)
            # A claim pointing outside the episode is worse than one with no anchor: tapping it
            # would seek nowhere.
            return ms if 0 <= ms <= max(total_ms, 0) else None

        claims = []
        for item in page.get("claims") or []:
            if not isinstance(item, dict):
                continue
            claim = chinese_prose(item.get("claim"))
            if not claim:
                continue
            claims.append({
                "claim": claim,
                # Kept even when absent — "they offer nothing" is itself worth knowing.
                "evidence": chinese_prose(item.get("evidence")),
                "dispute": chinese_prose(item.get("dispute")),
                "at_ms": offset(item.get("at_ms")),
            })
        claims = claims[:5]

        facts = []
        for item in page.get("facts") or []:
            if not isinstance(item, dict):
                continue
            fact = chinese_prose(item.get("fact"))
            if not fact:
                continue
            facts.append({
                "fact": fact,
                # Default UNSOURCED. A number said off the cuff read as established is the
                # failure that matters, so anything not explicitly true is treated as not sourced.
                "sourced": item.get("sourced") is True,
                "at_ms": offset(item.get("at_ms")),
            })
        facts = facts[:8]

        # Takeaways must be inferences. Restatement is what a model produces when asked for
        # insight and given none, and a reader who finds it here stops trusting the section — so
        # anything mostly present in the thesis, claims or facts is dropped rather than shown.
        said = [thesis] + [c["claim"] for c in claims] + [f["fact"] for f in facts]
        takeaways = []
        for item in page.get("takeaways") or []:
            text = chinese_prose(item if isinstance(item, str) else (item or {}).get("takeaway"))
            if text and cls._overlap_ratio(text, said) < 0.6:
                takeaways.append(text)
        takeaways = takeaways[:3]

        anchors = []
        for item in page.get("anchors") or []:
            if not isinstance(item, dict):
                continue
            at_ms = offset(item.get("at_ms"))
            why = chinese_prose(item.get("why"))
            if at_ms is not None and why:
                anchors.append({"at_ms": at_ms, "why": why})
        anchors = anchors[:4]

        if not claims and not facts:
            return None
        page = {"thesis": thesis, "claims": claims, "facts": facts,
                "takeaways": takeaways, "anchors": anchors}
        # Trim from the tail if it overran: claims carry the argument, so facts go first.
        while cls._insight_length(page) > cls.MAX_INSIGHT_CHARS and len(page["facts"]) > 3:
            page["facts"].pop()
        while cls._insight_length(page) > cls.MAX_INSIGHT_CHARS and len(page["claims"]) > 3:
            page["claims"].pop()
        return page

    @staticmethod
    def _insight_length(page: dict) -> int:
        parts = [page["thesis"]]
        for claim in page["claims"]:
            parts += [claim["claim"], claim.get("evidence") or "", claim.get("dispute") or ""]
        parts += [f["fact"] for f in page["facts"]]
        parts += page["takeaways"]
        parts += [a["why"] for a in page["anchors"]]
        return sum(len(p) for p in parts)

    def _hidden_traps(self, sentences: list[TranscriptSegment], material_kind: str,
                      job_id: int | None = None) -> list[dict]:
        """The expressions worth a card, across the whole transcript.

        Never raises: a scan that fails costs the learner nothing they had before, while a
        raised exception would cost them the transcript, translation and audio they waited
        for. Same reasoning as `_material_kind`.

        Reports progress across 40..99 as work completes. This is 65% of an import's wall
        clock, and it used to set 40% once and then say nothing for a minute — a frozen bar
        is indistinguishable from a hung import.
        """
        teaching = material_kind == "teaching"
        found: list[dict] = []
        # Verdicts by text, NOT a seen-set that skips repeats. The store merges items by text
        # into one expression and anchors an occurrence per reported position, so dropping a
        # phrase's second appearance highlights only its first. This caches the two
        # verification calls instead, which is what deduping was actually for.
        verdicts: dict[str, bool] = {}
        # The wording each key was first seen as, so every later variant is rewritten to it.
        canonical: dict[str, str] = {}
        # Candidates awaiting the producibility check, deduped by key so a phrase appearing in
        # three passes is verified once rather than three times.
        needs_verifying: dict[str, tuple[str, str]] = {}

        # Every finder call runs concurrently, because none of them depends on another. This
        # stage was the slowest part of an import purely because it waited: batches × passes
        # calls, one at a time. The batch/pass structure itself is unchanged — one pass SAMPLES
        # a batch rather than enumerating it (five runs of the same 40 lines returned 16 items
        # with ZERO overlap, which is why "unlimited in-n-out" went missing), so the union of
        # several passes is what makes coverage acceptable.
        #
        # Results are stored BY (batch, pass) and read back in that order, never in completion
        # order. `as_completed` alone made the output racy in a way that reached the learner:
        # one frame arrives worded differently on different passes ("hello ___ world" vs "hello
        # world ___"), and `canonical` keeps whichever it sees FIRST, so the wording on the card
        # depended on which thread won. The test for it failed about half the time.
        batch_starts = list(range(0, len(sentences), self.TRAP_BATCH))
        jobs = [(start, attempt)
                for start in batch_starts
                for attempt in range(self.TRAP_PASSES)]
        results: dict[tuple[int, int], list] = {}
        if jobs:
            workers = max(1, min(self.settings.scan_concurrency, len(jobs)))
            with ThreadPoolExecutor(max_workers=workers) as executor:
                futures = {
                    executor.submit(self._scan_once,
                                    sentences[start:start + self.TRAP_BATCH], teaching): (start, attempt)
                    for start, attempt in jobs
                }
                done = 0
                for future in as_completed(futures):
                    results[futures[future]] = future.result()
                    done += 1
                    # 40..70 for finding. Reported as calls LAND rather than as batches start,
                    # so the bar tracks work rather than intent.
                    self._report(job_id, "learning", 40 + int(30 * done / len(jobs)))
        scanned: dict[int, list] = {
            start: [item
                    for attempt in range(self.TRAP_PASSES)
                    for item in results.get((start, attempt), [])]
            for start in batch_starts
        }

        for start in batch_starts:
            batch = sentences[start:start + self.TRAP_BATCH]
            for item in scanned[start]:
                if not isinstance(item, dict):
                    continue
                # "pattern" only from a lesson: native speech is scanned for what was misread,
                # and a frame to reuse is not that.
                # Native speech is scanned for four kinds because its goal is UNDERSTANDING: a
                # term the speaker coined, or one the learner follows but could not produce,
                # both stop them mid-listen. "pattern" stays teaching-only — a frame to reuse
                # is a production tool.
                allowed = ("shifted", "set_phrase")
                allowed += (("pattern",) if teaching else ("coined", "unsayable"))
                kind = item.get("kind")
                if kind not in allowed:
                    continue
                text = str(item.get("text") or "").strip()
                if not text:
                    continue
                passage = " ".join(segment.text for segment in batch)
                if kind == "pattern":
                    # A frame with no slot is a quoted sentence — "I'd like to check in,
                    # please." came back labelled a pattern, and a whole line teaches nothing
                    # reusable. Demoted rather than dropped: as a phrase it still has to pass
                    # the phrase-length limit, which is what decides whether it survives.
                    if not has_slot(text):
                        kind = "set_phrase"
                    # Told not to invent frames, the model still does; this is the check that
                    # holds. Verified against the batch it came from, not the whole
                    # transcript, so a frame is grounded in the passage being listened to.
                    elif not self._pattern_is_grounded(text, passage):
                        continue
                # Everything else must be present too, for the same reason and one more: an
                # ungrounded expression has no occurrence to highlight, so it is a card
                # attached to nothing.
                elif not self._is_grounded(text, passage):
                    continue
                if self._mechanically_rejected(text, kind):
                    continue
                normalised = self._dedup_key(text, kind)
                # One wording per key, chosen once and reused. Repeated passes surface the same
                # frame worded differently each time — "drop me off ___", "drop me off at ___",
                # "drop me off at the ___" — and the store merges by exact text, so all three
                # became separate cards. Rewriting the text to the first wording seen merges
                # them THERE, which keeps every occurrence rather than dropping later rows.
                text = canonical.setdefault(normalised, text)
                meaning = str(item.get("chinese") or "").strip()
                # Only teaching material needs this. Native speech is filtered by "is the
                # everyday sense wrong HERE", which a compositional phrase fails on its own;
                # a lesson has no such signal, so the parts are compared to the whole.
                #
                # Patterns are exempt. The check asks what the learner would produce for a
                # meaning, and a frame's meaning is its shape — "Could I get ___?" has no
                # translation to reach for, so the question does not apply. A pattern earns
                # its place by being a frame, which the finder already decided.
                if teaching and meaning and kind != "pattern":
                    # Verified in one concurrent pass after this loop, not here. This is 93% of
                    # the stage's calls — two per unique candidate — so leaving it sequential
                    # would have made parallelising the finder almost pointless.
                    needs_verifying[normalised] = (text, meaning)
                try:
                    position = int(item.get("sentence_position", 0)) + start
                except (TypeError, ValueError):
                    # A hint only — the store locates by searching for the text.
                    position = start
                found.append({
                    "text": text,
                    # iOS already decodes "pattern" in both LearningExpressionKind and
                    # LearningExpressionType, where explainsComprehension is false — its own
                    # comment calls that group "what to put in the learner's own mouth".
                    # The two new native kinds map onto types the store and iOS already know,
                    # and both sit in `explainsComprehension: true` — which is exactly what
                    # they are for. A coined metaphor is a "reference": understanding it means
                    # understanding what the speaker built it out of. An unsayable word is
                    # ordinary vocabulary used at speed, which is what "idiom" covers here.
                    "type": {
                        "pattern": "pattern",
                        "coined": "reference",
                        "unsayable": "idiom",
                    }.get(kind, "phrase"),
                    # Cut at this episode's argument if the model folded it in — it belongs to
                    # 这集里, which already has it.
                    "chinese": self._general_definition(item.get("chinese"))
                                or item.get("chinese"),
                    # ONE sentence, cleaned. The model's own `example` was often a paragraph
                    # carrying speaker markers and stutters — ">> he did respond to me. I mean,
                    # I I want to center myself..." — which shows the learner nothing about the
                    # expression's shape. Falls back to the model's text if extraction finds
                    # nothing, since an example is the one section a card cannot do without.
                    # No `or` fallback to the model's raw text. _source_line returning empty
                    # means it could not find a sentence containing the expression, and the
                    # fallback then stored the whole paragraph — 4699 characters on one real
                    # card, after I had already "fixed" the 1590-character version. Fourth time
                    # this session a tolerant fallback reinstated exactly what it was guarding
                    # against.
                    "example": self._example_line(text, item.get("example")),
                    "example_chinese": item.get("example_chinese") or "",
                    # Five fields, down from ten. Each answers a question the learner has:
                    # what it means, how it is used generally, what it means HERE, and what it
                    # actually looked like.
                    #
                    # `restored` now carries 这集里 — the meaning specific to this episode,
                    # which is the point of listening to it. Previously it held a verbatim
                    # "sense group" that averaged 111 characters and ran to 1590, duplicating
                    # the example field.
                    #
                    # `when_to_use` is filled by the enrichment pass below, not by the finder,
                    # which cannot see outside this transcript.
                    #
                    # `heard_as` (容易理解成) is gone: a correct gloss already shows up the
                    # literal misreading, since misreading it is why the learner stopped.
                    # NO fallback to sense_group. The model ignored `context_meaning` on a real
                    # run and every one of 196 cards silently fell back to raw English
                    # transcript — the field looked populated and taught nothing. An absent
                    # section is honest; a section holding the wrong thing is not.
                    "restored": chinese_prose(item.get("context_meaning")),
                    "sentence_position": position,
                    # "auto" and not a third word: it is the column, schema and iOS default,
                    # and only "manual" is ever treated specially.
                    "source": "auto",
                    # Kept so the verification pass below can drop this row. Removed before
                    # returning — the store rejects keys it does not know.
                    "_key": normalised,
                })

        # Mis-transcriptions, in ONE call for everything found. The "coined" kind legitimises
        # exactly what a garbled word looks like, so "palunteer" (Palantir) and "onrem"
        # (on-prem) became cards on a real run.
        #
        # The single call is a deliberate choice, not laziness — do not "optimise" it into
        # smaller batches. Measured on 177 real cards: one call flags 4 items, batches of 30
        # flag 9. The extra 5 include real mis-transcriptions ("RF farming", "ramp data") AND
        # three of the episode's best cards ("buttered slippery slide", "long tale of buyers",
        # "zoom out his policy").
        #
        # The two categories are not separable by shape: "ramp data" and "magic box" look
        # identical to a model, and asking about them together it kept all 7 real coinages while
        # missing 5 garbled words. So the error is chosen rather than eliminated — a surviving
        # "monopsiny" costs one puzzling card, while a deleted coinage costs the thing the
        # native scan exists to find.
        if found:
            try:
                garbled = self.ai.garbled(sorted({item["text"] for item in found}))
            except AttributeError:
                raise
            except Exception:
                # Unchecked, not condemned: the finder had a reason to report these.
                garbled = set()
            if garbled:
                found = [item for item in found
                         if not self._contains_garbled(item["text"], garbled)]

        # Verification, all at once. Each candidate costs two model calls, and unique
        # candidates outnumber finder calls several times over, so this is where the stage's
        # time actually went.
        if needs_verifying:
            workers = max(1, min(self.settings.scan_concurrency, len(needs_verifying)))
            with ThreadPoolExecutor(max_workers=workers) as executor:
                futures = {
                    executor.submit(self._verify_producible, text, meaning): key
                    for key, (text, meaning) in needs_verifying.items()
                }
                done = 0
                for future in as_completed(futures):
                    verdicts[futures[future]] = future.result()
                    done += 1
                    # 70..99. Never 100 from here: the store still has to write everything, and
                    # a bar that reads 100% while work continues is the complaint this fixes.
                    self._report(job_id, "learning",
                                 70 + int(29 * done / len(needs_verifying)))

        # How each expression is used OUTSIDE this episode, in one batched call. This is the
        # section that lets a card teach something reusable: seeing "regulatory capture" once in
        # an AI argument does not tell you it belongs to policy criticism generally.
        #
        # A separate call by necessity, not convenience — the finder is bound to this transcript
        # (`_is_grounded` rejects anything absent from it) and general usage must come from
        # outside it. One call cannot be asked for both.
        if found:
            # Batched at USAGE_BATCH, and the size matters: asked about all 140 expressions of
            # one episode in a single call the model answered 18 of them, and asked in batches
            # of 20 it answered 79. Same model, same expressions, 4x the coverage — a long list
            # gets skimmed. Concurrent, since the batches are independent.
            unique = sorted({item["text"] for item in found})
            usages: dict[str, str] = {}
            groups = [unique[i:i + self.USAGE_BATCH]
                      for i in range(0, len(unique), self.USAGE_BATCH)]
            workers = max(1, min(self.settings.scan_concurrency, len(groups)))
            with ThreadPoolExecutor(max_workers=workers) as executor:
                for result in executor.map(self._usage_batch, groups):
                    usages.update(result)

            # A second pass over whatever the first one skipped, in much smaller groups.
            #
            # The misses are not errors: the log recorded zero failed batches while
            # pearl-clutching, pump, seeded and rage baiting all came back empty — and every one
            # of them answers in full when asked in a group of five. A long list simply gets
            # skimmed, and the omissions are silent, which makes them indistinguishable from "this
            # expression has no general usage".
            #
            # Expressions that genuinely have none (thinking tokens, safety stack) decline again
            # here, which costs a little and stays correct.
            missed = [text for text in unique if text not in usages]
            if missed:
                retry_groups = [missed[i:i + self.USAGE_RETRY_BATCH]
                                for i in range(0, len(missed), self.USAGE_RETRY_BATCH)]
                workers = max(1, min(self.settings.scan_concurrency, len(retry_groups)))
                with ThreadPoolExecutor(max_workers=workers) as executor:
                    for result in executor.map(self._usage_batch, retry_groups):
                        usages.update(result)
                print(
                    f"general-usage: {len(unique) - len(missed)}/{len(unique)} on the first pass, "
                    f"{len(usages)}/{len(unique)} after retrying {len(missed)} in "
                    f"{len(retry_groups)} small groups",
                    flush=True,
                )
            for item in found:
                # Checked HERE as well as inside the adapter's parsing. The adapter's check only
                # covers its own JSON handling, so any other supplier of usages — including a
                # test fake — reached the card unchecked, and an English register note did. The
                # guard belongs where the value is consumed, not only where it is parsed.
                #
                # The first line is the register note; the English example below it is expected,
                # so only that line is language-checked.
                usage = usages.get(item["text"])
                if not usage:
                    continue
                register, _, rest = usage.partition("\n")
                if not chinese_prose(register):
                    # The note is unusable, but an English example still teaches something, so
                    # it survives on its own when there is one.
                    usage = rest.strip()
                if usage:
                    item["when_to_use"] = usage

        # `_key` is dropped here whether or not it was verified, so a row can never reach the
        # store carrying it.
        return [
            {k: v for k, v in item.items() if k != "_key"}
            for item in found
            if not verdicts.get(item["_key"], False)
        ]

    def _usage_batch(self, texts: list[str]) -> dict[str, str]:
        """One general-usage call. Runs on a worker thread, so it touches no shared state.

        Retries once. A batch that fails returns {} for all 20 of its expressions, which is
        indistinguishable from "none of these has a general usage" — 52 cards were missing this
        section and the log said nothing at all, so I could not tell a dropped batch from an
        honest answer. Now the failure is logged and retried.
        """
        for attempt in (1, 2):
            try:
                return self.ai.generic_usage(texts)
            except AttributeError:
                raise
            except Exception as exc:
                # stdout, which is where the worker's log goes — this backend uses no logging
                # module. Flushed so a crash later in the run cannot lose the line.
                print(
                    f"general-usage batch of {len(texts)} failed "
                    f"(attempt {attempt}/2): {exc!r}",
                    flush=True,
                )
        return {}

    def _verify_producible(self, text: str, meaning: str) -> bool:
        """Whether the learner would already say this. Runs on a worker thread.

        Unverified is not rejected: the finder had a reason to report it, and a failed check is
        not evidence against it.
        """
        try:
            return self.ai.is_compositional(text, meaning)
        except Exception:
            return False

    def _chapters(self, sentences: list[TranscriptSegment]) -> list[dict]:
        try:
            chapters = self.ai.chapters(sentences)
            if chapters:
                return chapters
        except Exception:
            pass
        return self._fallback_chapters(sentences)

    @staticmethod
    def _fallback_chapters(sentences: list[TranscriptSegment]) -> list[dict]:
        if not sentences:
            return []
        window_ms = 600_000
        chapters: list[dict] = []
        start_ms = sentences[0].start_ms
        last_end = sentences[-1].end_ms
        current = start_ms
        index = 1
        while current < last_end:
            end_ms = min(current + window_ms, last_end)
            chapters.append({
                "title": f"Part {index}",
                "summary": "Auto-generated section.",
                "start_ms": current,
                "end_ms": end_ms,
            })
            current = end_ms
            index += 1
        return chapters
