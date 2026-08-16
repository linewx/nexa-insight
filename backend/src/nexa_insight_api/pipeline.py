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

from .repositories import Repository
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
            if detail:
                raise RuntimeError(f"yt-dlp failed: {detail[-1000:]}") from exc
            raise RuntimeError("yt-dlp failed while reading this YouTube URL") from exc

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
    # Two kinds only, and the narrowing IS the design. A scan over all six padded every
    # batch — six items whatever the instructions said, a product name filed as a lesson —
    # because a model given a list of categories fills them. These two are the ones a
    # learner cannot ask about: every word is known, the sentence parses, the reading is
    # wrong, and nothing signals it. New vocabulary is deliberately excluded — they will
    # look a word up themselves, and whether they already know it is the one judgement only
    # they can make.
    HIDDEN_TRAPS = (
        "You are scanning a transcript for a Chinese-speaking learner. Find ONLY the two "
        "failures a learner cannot ask about, because nothing tells them they got it wrong:\n"
        '- "shifted": the everyday sense of the words is easy AND WRONG HERE — context gives '
        'another sense ("model weights" is not heaviness; "play the clip" is not a game). '
        "Every word known, the sentence parses, the reading wrong.\n"
        '- "set_phrase": every word familiar but the combination means something the words do '
        'not ("throw shade"). The learner reads straight past it, confident and wrong.\n'
        "Return NOTHING else. Not new vocabulary — they will look that up, and only they know "
        "what they already know. Not discourse markers, not grammar, not implications.\n"
        "Skip any expression that looks like a TRANSCRIPTION ERROR rather than English "
        '("onrem" for "on-prem"): a garbled word teaches nothing and a learner would never '
        "ask about it.\n"
        "For each item return: text (exactly as it appears), kind, sense_group (verbatim from "
        "the transcript), chinese (its meaning here), usage (in Chinese, one short sentence "
        "naming the frame), literal (in Chinese, the everyday reading they would land on — "
        'required for "shifted"), example (verbatim), example_chinese (the example translated '
        "into Chinese), sentence_position.\n"
        "There is no quota and no minimum. Most passages contain none of these two, and an "
        'empty list is the expected answer. Return JSON with key "expressions".'
    )

    def hidden_traps(self, sentences: list[TranscriptSegment]) -> list[dict]:
        payload = [{"position": i, "text": s.text} for i, s in enumerate(sentences)]
        result = self._json(self.HIDDEN_TRAPS, {"sentences": payload})
        if isinstance(result, list):
            return list(result)
        # A bare array despite the schema has been observed; accepting both shapes is the
        # difference between dropping a whole batch and keeping it.
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
            self.repo.upsert_job(job_id, stage="transcription", progress=30)
            source_captions, _ = self.media.captions(episode.source_url, root / "captions")
            all_segments = source_captions
            if not all_segments:
                parts = self.media.split_audio(audio, root / "chunks")
                self.repo.upsert_job(job_id, stage="transcription", progress=30)
                completed = self.repo.completed_chunks(job_id)
                for index, part in enumerate(parts):
                    if index in completed:
                        raw = json.loads(completed[index].transcript_json or "[]")
                        segments = [TranscriptSegment(**item) for item in raw]
                    else:
                        segments = self.ai.transcribe(part, index * self.CHUNK_MS)
                        self.repo.save_chunk(job_id, index, index * self.CHUNK_MS, (index + 1) * self.CHUNK_MS, str(part), json.dumps([asdict(s) for s in segments]))
                    all_segments.extend(segments)
            self.repo.upsert_job(job_id, stage="translation", progress=70)
            # Always translate each source sentence directly. Reusing YouTube's
            # zh-Hans auto-caption track (the old _align_chinese path) time-aligned
            # two INDEPENDENT caption timelines by interval overlap, which both
            # duplicated Chinese (adjacent source sentences overlap, so one zh
            # fragment landed in several) and drifted (the two tracks' offsets
            # diverge over the episode). AI per-sentence translation is 1:1 by
            # construction — no duplication, no drift.
            translations = self._translate(all_segments, root / "translations", job_id)
            self.repo.upsert_job(job_id, stage="indexing", progress=88)
            chapters = self._chapters(all_segments)
            self.repo.upsert_job(job_id, stage="learning", progress=94)
            material_kind = self._material_kind(all_segments)
            self.repo.set_material_kind(episode.id, material_kind)
            # No batch extraction. Cards exist because the learner ASKED for one, so
            # pre-picking a few hundred expressions per episode spent the slowest and
            # most expensive stage of the pipeline building a shelf nobody opened — and,
            # since transcript highlights are drawn from those same rows, marking up the
            # text with words nobody chose.
            #
            # material_kind above is still detected and stored: it selects which prompt
            # the ON-DEMAND extraction uses when a card is actually requested.
            # Scanned, but only for the two failures a learner cannot ask about. The
            # earlier full extraction was removed because it pre-picked hundreds of words
            # nobody chose; this returns nothing for most batches, which is the point.
            traps = self._hidden_traps(all_segments, job_id)
            sentences = [{"start_ms": s.start_ms, "end_ms": s.end_ms, "speaker": s.speaker, "source_text": s.text, "chinese": cn} for s, cn in zip(all_segments, translations, strict=True)]
            self.repo.replace_learning_content(episode.id, chapters, sentences, traps)
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
        self.repo.upsert_job(job_id, stage="translation", progress=70 + int(19 * completed / total_batches))
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
                    progress = 70 + int(19 * completed / total_batches)
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

    def _hidden_traps(self, sentences: list[TranscriptSegment], job_id: int) -> list[dict]:
        """The two invisible failure kinds, across the whole transcript.

        Never raises: a scan that fails costs the learner nothing they had before, while a
        raised exception would cost the import. Same reasoning as `_material_kind`.
        """
        found: list[dict] = []
        for start in range(0, len(sentences), self.TRAP_BATCH):
            batch = sentences[start:start + self.TRAP_BATCH]
            try:
                items = self.ai.hidden_traps(batch)
            except Exception:
                continue
            for item in items:
                if not isinstance(item, dict):
                    continue
                # Only the two kinds. A model handed a category list fills it, so anything
                # else it decided to include is dropped rather than trusted.
                kind = item.get("kind")
                if kind not in ("shifted", "set_phrase"):
                    continue
                text = str(item.get("text") or "").strip()
                if not text:
                    continue
                # The scan's field names are not the store's. The card reads 整块 from
                # `restored`, 容易理解成 from `heard_as`, 怎么用 from `when_to_use` — mapping
                # here is the difference between a full card and three empty sections.
                try:
                    position = int(item.get("sentence_position", 0)) + start
                except (TypeError, ValueError):
                    # Position is a hint only: the store locates by searching for the text,
                    # so an unusable index costs the highlight nothing.
                    position = start
                found.append({
                    "text": text,
                    "type": "phrase",
                    "chinese": item.get("chinese"),
                    "example": item.get("example"),
                    # NOT NULL in the schema, and a quote a learner cannot read is no
                    # example at all — so it is asked for rather than defaulted to blank.
                    "example_chinese": item.get("example_chinese") or "",
                    "restored": item.get("sense_group"),
                    "when_to_use": item.get("usage"),
                    "heard_as": item.get("literal"),
                    "sentence_position": position,
                    # Marked as extraction so a reprocess may replace it, and so the purge
                    # that cleared the last generation still applies to this one.
                    "source": "extraction",
                })
        return found

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
