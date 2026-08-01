from __future__ import annotations

import json
import re
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


class YtDlpMediaAdapter:
    def metadata(self, url: str) -> MediaMetadata:
        result = subprocess.run(["yt-dlp", "--dump-single-json", "--skip-download", url], check=True, capture_output=True, text=True)
        data = json.loads(result.stdout)
        stream_url, expires_at = self._best_stream(data)
        return MediaMetadata(data["id"], data.get("title", "Untitled"), data.get("channel", "Unknown"), int(data.get("duration", 0) * 1000), data.get("thumbnail"), stream_url, expires_at)

    def stream(self, url: str) -> tuple[str | None, datetime | None]:
        result = subprocess.run(["yt-dlp", "--dump-single-json", "--skip-download", url], check=True, capture_output=True, text=True)
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
        subprocess.run(["yt-dlp", "-x", "--audio-format", "mp3", "-o", template, url], check=True)
        generated = destination.with_suffix(".mp3")
        # Re-encode to CONSTANT bitrate. yt-dlp yields a VBR MP3, and iOS AVPlayer
        # estimates the current time from byte-offset ÷ average bitrate — which
        # drifts mid-file on VBR (observed ~23s off near the end), desyncing audio
        # from subtitles. CBR makes byte↔time linear so the clock stays accurate.
        cbr = generated.with_name("source_cbr.mp3")
        subprocess.run(
            ["ffmpeg", "-y", "-i", str(generated), "-c:a", "libmp3lame",
             "-b:a", "128k", "-vn", str(cbr)],
            check=True, capture_output=True,
        )
        cbr.replace(destination)
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
                ["ffprobe", "-v", "error", "-select_streams", "a:0",
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
        command = [
            "yt-dlp", "--skip-download", "--write-subs", "--write-auto-subs",
            "--sub-langs", "en-orig,en", "--sub-format", "json3",
            "--js-runtimes", "node", "-o", template, url,
        ]
        subprocess.run(command, check=False, capture_output=True, text=True)
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
        subprocess.run(["ffmpeg", "-y", "-i", str(audio), "-f", "segment", "-segment_time", "900", "-c", "copy", str(output_dir / "%03d.mp3")], check=True, capture_output=True)
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
            self.repo.upsert_job(job_id, stage="indexing", progress=90)
            chapters = self._chapters(all_segments)
            sentences = [{"start_ms": s.start_ms, "end_ms": s.end_ms, "speaker": s.speaker, "source_text": s.text, "chinese": cn} for s, cn in zip(all_segments, translations, strict=True)]
            self.repo.replace_learning_content(episode.id, chapters, sentences)
            self.repo.upsert_job(job_id, stage="complete", progress=100, status="complete")
        except Exception as exc:
            self.repo.upsert_job(job_id, stage=self.repo.get_job(job_id).stage, progress=self.repo.get_job(job_id).progress, status="failed", error=str(exc))
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
            if isinstance(batch, list) and len(batch) == len(texts):
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

    def _translate_exact(self, texts: list[str]) -> list[str]:
        try:
            batch = self.ai.translate(texts)
            if len(batch) == len(texts):
                return batch
        except Exception:
            if len(texts) == 1:
                return [texts[0]]
        if len(texts) == 1:
            raise ValueError("Translation API did not return exactly one item for one sentence")
        middle = len(texts) // 2
        return self._translate_exact(texts[:middle]) + self._translate_exact(texts[middle:])

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
