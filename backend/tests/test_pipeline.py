import json
import os
import threading
import time
from pathlib import Path
from unittest.mock import patch

import pytest

from nexa_insight_api.models import Episode, ImportJob
from nexa_insight_api.pipeline import ImportPipeline, MediaMetadata, TranscriptSegment, YtDlpMediaAdapter
from nexa_insight_api.settings import Settings


class FakeMedia:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.downloaded_audio = False
        self.caption_texts = ["Hello world.", "Goodbye."]

    def metadata(self, url):
        return MediaMetadata("abcdefghijk", "Title", "Channel", 60000, "http://thumb")

    def captions(self, url, destination):
        source_text = [
            TranscriptSegment(index * 2000, (index + 1) * 2000, None, text)
            for index, text in enumerate(self.caption_texts)
        ]
        return source_text, None  # no chinese captions -> triggers translation

    def download_audio(self, url, destination):
        self.downloaded_audio = True
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"ID3fake")
        return destination

    def is_constant_bitrate(self, audio):
        # Only what download_audio writes counts as CBR here, so a file left by
        # an earlier run is treated the way a real VBR file would be.
        return audio.read_bytes() == b"ID3fake"

    def split_audio(self, audio, output_dir):
        raise AssertionError("should not split audio when captions exist")


class FakeAI:
    def transcribe(self, path, offset_ms):
        return []

    def translate(self, texts):
        return [f"中文：{t}" for t in texts]

    def chapters(self, sentences):
        return [{"title": "All", "summary": "whole", "start_ms": 0, "end_ms": 4000}]

    def learning_expressions(self, sentences, material_kind="native"):
        return [{
            "text": "Hello world",
            "kind": "phrase",
            "chinese": "你好，世界",
            "pronunciation": None,
            "example": "Hello world, again.",
            "example_chinese": "再次向世界问好。",
            "occurrences": [{"sentence_position": 0, "start_offset": 0, "end_offset": 11}],
        }]


class FlakyAI(FakeAI):
    def translate(self, texts):
        if len(texts) > 1:
            raise ValueError("bad json")
        return [f"中文：{texts[0]}"]

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
            return [f"中文：{t}" for t in texts]
        finally:
            with self.lock:
                self.active -= 1


class ChineseTrackingAI(FakeAI):
    def __init__(self):
        self.translation_calls = 0

    def translate(self, texts):
        self.translation_calls += 1
        return [f"中文：{text}" for text in texts]


class EnglishOnlyAI(FakeAI):
    def translate(self, texts):
        return list(texts)


class BatchedExpressionAI(FakeAI):
    def __init__(self):
        self.expression_batches: list[list[TranscriptSegment]] = []
        self.batches_lock = threading.Lock()

    def learning_expressions(self, sentences, material_kind="native"):
        # Batches run concurrently, so recording them needs a lock and callers
        # must not assume the order they land in.
        with self.batches_lock:
            self.expression_batches.append(list(sentences))
        return [{
            "text": sentences[0].text,
            "kind": "phrase",
            "chinese": "测试短语",
            "pronunciation": None,
            "example": sentences[0].text,
            "example_chinese": "测试例句",
            "occurrences": [{"sentence_position": 0, "start_offset": 0, "end_offset": len(sentences[0].text)}],
        }]


class SizeLimitedExpressionAI(BatchedExpressionAI):
    def learning_expressions(self, sentences, material_kind="native"):
        if len(sentences) > 2:
            raise ValueError("response was truncated")
        return super().learning_expressions(sentences, material_kind)


class SlowExpressionAI(BatchedExpressionAI):
    def __init__(self):
        super().__init__()
        self.active = 0
        self.max_active = 0
        self.lock = threading.Lock()

    def learning_expressions(self, sentences, material_kind="native"):
        with self.lock:
            self.active += 1
            self.max_active = max(self.max_active, self.active)
        try:
            time.sleep(0.05)
            return super().learning_expressions(sentences, material_kind)
        finally:
            with self.lock:
                self.active -= 1


class StringOffsetExpressionAI(BatchedExpressionAI):
    """qwen-plus returns offsets as JSON strings, and sometimes omits them."""

    def learning_expressions(self, sentences, material_kind="native"):
        batch = super().learning_expressions(sentences, material_kind)
        batch[0]["occurrences"] = [
            {"sentence_position": "0", "start_offset": "0", "end_offset": str(len(sentences[0].text))},
            {"start_offset": 0, "end_offset": 1},
        ]
        return batch


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
    assert [s.chinese for s in sentences] == ["中文：Hello world.", "中文：Goodbye."]
    assert repo.get_episode(episode_id).status == "ready"
    assert repo.get_episode(episode_id).audio_path == f"episodes/{episode_id}/source.mp3"
    assert repo.get_job(job_id).status == "complete"
    expressions = repo.list_learning_expressions(episode_id)
    assert [(item.text, item.kind) for item in expressions] == [("Hello world", "phrase")]
    assert [(item.sentence.position, item.start_offset, item.end_offset) for item in expressions[0].occurrences] == [(0, 0, 11)]


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
    assert [s.chinese for s in sentences] == ["中文：Hello world.", "中文：Goodbye."]
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


def test_pipeline_replaces_english_translation_cache(repo, tmp_path):
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    cache = tmp_path / "episodes" / str(episode_id) / "translations"
    cache.mkdir(parents=True)
    (cache / "000.json").write_text(json.dumps(["Hello world.", "Goodbye."]))
    ai = ChineseTrackingAI()

    ImportPipeline(repo, settings, FakeMedia(tmp_path), ai).run(job_id)

    assert ai.translation_calls == 1
    assert [item.chinese for item in repo.list_sentences(episode_id)] == ["中文：Hello world.", "中文：Goodbye."]


def test_pipeline_rejects_english_translation_response(repo, tmp_path):
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)

    with pytest.raises(ValueError, match="Chinese translation"):
        ImportPipeline(repo, settings, FakeMedia(tmp_path), EnglishOnlyAI()).run(job_id)

    assert repo.get_job(job_id).status == "failed"


class UntranslatableAI(FakeAI):
    """A line with nothing to translate comes back without any Chinese."""

    def translate(self, texts):
        return ["DEP40。" if text == "DEP40." else f"中文：{text}" for text in texts]


def test_pipeline_accepts_a_translation_with_no_chinese_to_produce(repo, tmp_path):
    """A promo code translates to itself, and that must not fail the import.

    "DEP40." has no translatable content, so the model correctly echoes it. The
    CJK check treated that as a broken response and, once recursion narrowed to
    the single sentence, failed the whole episode.
    """
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    media = FakeMedia(tmp_path)
    media.caption_texts = ["DEP40.", "Goodbye."]

    ImportPipeline(repo, settings, media, UntranslatableAI()).run(job_id)

    assert repo.get_job(job_id).status == "complete"
    assert [item.chinese for item in repo.list_sentences(episode_id)] == ["DEP40。", "中文：Goodbye."]


def test_pipeline_extracts_learning_expressions_in_batches_with_global_positions(repo, tmp_path):
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path, learning_expression_batch_size=2)
    ai = BatchedExpressionAI()

    ImportPipeline(repo, settings, ManySegmentsMedia(tmp_path, 5), ai).run(job_id)

    assert sorted(len(batch) for batch in ai.expression_batches) == [1, 2, 2]
    expressions = repo.list_learning_expressions(episode_id)
    assert [item.occurrences[0].sentence.position for item in expressions] == [0, 2, 4]
    assert repo.get_job(job_id).progress == 100


def test_pipeline_retries_a_truncated_expression_batch_in_smaller_chunks(repo, tmp_path):
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path, learning_expression_batch_size=5)
    ai = SizeLimitedExpressionAI()

    ImportPipeline(repo, settings, ManySegmentsMedia(tmp_path, 5), ai).run(job_id)

    assert [len(batch) for batch in ai.expression_batches] == [2, 1, 2]
    assert [item.occurrences[0].sentence.position for item in repo.list_learning_expressions(episode_id)] == [0, 2, 3]


class MaterialAwareAI(FakeAI):
    """Records which strategy the pipeline asked for."""

    def __init__(self, material="native"):
        self.material = material
        self.asked_with = []

    def classify_material(self, sentences):
        return self.material

    def learning_expressions(self, sentences, material_kind="native"):
        self.asked_with.append(material_kind)
        return [{
            "text": sentences[0].text.split(".")[0],
            "type": "reduction" if material_kind == "native" else "phrase",
            "chinese": "测试",
            "pronunciation": None,
            "example": sentences[0].text,
            "example_chinese": "测试例句",
            "heard_as": "kinda" if material_kind == "native" else None,
            "why_hard": "弱读脱落。" if material_kind == "native" else None,
            "when_to_use": None if material_kind == "native" else "日常对话。",
            "occurrences": [{"sentence_position": 0}],
        }]


def test_pipeline_records_material_kind_and_uses_the_matching_strategy(repo, tmp_path):
    """native transcripts and English lessons need different things extracted."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ai = MaterialAwareAI(material="teaching")

    ImportPipeline(repo, settings, FakeMedia(tmp_path), ai).run(job_id)

    assert repo.get_episode(episode_id).material_kind == "teaching"
    assert set(ai.asked_with) == {"teaching"}
    stored = repo.list_learning_expressions(episode_id)[0]
    assert stored.type == "phrase"
    assert stored.when_to_use == "日常对话。"


def test_pipeline_extracts_native_material_with_the_native_strategy(repo, tmp_path):
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ai = MaterialAwareAI(material="native")

    ImportPipeline(repo, settings, FakeMedia(tmp_path), ai).run(job_id)

    assert repo.get_episode(episode_id).material_kind == "native"
    stored = repo.list_learning_expressions(episode_id)[0]
    assert stored.type == "reduction"
    assert stored.heard_as == "kinda"
    assert stored.why_hard == "弱读脱落。"


def test_pipeline_falls_back_to_native_when_classification_fails(repo, tmp_path):
    """A failed classification must not fail the import."""
    class BrokenClassifierAI(MaterialAwareAI):
        def classify_material(self, sentences):
            raise RuntimeError("model unavailable")

    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ai = BrokenClassifierAI()

    ImportPipeline(repo, settings, FakeMedia(tmp_path), ai).run(job_id)

    assert repo.get_job(job_id).status == "complete"
    assert repo.get_episode(episode_id).material_kind == "native"


class NonconformingAI(FakeAI):
    """Real qwen-plus output: IPA as a per-word list, and patterns with no slots."""

    def learning_expressions(self, sentences, material_kind="native"):
        return [
            {
                "text": "real talk",
                "type": "phrase",
                "chinese": "真心话",
                "pronunciation": ["riːl", "tɔːk"],  # a list, not a string
                "example": sentences[0].text,
                "example_chinese": "真心话。",
                "occurrences": [{"sentence_position": 0}],
            },
            {
                "text": sentences[0].text,  # a whole sentence claimed as a pattern
                "type": "pattern",
                "chinese": "整句",
                "pronunciation": None,
                "example": sentences[0].text,
                "example_chinese": "整句。",
                "occurrences": [{"sentence_position": 0}],
            },
        ]


def test_pipeline_accepts_ipa_returned_as_a_word_list(repo, tmp_path):
    """The model returns per-word IPA as a list; storing it must not crash."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)

    ImportPipeline(repo, settings, FakeMedia(tmp_path), NonconformingAI()).run(job_id)

    stored = {item.text: item for item in repo.list_learning_expressions(episode_id)}
    assert stored["real talk"].pronunciation == "riːl tɔːk"


def test_pipeline_demotes_a_pattern_without_slots(repo, tmp_path):
    """A pattern is a frame with slots; a whole sentence is just a phrase."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)

    ImportPipeline(repo, settings, FakeMedia(tmp_path), NonconformingAI()).run(job_id)

    sentence_item = next(
        item for item in repo.list_learning_expressions(episode_id) if item.text == "Hello world."
    )
    assert sentence_item.type == "phrase"


def test_pipeline_reports_a_programming_error_instead_of_silently_losing_expressions(repo, tmp_path):
    """The batch retry is for flaky model calls, not for bugs in our own code.

    A TypeError from a wrong call signature was caught by the same handler,
    recursed down to single sentences, and returned as "no expressions found" —
    a green import with a silently empty learning pack.
    """
    class BuggyAI(FakeAI):
        def learning_expressions(self, sentences, material_kind="native"):
            raise TypeError("learning_expressions() got an unexpected argument")

    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)

    with pytest.raises(TypeError):
        ImportPipeline(repo, settings, FakeMedia(tmp_path), BuggyAI()).run(job_id)

    assert repo.get_job(job_id).status == "failed"


def test_pipeline_extracts_expression_batches_concurrently(repo, tmp_path):
    """Serial batches dominated import time: 12 waves at ~42s each."""
    episode_id, job_id = _seed(repo)
    settings = Settings(
        _env_file=None,
        data_dir=tmp_path,
        learning_expression_batch_size=2,
        learning_expression_concurrency=3,
    )
    ai = SlowExpressionAI()

    ImportPipeline(repo, settings, ManySegmentsMedia(tmp_path, 8), ai).run(job_id)

    assert ai.max_active > 1
    assert repo.get_job(job_id).status == "complete"
    # Positions must stay correct even though batches finish out of order.
    assert [item.occurrences[0].sentence.position for item in repo.list_learning_expressions(episode_id)] == [0, 2, 4, 6]


def test_pipeline_remaps_string_offsets_and_skips_incomplete_occurrences(repo, tmp_path):
    """The model returns offsets as strings, which must not crash the batch remap."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path, learning_expression_batch_size=2)

    ImportPipeline(repo, settings, ManySegmentsMedia(tmp_path, 5), StringOffsetExpressionAI()).run(job_id)

    assert repo.get_job(job_id).status == "complete"
    assert [item.occurrences[0].sentence.position for item in repo.list_learning_expressions(episode_id)] == [0, 2, 4]


def test_pipeline_replaces_leftover_audio_from_an_earlier_run(repo, tmp_path):
    """A source.mp3 already on disk must not be trusted.

    The guard was `if not audio.exists()`, which only asks whether a file is
    there — never whether it is the CBR file the player needs. So an episode
    whose audio was downloaded before the VBR fix (or by a run that died
    mid-import) kept its VBR file forever: every retry skipped download_audio,
    which is where the CBR re-encode lives. Observed on a real import — 15
    distinct packet sizes at 103kbps, against the 128k CBR the pipeline emits.
    """
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    media = FakeMedia(tmp_path)

    stale = tmp_path / "episodes" / str(episode_id) / "source.mp3"
    stale.parent.mkdir(parents=True, exist_ok=True)
    stale.write_bytes(b"VBR-from-an-earlier-run")

    ImportPipeline(repo, settings, media, FakeAI()).run(job_id)

    assert media.downloaded_audio is True, "stale audio must be re-downloaded, not reused"
    assert stale.read_bytes() == b"ID3fake", "the stale bytes must be gone"


def test_media_adapter_finds_homebrew_tools_when_launchd_path_is_minimal():
    with patch.dict(os.environ, {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}):
        adapter = YtDlpMediaAdapter()

    assert adapter.yt_dlp.endswith("yt-dlp")
    assert adapter.ffmpeg.endswith("ffmpeg")
    assert adapter.ffprobe.endswith("ffprobe")


def test_media_adapter_passes_ffmpeg_location_to_yt_dlp():
    adapter = YtDlpMediaAdapter()

    command = adapter._yt_dlp_command("-x", "--audio-format", "mp3", include_ffmpeg=True)

    assert "--ffmpeg-location" in command
    assert str(Path(adapter.ffmpeg).parent) in command


def test_media_adapter_reports_missing_required_tool(tmp_path):
    with patch.dict(os.environ, {"PATH": str(tmp_path)}), patch.object(YtDlpMediaAdapter, "EXTRA_BIN_DIRS", (str(tmp_path),)):
        with pytest.raises(RuntimeError, match="yt-dlp is not installed"):
            YtDlpMediaAdapter()
