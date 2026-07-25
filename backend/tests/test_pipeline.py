import json
import threading
import time
from pathlib import Path

from nexa_insight_api.models import Episode, ImportJob
from nexa_insight_api.pipeline import ImportPipeline, MediaMetadata, TranscriptSegment
from nexa_insight_api.settings import Settings


class FakeMedia:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.downloaded_audio = False

    def metadata(self, url):
        return MediaMetadata("abcdefghijk", "Title", "Channel", 60000, "http://thumb")

    def captions(self, url, destination):
        source_text = [TranscriptSegment(0, 2000, None, "Hello world."), TranscriptSegment(2000, 4000, None, "Goodbye.")]
        return source_text, None  # no chinese captions -> triggers translation

    def download_audio(self, url, destination):
        self.downloaded_audio = True
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"ID3fake")
        return destination

    def split_audio(self, audio, output_dir):
        raise AssertionError("should not split audio when captions exist")


class FakeAI:
    def transcribe(self, path, offset_ms):
        return []

    def translate(self, texts):
        return [f"[zh]{t}" for t in texts]

    def chapters(self, sentences):
        return [{"title": "All", "summary": "whole", "start_ms": 0, "end_ms": 4000}]


class FlakyAI(FakeAI):
    def translate(self, texts):
        if len(texts) > 1:
            raise ValueError("bad json")
        return [f"[zh]{texts[0]}"]

    def chapters(self, sentences):
        raise ValueError("bad json")


class ManySegmentsMedia(FakeMedia):
    def __init__(self, tmp: Path, count: int):
        super().__init__(tmp)
        self.count = count

    def captions(self, url, destination):
        source_text = [
            TranscriptSegment(index * 1000, (index + 1) * 1000, None, f"Sentence {index}.")
            for index in range(self.count)
        ]
        return source_text, None


class SlowTrackingAI(FakeAI):
    def __init__(self):
        self.active = 0
        self.max_active = 0
        self.lock = threading.Lock()

    def translate(self, texts):
        with self.lock:
            self.active += 1
            self.max_active = max(self.max_active, self.active)
        try:
            time.sleep(0.05)
            return [f"[zh]{t}" for t in texts]
        finally:
            with self.lock:
                self.active -= 1


def _seed(repo):
    with repo.session() as session:
        episode = Episode(source_url="https://youtu.be/x", youtube_id="abcdefghijk", status="queued")
        session.add(episode)
        session.flush()
        job = ImportJob(episode_id=episode.id, status="running")
        session.add(job)
        session.commit()
        return episode.id, job.id


def _seed_audio_backfill(repo):
    with repo.session() as session:
        episode = Episode(source_url="https://youtu.be/x", youtube_id="abcdefghijk", status="queued")
        session.add(episode)
        session.flush()
        job = ImportJob(episode_id=episode.id, stage="audio_backfill", status="running")
        session.add(job)
        session.commit()
        return episode.id, job.id


def test_pipeline_produces_ready_bilingual_episode(repo, tmp_path):
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    pipeline = ImportPipeline(repo, settings, FakeMedia(tmp_path), FakeAI())
    pipeline.run(job_id)
    sentences = repo.list_sentences(episode_id)
    assert [s.source_text for s in sentences] == ["Hello world.", "Goodbye."]
    assert [s.chinese for s in sentences] == ["[zh]Hello world.", "[zh]Goodbye."]
    assert repo.get_episode(episode_id).status == "ready"
    assert repo.get_episode(episode_id).audio_path == f"episodes/{episode_id}/source.mp3"
    assert repo.get_job(job_id).status == "complete"


def test_pipeline_audio_backfill_downloads_audio_without_reprocessing(repo, tmp_path):
    episode_id, job_id = _seed_audio_backfill(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    media = FakeMedia(tmp_path)
    pipeline = ImportPipeline(repo, settings, media, FakeAI())

    pipeline.run(job_id)

    assert media.downloaded_audio is True
    assert repo.get_episode(episode_id).status == "ready"
    assert repo.get_episode(episode_id).audio_path == f"episodes/{episode_id}/source.mp3"
    assert repo.list_sentences(episode_id) == []
    assert repo.get_job(job_id).status == "complete"


def test_pipeline_recovers_from_batch_translation_and_chapter_errors(repo, tmp_path):
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    pipeline = ImportPipeline(repo, settings, FakeMedia(tmp_path), FlakyAI())
    pipeline.run(job_id)
    sentences = repo.list_sentences(episode_id)
    chapters = repo.list_chapters(episode_id)
    assert [s.chinese for s in sentences] == ["[zh]Hello world.", "[zh]Goodbye."]
    assert chapters[0].title == "Part 1"
    assert repo.get_episode(episode_id).status == "ready"


def test_pipeline_translates_uncached_batches_concurrently(repo, tmp_path):
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path, translation_batch_size=2, translation_concurrency=3)
    ai = SlowTrackingAI()
    pipeline = ImportPipeline(repo, settings, ManySegmentsMedia(tmp_path, 8), ai)
    pipeline.run(job_id)
    sentences = repo.list_sentences(episode_id)
    assert len(sentences) == 8
    assert ai.max_active > 1
    assert repo.get_job(job_id).status == "complete"
