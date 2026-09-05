import json
import os
import subprocess
import threading
import time
from pathlib import Path
from unittest.mock import patch

import pytest

from nexa_insight_api.models import Episode, ImportJob
from nexa_insight_api.repositories import has_slot, is_studiable_expression
from nexa_insight_api.pipeline import (ImportPipeline, MediaMetadata, OpenAIAdapter,
                                       TranscriptSegment, YtDlpMediaAdapter, chinese_prose)
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

    def garbled(self, texts):
        # Nothing here is a mis-transcription. Real adapters ask the model; fixtures that want
        # to exercise the filter override this.
        return set()

    def generic_usage(self, texts):
        # No general-usage section by default. Fixtures that care override this; the enrichment
        # pass is best-effort, so a card without it is still a card.
        return {}

    def insight_chunk(self, lines):
        # No argument extracted by default. The 洞察 page is native-only and absent is a valid
        # outcome, so fixtures that do not care about it get no page.
        return {"claims": [], "facts": []}

    def insight_synthesis(self, claims, facts):
        return {}

    def hidden_traps(self, sentences):
        # One shifted sense in the first line of every batch, so remapping is observable.
        return [{
            "text": "Hello world",
            "kind": "shifted",
            "chinese": "\u6253\u62db\u547c",
            "context_meaning": "\u8fd9\u96c6\u91cc\u6307\u6d4b\u8bd5\u7528\u7684\u6253\u62db\u547c",
            "usage": "\u6d4b\u8bd5\u7528",
            "literal": "\u4f60\u597d\uff0c\u4e16\u754c",
            "example": "Hello world.",
            "example_chinese": "\u4f60\u597d\uff0c\u4e16\u754c\u3002",
            "sentence_position": 0,
        }]

    # A lesson is scanned with a different question, so the fake has to answer both or the
    # teaching path silently returns nothing — which the broad `except` would hide.
    def teaching_traps(self, sentences):
        return self.hidden_traps(sentences)

    def is_compositional(self, text, meaning):
        return False

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


class ProgressRecordingRepo:
    """Wraps a repo and records every progress write, in order."""

    def __init__(self, inner):
        self._inner = inner
        self.reports: list[tuple[str, int]] = []

    def upsert_job(self, job_id, *, stage, progress, status="running", error=None):
        self.reports.append((stage, progress))
        return self._inner.upsert_job(job_id, stage=stage, progress=progress,
                                      status=status, error=error)

    def __getattr__(self, name):
        return getattr(self._inner, name)


class ManyCandidatesAI(FakeAI):
    """Enough candidates that the scan has something to report progress across."""

    def classify_material(self, sentences):
        return "teaching"

    def teaching_traps(self, sentences):
        return [{"text": f"phrase {n}", "kind": "set_phrase", "chinese": f"x{n}",
                 "example": "Hello world.", "example_chinese": "y", "sentence_position": 0}
                for n in range(4)]

    def is_compositional(self, text, meaning):
        return False


def test_progress_never_goes_backwards_and_never_claims_done_early(repo, tmp_path):
    """The bar reached 88% eight seconds into a 124-second import and then crawled: the
    percentages were assigned by stage ORDER rather than by measured duration, and the scan —
    65% of the wall clock — set one value and then reported nothing for a minute. A frozen bar
    is indistinguishable from a hung import."""
    episode_id, job_id = _seed(repo)
    recording = ProgressRecordingRepo(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ImportPipeline(recording, settings, FakeMedia(tmp_path), ManyCandidatesAI()).run(job_id)

    values = [progress for _, progress in recording.reports]
    assert values, "the pipeline reports progress"
    assert values == sorted(values), f"progress must not go backwards: {values}"
    # 100 is reported exactly once, at the end — not before the store has written anything.
    assert values[-1] == 100
    assert values.count(100) == 1, "reaching 100% is what 'finished' means"

    # The scan reports repeatedly rather than once, which is the fix for the frozen bar.
    during_scan = [p for stage, p in recording.reports if stage == "learning"]
    assert len(during_scan) > 3, f"the scan must report as it works, got {during_scan}"
    assert max(during_scan) < 100, "the scan cannot claim the import is done"


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
    # Scanned again, but only for the two failures a learner cannot ask about. The card
    # fields are what matters: 整块 reads `restored`, 容易理解成 reads `heard_as`, 怎么用 reads
    # `when_to_use`, and the scan's own field names are none of those — a mapping slip
    # renders three empty sections rather than failing anything.
    assert [e.text for e in expressions] == ["Hello world"]
    found = expressions[0]
    assert found.source == "auto", "a reprocess must be free to replace it"
    # Five fields now, not ten. 这集里 lives in `restored`; 常见用法 comes from the enrichment
    # pass (absent here, since FakeAI returns none); 容易理解成 is gone entirely — a correct
    # gloss already shows up the literal misreading, which is why the learner stopped.
    # 这集里 must be Chinese prose, not a transcript quotation. A real run produced 196 of 196
    # cards holding raw English here, because the mapping fell back to the old field.
    assert found.restored == "\u8fd9\u96c6\u91cc\u6307\u6d4b\u8bd5\u7528\u7684\u6253\u62db\u547c"
    assert found.heard_as is None, "容易理解成 was removed as redundant with the gloss"
    assert found.when_to_use is None, "no generic usage unless the enrichment pass supplies it"


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


def test_an_entirely_english_response_still_fails_the_import(repo, tmp_path):
    """A few untranslated lines are bad captions; ALL of them is a broken translator.

    Now that a single line survives by keeping its source, nothing would otherwise notice a wrong
    model name or a dead endpoint — the episode would ship an English "translation" in silence. So
    the failure moved to the whole-episode level, where it can tell the two apart.
    """
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)

    with pytest.raises(ValueError, match="did not return Chinese"):
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


class MaterialAwareAI(FakeAI):
    """Records which material strategy the pipeline classified the episode as.

    It used to also stand in for batch extraction; that is gone, so what remains is the
    classification, which still matters — `material_kind` picks the prompt ON-DEMAND
    extraction uses when the learner actually asks for a card.
    """

    def __init__(self, material="native"):
        self.material = material

    def classify_material(self, sentences):
        return self.material


def test_pipeline_records_material_kind_and_uses_the_matching_strategy(repo, tmp_path):
    """native transcripts and English lessons need different things extracted."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ai = MaterialAwareAI(material="teaching")

    ImportPipeline(repo, settings, FakeMedia(tmp_path), ai).run(job_id)

    # Classification still runs and is stored: it selects the prompt the on-demand
    # teacher uses. The scan runs alongside it and is not gated on it.
    assert repo.get_episode(episode_id).material_kind == "teaching"
    assert [e.text for e in repo.list_learning_expressions(episode_id)] == ["Hello world"]


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


# The narrowing IS the design, so it is pinned here rather than left to the prompt. A scan
# over all six kinds padded every batch — six items whatever the instructions said, a
# product name filed as a lesson — because a model handed a category list fills it.
class PaddingAI(FakeAI):
    """Returns the kinds a padding model reaches for when it has nothing real to report."""

    def hidden_traps(self, sentences):
        return [
            {"text": "Hello world", "kind": "shifted", "chinese": "打招呼",
             "example": "Hello world.", "example_chinese": "你好。", "sentence_position": 0},
            # Vocabulary is deliberately out of scope: they will look a word up themselves,
            # and whether they already know it is the one judgement only they can make.
            {"text": "Goodbye", "kind": "word", "chinese": "再见",
             "example": "Goodbye.", "example_chinese": "再见。", "sentence_position": 1},
            {"text": "you know", "kind": "discourse", "chinese": "你知道的",
             "example": "Goodbye.", "example_chinese": "再见。", "sentence_position": 1},
            # No text is nothing to highlight and nothing to study.
            {"text": "   ", "kind": "set_phrase", "chinese": "空",
             "example": "Goodbye.", "example_chinese": "再见。", "sentence_position": 0},
            "not even a dict",
        ]


def test_scan_keeps_only_the_two_kinds_a_learner_cannot_ask_about(repo, tmp_path):
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ImportPipeline(repo, settings, FakeMedia(tmp_path), PaddingAI()).run(job_id)

    kept = repo.list_learning_expressions(episode_id)
    assert [e.text for e in kept] == ["Hello world"], (
        "vocabulary, discourse markers, blank text and non-dicts are all dropped"
    )


class SamplingAI(FakeAI):
    """A finder that returns something different every call, as the real one does."""

    def __init__(self):
        self.calls = 0
        # The passes run concurrently now, so `calls += 1` and reading it back is a race: two
        # threads could hand out the same number and the union would look smaller than it is.
        self.lock = threading.Lock()

    def hidden_traps(self, sentences):
        with self.lock:
            self.calls += 1
            number = self.calls
        # One item per pass, never repeating — the observed behaviour, taken to its extreme.
        return [{
            # Lifted from the passage: grounding drops anything absent from it, and a
            # fabricated "phrase 7" is exactly what that check exists to catch.
            "text": "hello" if number % 2 else "world", "kind": "set_phrase", "chinese": f"x{number}",
            "example": "Hello world.", "example_chinese": "y", "sentence_position": 0,
        }]


class SlowFirstPassAI(FakeAI):
    """Returns two wordings of one frame, with the FIRST pass deliberately slow.

    This is the shape that made concurrency racy: reassembling in completion order let the
    second pass land first, so `canonical` kept its wording and the card's text depended on
    thread scheduling.
    """

    def __init__(self):
        self.calls = 0
        self.lock = threading.Lock()

    def classify_material(self, sentences):
        return "teaching"

    def teaching_traps(self, sentences):
        with self.lock:
            self.calls += 1
            number = self.calls
        if number == 1:
            time.sleep(0.15)
            wording = "hello ___ world"
        else:
            wording = "hello world ___"
        return [{"text": wording, "kind": "pattern", "chinese": "x",
                 "example": "Hello world.", "example_chinese": "y", "sentence_position": 0}]

    def is_compositional(self, text, meaning):
        return False


class VerifyingAI(FakeAI):
    """Two candidates, one of which the learner would already say."""

    def __init__(self):
        self.verified = []
        self.lock = threading.Lock()

    def classify_material(self, sentences):
        return "teaching"

    def teaching_traps(self, sentences):
        def item(text, chinese):
            return {"text": text, "kind": "set_phrase", "chinese": chinese,
                    "example": "Hello world.", "example_chinese": "y", "sentence_position": 0}
        return [item("card on file", "已存档的卡"),
                item("free breakfast", "免费早餐")]

    def is_compositional(self, text, meaning):
        with self.lock:
            self.verified.append(text)
        return text == "free breakfast"


def test_verification_runs_once_per_candidate_and_drops_what_it_rejects(repo, tmp_path):
    """Verification is 93% of this stage's model calls — two per unique candidate — so it runs
    concurrently and deduped. Doing it inline per item would have made parallelising the finder
    almost pointless, and would re-verify the same phrase once per pass."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ai = VerifyingAI()
    # Grounded: `_is_grounded` drops an expression absent from its passage.
    media = FakeMedia(tmp_path)
    media.caption_texts = ["I keep a card on file.", "The free breakfast is included."]
    ImportPipeline(repo, settings, media, ai).run(job_id)

    stored = [e.text for e in repo.list_learning_expressions(episode_id)]
    assert stored == ["card on file"], "a phrase the learner would already say earns no card"
    # Three passes, two candidates each — but each distinct candidate is checked exactly once.
    assert sorted(ai.verified) == ["card on file", "free breakfast"]


def test_internal_dedup_key_never_reaches_the_store():
    """Rows carry `_key` between the collect and verify phases. The store rejects columns it
    does not know, so leaking it would fail the whole import rather than one card."""
    class AI(FakeAI):
        def classify_material(self, sentences):
            return "teaching"

        def teaching_traps(self, sentences):
            # From the passage below, since grounding drops anything absent from it.
            return [{"text": "Hello world", "kind": "set_phrase", "chinese": "x",
                     "example": "Hello world.", "example_chinese": "y", "sentence_position": 0}]

        def is_compositional(self, text, meaning):
            return False

    pipeline = ImportPipeline.__new__(ImportPipeline)
    pipeline.ai = AI()
    pipeline.settings = Settings(_env_file=None)
    rows = pipeline._hidden_traps([TranscriptSegment(0, 900, None, "Hello world.")], "teaching")

    assert rows, "the candidate survives"
    assert not [key for row in rows for key in row if key.startswith("_")]


def test_concurrent_passes_still_produce_the_same_card(repo, tmp_path):
    """Order comes from (batch, pass), never from which call returned first.

    Running passes concurrently made the output depend on thread scheduling: one frame arrives
    worded differently on different passes, `canonical` keeps whichever it sees first, and the
    text on the card changed between identical reprocesses. The test for it failed about half
    the time before the fix.
    """
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ImportPipeline(repo, settings, FakeMedia(tmp_path), SlowFirstPassAI()).run(job_id)

    stored = [e.text for e in repo.list_learning_expressions(episode_id)]
    assert stored == ["hello ___ world"], "the first pass's wording wins, however late it lands"


def test_each_batch_is_scanned_several_times_and_the_union_kept():
    """One pass samples a batch rather than enumerating it: five runs of the same 40 lines
    returned 16 distinct items with ZERO overlap. A single pass therefore drops most of what
    is there, which is why an expression can go missing with nothing rejecting it."""
    ai = SamplingAI()
    pipeline = ImportPipeline.__new__(ImportPipeline)
    pipeline.ai = ai
    # The passes run on a thread pool now, so the concurrency setting has to be present. Reached
    # through __new__ rather than a full constructor because this test needs neither a repo nor
    # media, and `settings` is the one field _hidden_traps actually reads.
    pipeline.settings = Settings(_env_file=None)
    found = pipeline._hidden_traps([TranscriptSegment(0, 900, None, "Hello world.")], "native")

    assert ai.calls == ImportPipeline.TRAP_PASSES
    # Sorted: the passes complete in whatever order the pool returns them, and which pass
    # produced which item is not a thing this test should pin.
    # Every pass contributes, and the union is kept rather than the last result. The fixture
    # alternates between two words of the passage, so three passes yield both.
    assert sorted({f["text"] for f in found}) == ["hello", "world"]


class BatchPositionAI(FakeAI):
    """Reports a position relative to ITS batch, which is all the model can see."""

    def __init__(self):
        self.batches = []

    def hidden_traps(self, sentences):
        self.batches.append([s.text for s in sentences])
        # The repeated phrase, reported at its position WITHIN this batch.
        for offset, segment in enumerate(sentences):
            if "throw shade" in segment.text:
                return [{"text": "throw shade", "kind": "set_phrase", "chinese": "\u6697\u4e2d\u8d2c\u4f4e",
                         "example": segment.text, "example_chinese": "\u6d4b\u8bd5\u3002",
                         "sentence_position": offset}]
        return []


def test_scan_shifts_batch_positions_into_transcript_numbering(repo, tmp_path):
    """The store searches every sentence for the text, so a position is only the first place
    it looks — which makes the shift invisible until the SAME phrase appears twice. Then the
    reported index decides which occurrence gets highlighted, and an unshifted one anchors
    the card to a sentence in the wrong batch."""
    episode_id, job_id = _seed(repo)
    ai = BatchPositionAI()
    media = FakeMedia(tmp_path)
    lines = [f"line {i}." for i in range(ImportPipeline.TRAP_BATCH + 5)]
    lines[1] = "I heard them throw shade early on."
    target = ImportPipeline.TRAP_BATCH + 2
    lines[target] = "They throw shade again much later."
    media.caption_texts = lines
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ImportPipeline(repo, settings, media, ai).run(job_id)

    # Distinct batches, not call count: each batch is scanned TRAP_PASSES times because one
    # pass samples rather than enumerates, so the call total is batches × passes.
    assert len({tuple(b) for b in ai.batches}) == 2, "the transcript is scanned in batches"
    assert len(ai.batches) == 2 * ImportPipeline.TRAP_PASSES
    sentences = {s.id: s.position for s in repo.list_sentences(episode_id)}
    expressions = repo.list_learning_expressions(episode_id)
    assert [e.text for e in expressions] == ["throw shade"]
    # Reported as position 2 inside the SECOND batch, so only a shifted position lands on
    # the later line. Unshifted it anchors to line 2, which does not contain the phrase.
    anchored = sorted(sentences[o.sentence_id] for o in expressions[0].occurrences)
    assert anchored == [1, target]


# The teaching path asks a different question, and routing to the wrong one is silent: a
# lesson scanned with "would they misread it HERE" returns nothing, because the speaker just
# explained it. Measured at 0 items on a hotel vlog that plainly contains "card on file".
class RoutingAI(FakeAI):
    def __init__(self, kind):
        self.kind = kind
        self.asked = []

    def classify_material(self, sentences):
        return self.kind

    def hidden_traps(self, sentences):
        self.asked.append("native")
        return []

    def teaching_traps(self, sentences):
        self.asked.append("teaching")
        return []

    def is_compositional(self, text, meaning):
        return False


def test_a_lesson_is_scanned_with_the_teaching_question(repo, tmp_path):
    episode_id, job_id = _seed(repo)
    ai = RoutingAI("teaching")
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ImportPipeline(repo, settings, FakeMedia(tmp_path), ai).run(job_id)
    assert set(ai.asked) == {"teaching"}


class NativeKindsAI(FakeAI):
    """The four kinds a native scan may return, plus one the model invented."""

    def classify_material(self, sentences):
        return "native"

    def hidden_traps(self, sentences):
        def item(text, kind):
            return {"text": text, "kind": kind, "chinese": "x",
                    "example": "Hello world.", "example_chinese": "y", "sentence_position": 0}
        return [
            # Lowercase: a single capitalised word is rejected as a name, which is what stops
            # "Palanteer" and "Neotron" becoming cards.
            item("hello", "shifted"),
            item("world", "set_phrase"),
            item("goodbye", "coined"),      # a term the speaker made up for this discussion
            item("hello world", "unsayable"),  # followed but not producible
            # A pattern is a production tool, so native material must not yield one.
            item("hello ___", "pattern"),
            # Absent from the passage: the model echoing a prompt example back as a finding.
            item("blindsided", "unsayable"),
        ]


def test_native_speech_yields_coined_and_unsayable_but_not_patterns(repo, tmp_path):
    """Native material is scanned for UNDERSTANDING, so a term the speaker coined and a word the
    learner follows but could not produce both count — 720 sentences previously gave 2 cards.
    Filtering coinages out as "unportable" would be a production argument, and production is the
    teaching path's job; here, not knowing one means not following the sentence."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ImportPipeline(repo, settings, FakeMedia(tmp_path), NativeKindsAI()).run(job_id)

    stored = {e.text: e.type for e in repo.list_learning_expressions(episode_id)}
    assert set(stored) == {"hello", "world", "goodbye", "hello world"}, (
        "coined and unsayable are kept; a pattern is teaching-only; an absent expression is "
        "dropped"
    )
    # Both map onto types iOS already treats as comprehension aids.
    assert stored["goodbye"] == "reference"
    assert stored["hello world"] == "idiom"


def test_a_single_capitalised_word_is_a_name():
    """The proper-noun rule only looked from the SECOND word on, so a lone capitalised word
    passed — and "Palanteer" (Palantir), "Neotron" (Nvidia) and "ROCE" all became cards on a
    real native run. The transcript is machine-punctuated, so a mid-sentence capital is a name."""
    rejected = ImportPipeline._mechanically_rejected
    assert rejected("Palanteer") == "proper noun"
    assert rejected("Neotron") == "proper noun"
    assert rejected("ROCE") == "proper noun"
    # Real expressions are lowercase in a transcript and must survive.
    for text in ["blindsided", "hoover up", "codified", "alpha", "rocket docket",
                 "intelligence sovereignty"]:
        assert rejected(text) is None, text


class GarbledAI(FakeAI):
    """One mis-transcription among real expressions."""

    def __init__(self):
        self.asked: list[list[str]] = []

    def classify_material(self, sentences):
        return "native"

    def hidden_traps(self, sentences):
        def item(text, kind):
            return {"text": text, "kind": kind, "chinese": "x",
                    "example": "Hello world.", "example_chinese": "y", "sentence_position": 0}
        return [item("world", "set_phrase"), item("hello", "coined")]

    def garbled(self, texts):
        self.asked.append(sorted(texts))
        return {"hello"}


def test_a_mis_transcription_is_not_a_card(repo, tmp_path):
    """The "coined" kind legitimises exactly what a garbled word looks like — a made-up-sounding
    term — so "palunteer" (Palantir), "onrem" (on-prem) and "obiated" became cards on a real
    run. Asked in ONE batched call, since this is a spelling question rather than a judgement.

    A dictionary was the obvious tool and the wrong one: /usr/share/dict/words rejects
    "blindsided", "codified" and "clunky" while accepting "alpha"."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ai = GarbledAI()
    ImportPipeline(repo, settings, FakeMedia(tmp_path), ai).run(job_id)

    stored = {e.text for e in repo.list_learning_expressions(episode_id)}
    assert stored == {"world"}, "the mis-transcription is dropped, the real expression kept"
    # ONE call, deliberately. Measured on 177 real cards: one call flags 4 items, batches of 30
    # flag 9 — and the extra 5 include three of the episode's best coinages ("buttered slippery
    # slide", "long tale of buyers", "zoom out his policy") alongside real garbled words. The
    # two categories are not separable by shape, so the error is chosen: a surviving
    # "monopsiny" costs one puzzling card, a deleted coinage costs what the scan exists to find.
    assert ai.asked == [["hello", "world"]], "one call for everything found, not one per item"


def test_a_phrase_built_on_a_garbled_word_is_dropped():
    """The model answers with the garbled WORD, not the phrase it was handed: asked about
    "monopsiny buyer situation" it returns "monopsiny". An exact-match filter therefore removed
    nothing and that card survived a real run. A phrase built on a mis-transcribed word is just
    as unusable as the word alone."""
    contains = ImportPipeline._contains_garbled
    flagged = {"monopsiny", "moratorum"}
    assert contains("monopsiny buyer situation", flagged)
    assert contains("moratorum", flagged)
    assert contains("Monopsiny Buyer Situation", flagged), "case is normalised"
    # Real expressions are untouched, including ones that merely share a common word.
    assert not contains("cost of capital", flagged)
    assert not contains("long tale of buyers", flagged)
    assert not contains("buyer situation", flagged), "only the garbled word condemns a phrase"
    assert not contains("anything", set()), "nothing flagged means nothing dropped"


def test_an_expression_absent_from_the_passage_is_dropped():
    """Naming examples in a prompt gets them returned verbatim: a draft of HIDDEN_TRAPS
    mentioned "blindsided", "clunky" and "job displacement", and a batch containing none of the
    three reported all three. The instruction alone did not hold, so this is checked in code —
    and an ungrounded expression has no occurrence to highlight anyway."""
    grounded = ImportPipeline._is_grounded
    passage = "We were caught off guard by the new tariffs."
    assert grounded("caught off guard", passage)
    assert grounded("Caught Off Guard", passage), "case and spacing are normalised"
    assert not grounded("blindsided", passage)
    assert not grounded("", passage)


def test_native_speech_is_scanned_with_the_misreading_question(repo, tmp_path):
    episode_id, job_id = _seed(repo)
    ai = RoutingAI("native")
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ImportPipeline(repo, settings, FakeMedia(tmp_path), ai).run(job_id)
    assert set(ai.asked) == {"native"}


class CompositionalAI(FakeAI):
    """Reports one phrase whose parts add up and one whose parts do not."""

    def __init__(self):
        self.checked = []

    def classify_material(self, sentences):
        return "teaching"

    def teaching_traps(self, sentences):
        return [
            {"text": "mini bar", "kind": "set_phrase", "chinese": "\u8ff7\u4f60\u5427",
             "example": "Hello world.", "example_chinese": "x", "sentence_position": 0},
            {"text": "card on file", "kind": "set_phrase", "chinese": "\u5df2\u5b58\u6863\u7684\u5361",
             "example": "Hello world.", "example_chinese": "x", "sentence_position": 0},
        ]

    def is_compositional(self, text, meaning):
        self.checked.append(text)
        # "mini" + "bar" assembles to the right meaning; "card on file" does not.
        return text == "mini bar"


def test_teaching_drops_expressions_whose_parts_add_up(repo, tmp_path):
    """A lesson has no "wrong here" signal, so the filter is whether the words, glossed
    separately, already give the meaning. Without it the scan keeps hotel jargon a learner
    assembles correctly on first meeting."""
    episode_id, job_id = _seed(repo)
    ai = CompositionalAI()
    settings = Settings(_env_file=None, data_dir=tmp_path)
    # Grounded: `_is_grounded` drops an expression absent from its passage.
    media = FakeMedia(tmp_path)
    media.caption_texts = ["The mini bar and the card on file."]
    ImportPipeline(repo, settings, media, ai).run(job_id)

    assert [e.text for e in repo.list_learning_expressions(episode_id)] == ["card on file"]
    assert ai.checked == ["mini bar", "card on file"], "each candidate is checked once"


class ShapesAI(FakeAI):
    """Everything here was a real result from a real transcript."""

    def classify_material(self, sentences):
        return "teaching"

    def teaching_traps(self, sentences):
        def item(text):
            return {"text": text, "kind": "set_phrase", "chinese": "x",
                    "example": "Hello world.", "example_chinese": "y", "sentence_position": 0}
        return [item(t) for t in [
            "P level",                      # a parking sign
            "M Club",                       # a hotel lounge brand
            "Stay close to me",             # a line of dialogue, not a phrase
            "I want to see where you go",   # a whole sentence
            "go through",                   # keep: particle verb, parts mislead
            "drop off",                     # keep: same shape
        ]]

    def is_compositional(self, text, meaning):
        return False


def test_labels_names_and_whole_sentences_are_rejected_without_a_model_call(repo, tmp_path):
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    # Grounded: `_is_grounded` drops an expression absent from its passage.
    media = FakeMedia(tmp_path)
    media.caption_texts = ["Go through the P level and the M Club.", "Stay close to me, I want to see where you go, drop off here."]
    ImportPipeline(repo, settings, media, ShapesAI()).run(job_id)

    kept = {e.text for e in repo.list_learning_expressions(episode_id)}
    assert kept == {"go through", "drop off"}, (
        "an imperative ending in a particle must survive; a bare imperative must not"
    )


class PatternAI(FakeAI):
    """Patterns are the one kind the model invents, so both cases are here."""

    def classify_material(self, sentences):
        return "teaching"

    def teaching_traps(self, sentences):
        def item(text, kind="pattern"):
            return {"text": text, "kind": kind, "chinese": "x",
                    "example": "Hello world.", "example_chinese": "y", "sentence_position": 0}
        return [
            # Grounded in FakeMedia's transcript ("Hello world." / "Goodbye."), and with two
            # content words so the weak-frame rule keeps it.
            item("Hello ___ world"),
            # Invented: generic English for the topic, in a transcript that never said it.
            item("Could I get ___?"),
            # A frame whose second half was invented must go too — checking only the longest
            # run would pass this.
            item("Hello ___ world and welcome to our ___ hotel"),
            item("check in", kind="set_phrase"),
        ]

    def is_compositional(self, text, meaning):
        return False


def test_patterns_must_come_from_the_transcript(repo, tmp_path):
    """Given "Could I get ___?" as a prompt example the model returned exactly that, twice, for
    a transcript containing neither "could I get" nor "do you have any" — generic hotel English
    rather than anything the learner heard. An invented frame also anchors no highlight."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    # Grounded: `_is_grounded` drops an expression absent from its passage.
    media = FakeMedia(tmp_path)
    media.caption_texts = ["Hello world.", "Goodbye.", "check in now."]
    ImportPipeline(repo, settings, media, PatternAI()).run(job_id)

    kept = {e.text for e in repo.list_learning_expressions(episode_id)}
    assert kept == {"Hello ___ world", "check in"}


class SlotlessPatternAI(FakeAI):
    def classify_material(self, sentences):
        return "teaching"

    def teaching_traps(self, sentences):
        return [
            # Labelled a pattern, but it is a whole quoted line — nothing reusable.
            {"text": "I'd like to check in, please.", "kind": "pattern", "chinese": "x",
             "example": "Hello world.", "example_chinese": "y", "sentence_position": 0},
            # A real frame, short enough to survive either way.
            {"text": "Hello ___ world", "kind": "pattern", "chinese": "x",
             "example": "Hello world.", "example_chinese": "y", "sentence_position": 0},
        ]

    def is_compositional(self, text, meaning):
        return False


def test_a_slotless_pattern_is_not_a_pattern(repo, tmp_path):
    """The model labels whole quoted sentences as patterns. Demoted to a phrase, the line then
    has to pass the phrase-length limit — which is what removes it."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ImportPipeline(repo, settings, FakeMedia(tmp_path), SlotlessPatternAI()).run(job_id)

    stored = {e.text: e.type for e in repo.list_learning_expressions(episode_id)}
    assert stored == {"Hello ___ world": "pattern"}


def test_either_slot_notation_counts():
    """The scan asks for `___`, which reads as a blank to fill; `{}` was the earlier prompt's
    convention and its rows still exist. Checking only for braces demoted every pattern the
    current scan produces, which is why none reached the store as one."""
    assert has_slot("I have you on ___ floor")
    assert has_slot("I have you on {floor}")
    assert not has_slot("I'd like to check in, please.")
    # Length is waived only for a real frame, so a slotless line cannot smuggle itself in.
    assert is_studiable_expression("Would you like any help with ___ today please", "pattern")
    assert not is_studiable_expression(
        "Would you like any help with your luggage today please", "pattern"
    )


def test_weak_frames_are_rejected():
    """Three-pass scanning raised coverage and exposed the quality gate as the bottleneck: one
    122-line lesson produced 22 patterns, 16 of them weak. Every case here is a real result."""
    weak = lambda t: ImportPipeline._mechanically_rejected(t, "pattern")

    # The host DESCRIBING what hotels do. Information, not something to say.
    assert weak("they will ask for your ___") == "narration"
    assert weak("there's a safe where you keep ___") == "narration"
    assert weak("all of these things are called ___") == "narration"
    assert weak("it's directly connected to the ___") == "narration"
    # Mostly hole: no fixed frame survives between two blanks.
    assert weak("they have ___ where you can ___") == "narration"
    # Two slots is checked before two clauses, and this real result trips both.
    assert weak("plug a ___ and charge your ___") == "two slots"
    assert weak("check in and ___") == "two clauses"
    # A blank plus one content word teaches the word, which a phrase card does better.
    assert weak("under the ___") == "too bare"
    assert weak("return ___") == "too bare"
    assert weak("tip the ___") == "too bare"
    # A narrated line, caught by length.
    assert weak("call ___ by just dialing up a number") == "sentence"

    # And the frames that must survive: a particle after a verb carries the meaning, and a
    # noun after the slot is the frame's whole point, so neither counts as filler.
    for frame in ["I have you here for ___ nights.", "drop me off ___", "plug ___ in",
                  "on the ___ floor", "you have to ___", "let's check out ___",
                  "Could I get ___?", "Would you like any help with ___?"]:
        assert weak(frame) is None, frame


def test_a_pattern_may_be_longer_than_a_phrase():
    """A frame with slots is necessarily longer — "Would you like any help with ___" is six
    words and exactly the point — while a bare phrase stays capped so lines of dialogue stay
    out. And "I" must not read as a brand label, or every first-person frame is unstudiable."""
    rejected = ImportPipeline._mechanically_rejected
    assert rejected("Would you like any help with ___?", "pattern") is None
    assert rejected("Could I get a late checkout", "pattern") is None
    assert rejected("Let me know if you need anything", "pattern") is None
    # The same string as an ordinary phrase is too long to be one.
    assert rejected("Would you like any help with ___?", "set_phrase") == "sentence"
    # Dialogue and labels are still rejected whatever the kind claims.
    assert rejected("P level", "pattern") == "label"
    assert rejected("Stay close to me", "set_phrase") == "imperative"


class ExplodingScanAI(FakeAI):
    def hidden_traps(self, sentences):
        raise RuntimeError("the scan provider is down")


def test_a_failed_scan_costs_the_import_nothing(repo, tmp_path):
    """A scan that fails leaves the learner exactly where they were; a raised exception
    would instead lose the transcript, translation and audio they were waiting for."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ImportPipeline(repo, settings, FakeMedia(tmp_path), ExplodingScanAI()).run(job_id)

    assert repo.get_episode(episode_id).status == "ready"
    assert repo.get_job(job_id).status == "complete"
    assert repo.list_learning_expressions(episode_id) == []


# The parenthetical is why two transparent compounds survived the filter on a real
# transcript. "mini bar" glossed word-by-word is 小型的酒吧, and against 迷你吧 the comparison
# correctly says "same" — but the finder returns 迷你吧（酒店房间内收费的小冰箱）, and the aside
# describes the thing rather than translating it, so any two strings look different.
class StubbedAdapter(OpenAIAdapter):
    """The real verification logic with the two model calls replaced by recorded stubs."""

    def __init__(self, attempts, would_produce):
        self.attempt_payloads = []
        self._attempts = attempts
        self._would_produce = would_produce

    def _json(self, prompt, payload):
        if prompt == self.LEARNER_ATTEMPTS:
            self.attempt_payloads.append(payload)
            return {"attempts": self._attempts}
        return {"would_produce": self._would_produce}


def test_the_attempts_pass_never_sees_the_target_expression():
    """Two calls rather than one, deliberately: shown the target, the model writes it back as
    the learner's own attempt and every expression looks like one they could already say."""
    ai = StubbedAdapter(["very big bed", "super big bed"], would_produce=False)
    ai.is_compositional("king-size bed", "特大号床")

    assert ai.attempt_payloads, "the attempts pass must run"
    for payload in ai.attempt_payloads:
        assert "king" not in json.dumps(payload, ensure_ascii=False).lower()


def test_an_expression_the_learner_would_already_say_needs_no_card():
    # The axis is production, not comprehension. "king-size bed" reads effortlessly — and the
    # learner still says "very big bed", so it earns a card. Judging comprehension dropped it.
    unreachable = StubbedAdapter(["very big bed", "super big bed"], would_produce=False)
    assert unreachable.is_compositional("king-size bed", "特大号床") is False

    already_known = StubbedAdapter(["free breakfast", "breakfast included"], would_produce=True)
    assert already_known.is_compositional("free breakfast", "免费早餐") is True


def test_an_unusable_attempts_response_does_not_drop_the_expression():
    """Unverified is not the same as rejected: the finder already had a reason to report it."""
    class Broken(StubbedAdapter):
        def _json(self, prompt, payload):
            return "not a dict"

    assert Broken([], would_produce=True).is_compositional("card on file", "已存档的卡") is False


class FrameVariantAI(FakeAI):
    """The three wordings three real passes produced for one frame, one per pass.

    Worded against FakeMedia's own transcript ("Hello world." / "Goodbye."), because a frame
    whose words are not in the batch is rejected as invented before dedup ever runs.
    """

    # Both wordings must be GROUNDED in that transcript, or the invented-frame check removes
    # the second one and the test passes without dedup doing anything — which is exactly what
    # my first attempt did. These two differ only in where the blank sits.
    WORDINGS = ["hello ___ world", "hello world ___"]

    def __init__(self):
        self.pass_count = 0

    def classify_material(self, sentences):
        return "teaching"

    def teaching_traps(self, sentences):
        wording = self.WORDINGS[self.pass_count % len(self.WORDINGS)]
        self.pass_count += 1
        return [{"text": wording, "kind": "pattern", "chinese": "x",
                 "example": "Hello world.", "example_chinese": "y", "sentence_position": 0}]

    def is_compositional(self, text, meaning):
        return False


def test_frame_variants_reach_the_store_as_one_card(repo, tmp_path):
    """Merging has to happen where the store can see it. The store merges by exact text, so a
    dedup key computed and then unused left all three wordings as separate cards — which is
    what happened live, and what a key-only unit test cannot catch. Rewriting each variant to
    the first wording seen also keeps every occurrence, rather than dropping later rows."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ai = FrameVariantAI()
    ImportPipeline(repo, settings, FakeMedia(tmp_path), ai).run(job_id)

    assert ai.pass_count >= 2, "several passes must run for variants to appear at all"
    stored = [e.text for e in repo.list_learning_expressions(episode_id)]
    assert stored == ["hello ___ world"]


def test_one_frame_written_three_ways_is_one_pattern():
    """Three passes over one transcript produced "drop me off ___", "drop me off at ___" and
    "drop me off at the ___" — one frame, three cards — plus "plug ___ in" beside "plug a ___".
    A frame's identity is its content words; the preposition and where the blank sits are
    exactly what varies between two people saying the same thing."""
    key = lambda t: ImportPipeline._dedup_key(t, "pattern")
    assert key("drop me off ___") == key("drop me off at ___") == key("drop me off at the ___")
    assert key("plug ___ in") == key("plug a ___")
    assert key("tip the ___") == key("tip your ___")
    # Different frames must stay different: stripping function words cannot collapse them.
    assert key("check in the ___") != key("check out the ___")
    assert key("head down to ___") != key("drop me off at ___")


class UsageAI(FakeAI):
    """Supplies general usage for one expression and honestly declines for the other."""

    def __init__(self):
        self.asked: list[list[str]] = []

    def classify_material(self, sentences):
        return "native"

    def hidden_traps(self, sentences):
        def item(text):
            return {"text": text, "kind": "set_phrase", "chinese": "x",
                    "example": "hello world.", "example_chinese": "y", "sentence_position": 0}
        return [item("hello"), item("world")]

    def generic_usage(self, texts):
        self.asked.append(sorted(texts))
        # "world" gets a usage; "hello" is treated as a one-off with none.
        return {"world": "政策评论，正式\n银行游说写出对自己有利的规定。"}


def test_general_usage_is_a_separate_pass(repo, tmp_path):
    """This section is what makes a card reusable: seeing an expression once in one argument does
    not tell you where it belongs generally.

    It cannot come from the finder. The finder is bound to the transcript — `_is_grounded`
    rejects anything absent from it — and general usage must come from OUTSIDE. One call cannot
    be asked for both, and this session has shown what happens when a model is given two
    conflicting jobs: it satisfies one with the other's answer.
    """
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ai = UsageAI()
    ImportPipeline(repo, settings, FakeMedia(tmp_path), ai).run(job_id)

    stored = {e.text: e.when_to_use for e in repo.list_learning_expressions(episode_id)}
    assert stored.get("world", "").startswith("政策评论")
    # A declined usage stays empty rather than being filled with something plausible: an
    # invented general meaning teaches a usage that does not exist.
    assert not stored.get("hello")
    # Two passes: everything once in a batch, then whatever came back empty in small groups. The
    # log recorded zero failures while pearl-clutching, pump and seeded all returned nothing, and
    # each answers in full when asked in a group of five — a long list gets skimmed silently, and
    # a skipped expression is indistinguishable from one with no general usage.
    assert ai.asked[0] == ["hello", "world"], "first pass covers everything in one batch"
    assert ai.asked[1:] == [["hello"]], "second pass re-asks only what was skipped"


class BatchSizeAI(FakeAI):
    """Records the size of every general-usage call."""

    def __init__(self):
        self.sizes: list[int] = []
        self.lock = threading.Lock()

    def classify_material(self, sentences):
        return "native"

    def hidden_traps(self, sentences):
        # More expressions than one batch holds, all grounded in FakeMedia's transcript.
        return [{"text": word, "kind": "set_phrase", "chinese": "x",
                 "example": "hello world.", "example_chinese": "y", "sentence_position": 0}
                for word in ("hello", "world", "goodbye")]

    def generic_usage(self, texts):
        with self.lock:
            self.sizes.append(len(texts))
        return {t: "\u7528\u6cd5\u8bf4\u660e" for t in texts}


def test_general_usage_is_asked_in_small_batches(repo, tmp_path):
    """Batch size decides whether this section exists at all. Measured on ep8: one call covering
    all 140 expressions answered 18 of them; batches of 20 answered 79. Same model, same
    expressions, four times the coverage — a long list gets skimmed, and the skipped ones look
    exactly like "this expression has no general usage"."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ai = BatchSizeAI()
    ImportPipeline(repo, settings, FakeMedia(tmp_path), ai).run(job_id)

    assert ai.sizes, "the enrichment pass runs"
    assert max(ai.sizes) <= ImportPipeline.USAGE_BATCH
    assert ImportPipeline.USAGE_BATCH <= 40, "a long list gets skimmed"
    stored = [e.when_to_use for e in repo.list_learning_expressions(episode_id)]
    assert all(stored), "every card got its usage section"


class PlaceholderUsageAI(OpenAIAdapter):
    """The real parsing logic with the model call replaced."""

    def __init__(self, payload):
        self._payload = payload

    def _json(self, prompt, payload):
        return self._payload


class ChineseSourceAI(FakeAI):
    """Transcribes Chinese, and records whether the skipped passes were asked for anyway."""

    def __init__(self):
        self.translate_calls = 0
        self.trap_calls = 0
        self.insight_calls = 0

    def translate(self, items):
        self.translate_calls += 1
        return ["\u8bd1\u6587"] * len(items)

    def classify_material(self, sentences):
        return "native"

    def hidden_traps(self, sentences):
        self.trap_calls += 1
        return [{"text": "x", "kind": "set_phrase", "chinese": "y",
                 "example": "z", "example_chinese": "w", "sentence_position": 0}]

    def insight_chunk(self, lines):
        self.insight_calls += 1
        return {"claims": [{"claim": "\u5f00\u6e90\u76d1\u7ba1\u662f\u6743\u529b\u4e4b\u4e89",
                            "evidence": "\u4e3b\u64ad\u5f15\u7528\u4e86\u4e24\u4efd\u8349\u6848",
                            "at_ms": 1000}],
                "facts": []}

    def insight_synthesis(self, claims, facts):
        return {"thesis": "\u8fd9\u96c6\u5728\u8bb2\u5f00\u6e90 AI \u7684\u76d1\u7ba1\u4e4b\u4e89",
                "claims": claims, "facts": facts, "takeaways": [], "anchors": []}


def test_a_chinese_source_skips_translation_and_cards_but_keeps_insight(repo, tmp_path):
    """Importing a Chinese video is about its CONTENT.

    Translation and vocabulary cards both exist to close the gap between what was said and what the
    listener understood. For a source in the listener's own language there is no gap, so both are
    wasted calls and a shelf of words nobody needed. The 洞察 page is the opposite — it is why the
    video was imported at all.
    """
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ai = ChineseSourceAI()
    media = FakeMedia(tmp_path)
    # Chinese captions, which is the realistic path: YouTube auto-captions Chinese, so this is
    # what a real import of a Chinese video reads.
    media.caption_texts = ["\u8fd9\u4e00\u96c6\u6211\u4eec\u804a\u5f00\u6e90 AI \u7684\u76d1\u7ba1\u4e4b\u4e89\u3002",
                           "\u5b83\u5bf9\u521b\u4e1a\u516c\u53f8\u610f\u5473\u7740\u4ec0\u4e48\uff1f"]
    ImportPipeline(repo, settings, media, ai).run(job_id)

    assert ai.translate_calls == 0, "nothing to translate"
    assert ai.trap_calls == 0, "and no cards to extract"
    assert ai.insight_calls > 0, "but the insight page is the point"

    sentences = repo.list_sentences(episode_id)
    assert sentences, "the transcript is still stored"
    # The view renders `chinese` and the app decodes it as non-optional, so it has to hold
    # something — and for a Chinese source the source text IS that something.
    assert sentences[0].chinese == sentences[0].source_text
    assert not repo.list_learning_expressions(episode_id)


class SplittingTranslateAI(FakeAI):
    """Answers a run-on caption with several items, as the real model did."""

    def __init__(self):
        self.calls: list[list[str]] = []

    def translate(self, items):
        self.calls.append(list(items))
        if len(items) == 1 and "subgroup" in items[0]:
            # The measured shape: four translations for one unpunctuated line.
            return ["社区子群", "资产集合", "项目集合", "正在开展的项目"]
        return ["译文"] * len(items)


def test_a_run_on_caption_answered_as_a_list_is_joined(repo, tmp_path):
    """A 684-line episode failed on one caption with no punctuation in it.

    'community subgroup set of assets set of projects that are ha…' reads as a LIST, and the model
    returned four translations for that single line. The bisect cannot help — the batch is already
    one line — so it raised and lost the whole import.

    Joining them is the sentence it meant. Losing an episode over one run-on caption is the worse
    outcome by a wide margin.
    """
    ai = SplittingTranslateAI()
    pipeline = ImportPipeline(repo, Settings(_env_file=None, data_dir=tmp_path),
                             FakeMedia(tmp_path), ai)
    result = pipeline._translate_exact(["community subgroup set of assets"])

    assert len(result) == 1, "one line in, one line out"
    assert result[0] == "社区子群资产集合项目集合正在开展的项目"


def test_a_line_that_will_not_translate_keeps_its_source(repo, tmp_path):
    """One bad line must not cost the episode.

    Three separate lines did exactly that on one 684-sentence import, each visible only after the
    previous was fixed: a URL, a run-on caption the model answered as a list, and a batch that came
    back one item short. An episode with a few English lines is far better than one that will not
    open, and the untranslated line is visible on screen, which is its own report.
    """
    class EnglishPiecesAI(FakeAI):
        def translate(self, items):
            return ["community", "subgroup"] if len(items) == 1 else ["译文"] * len(items)

    pipeline = ImportPipeline(repo, Settings(_env_file=None, data_dir=tmp_path),
                             FakeMedia(tmp_path), EnglishPiecesAI())
    pipeline._untranslated_lines = 0
    source = "community subgroup and more prose here"
    assert pipeline._translate_exact([source]) == [source], "the source stands in for itself"
    assert pipeline._untranslated_lines == 1, "and it is counted, so a broken translator is caught"


def test_a_url_does_not_fail_the_whole_episode():
    """A 684-sentence import died on one line: 'creativeplanning.com/allin.'

    The model returned 'creativeplanning.com/allin。' — correct, since a URL has nothing to
    translate, and the only change is the full stop. But the guard requires CJK, '。' is not CJK, and
    `_has_translatable_words` reads "creativeplanning" and "allin" as ordinary words. So it decided
    the line was untranslated, bisected down to it, and failed the episode over a URL.
    """
    assert ImportPipeline._is_translated("creativeplanning.com/allin.",
                                         "creativeplanning.com/allin。")
    assert ImportPipeline._is_translated("@allin_pod", "@allin_pod")
    assert ImportPipeline._is_translated("DEP40.", "DEP40.")


def test_english_left_in_english_is_still_a_failure():
    """The exemption has to be narrow, and my first two attempts were not.

    Comparing the two with punctuation stripped passed 'Goodbye.' -> 'Goodbye.', which is exactly
    the failure this guard exists for. Requiring "the source contains punctuation" passed it too,
    because a sentence ends in a full stop. What distinguishes a URL is STRUCTURE: a separator with
    word characters on both sides.
    """
    assert not ImportPipeline._is_translated("Goodbye.", "Goodbye.")
    assert not ImportPipeline._is_translated("We have become a nation.", "We have become a nation.")
    # An abbreviation is not a URL.
    assert not ImportPipeline._is_translated("Mr. Smith.", "Mr. Smith.")
    # A URL among prose is a sentence, and the prose still needs translating.
    assert not ImportPipeline._is_translated("go to x.com/allin now", "go to x.com/allin now")
    # And a real translation passes, which is the point of the whole thing.
    assert ImportPipeline._is_translated("Goodbye.", "再见。")


class SilentlyFailingMedia(FakeMedia):
    """yt-dlp exits 0 and writes no mp3 — the real failure behind an ffmpeg 254."""

    def download_audio(self, url, destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        # What actually happened: the intermediate .webm was left behind and no mp3 appeared.
        (destination.parent / "source.webm").write_bytes(b"webm")
        return destination


def test_an_episode_cannot_claim_audio_it_does_not_have(repo, tmp_path):
    """A newly imported episode reported "Command '[ffmpeg …]' returned non-zero exit status 254".

    The mp3 was never written. yt-dlp had exited 0 leaving only its intermediate .webm, and every
    step after that trusted the file to exist: the audio path was recorded regardless, ffmpeg was
    handed a path to nothing, and the error named ffmpeg — three steps past the cause. The database
    then said the episode had audio, so the app offered a source it could not play.
    """
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    # `run` records the failure and re-raises, so the worker logs it — that is deliberate, and the
    # point of this test is what it recorded on the way out.
    with pytest.raises(RuntimeError, match="Audio was not downloaded"):
        ImportPipeline(repo, settings, SilentlyFailingMedia(tmp_path), FakeAI()).run(job_id)

    episode = repo.get_episode(episode_id)
    assert episode.status == "failed", "a missing file is a failed import, not a ready one"
    assert episode.audio_path is None, "and no path is recorded for a file that is not there"
    # The message must name the audio, not a tool three steps downstream.
    assert "udio" in (episode.error or ""), episode.error
    assert "ffmpeg" not in (episode.error or "").lower()


def test_audio_is_apportioned_into_sentences_when_no_timings_come_back():
    """The fallback used when YouTube rate-limits captions.

    This DashScope deployment has no /audio/transcriptions route at all — measured: it 404s while
    /chat/completions returns 400, and none of the ASR models it lists are reachable there either.
    `gpt-4o-transcribe` was never one of its models. So audio goes through an audio-capable chat
    model, which returns text and no timings.

    Timings are therefore ESTIMATED, proportional to sentence length. Tapping a line lands near it
    rather than on it, and the 洞察 page's anchors are approximate — worth stating plainly, since a
    caption track gives real ones.
    """
    text = "SpaceX完成了最大的IPO。在这之前，你知道美股最大的IPO是谁吗？还是十二年前的阿里巴巴。"
    segments = OpenAIAdapter._apportion(text, offset_ms=0, duration_ms=60_000)

    # Split on sentence ENDS, not newlines: asked for one sentence per line, the model returned a
    # single fifteen-minute paragraph. A transcript of one line has nothing to tap and renders as a
    # wall of text.
    assert len(segments) == 3
    assert segments[0].text.endswith("。")
    # Proportional, not equal — a three-word line and a forty-word line are not the same duration,
    # and equal division drifts badly across a long chunk.
    assert segments[1].end_ms - segments[1].start_ms > segments[2].end_ms - segments[2].start_ms
    # Contiguous and inside the chunk.
    assert segments[0].start_ms == 0
    assert [s.start_ms for s in segments] == sorted(s.start_ms for s in segments)
    assert segments[-1].end_ms <= 60_000

    # An offset shifts the whole chunk, since chunks are transcribed independently.
    shifted = OpenAIAdapter._apportion(text, offset_ms=900_000, duration_ms=60_000)
    assert shifted[0].start_ms == 900_000
    # Nothing said produces nothing, rather than a zero-length segment.
    assert OpenAIAdapter._apportion("", offset_ms=0, duration_ms=60_000) == []


def test_english_audio_splits_on_its_own_punctuation():
    """Both punctuation families, since the fallback runs on whichever language the audio is."""
    segments = OpenAIAdapter._apportion(
        "The IPO was the largest ever. Do you know the previous record? It was Alibaba.",
        offset_ms=0, duration_ms=30_000)
    assert len(segments) == 3
    assert segments[0].text == "The IPO was the largest ever."


def test_the_caption_file_is_matched_by_prefix_not_by_an_enumerated_list(tmp_path):
    """A second Chinese video failed with the same "Error code: 404" after the first was fixed.

    yt-dlp appends the SOURCE language to an auto-translated track, and that suffix varies per
    video: one episode's own language was "zh" and it wrote `captions.zh-Hans-zh.json3`, the next
    was "zh-Hans" and wrote `captions.zh-Hans-zh-Hans.json3`. My picker held a hardcoded list of
    filenames, so it could only ever contain combinations I had happened to see — the second video
    matched nothing, fell through to audio transcription, and died there.
    """
    def pick(*names: str) -> str | None:
        for directory in [tmp_path / str(hash(names))]:
            directory.mkdir(parents=True, exist_ok=True)
            for name in names:
                (directory / name).write_text("{}")
            found = YtDlpMediaAdapter._pick_caption_file(directory)
            return found.name if found else None

    # Both real shapes, from the two videos that produced them.
    assert pick("captions.zh.json3", "captions.zh-Hans-zh.json3") == "captions.zh.json3"
    assert pick("captions.zh-Hans-zh-Hans.json3") == "captions.zh-Hans-zh-Hans.json3"

    # An ORIGINAL track beats a translated one even when the translation's language ranks higher.
    # Checking exact-then-prefix per language got this wrong: with zh-Hans ahead of zh, a video whose
    # own language is "zh" matched the zh-Hans TRANSLATION before reaching its native track.
    assert pick("captions.zh.json3", "captions.zh-Hans-zh.json3") == "captions.zh.json3"
    assert pick("captions.zh-Hans.json3", "captions.en-zh-Hans.json3") == "captions.zh-Hans.json3"

    # English still wins when it is the video's own language.
    assert pick("captions.en.json3", "captions.zh-Hans.json3") == "captions.en.json3"
    assert pick("captions.en.json3", "captions.en-orig.json3") == "captions.en-orig.json3"

    # A language nobody asked for still beats falling through: audio transcription names an OpenAI
    # model against a DashScope endpoint, so that path 404s two layers from the real problem.
    assert pick("captions.ja.json3") == "captions.ja.json3"
    assert pick() is None


def test_captions_are_requested_in_chinese_too():
    """A Chinese video failed with "Error code: 404" and the 404 had nothing to do with Chinese.

    The caption fetch asked only for `en-orig,en`. The video had zh auto-captions and no English
    track, so the transcript came back empty, the pipeline fell back to audio transcription, and THAT
    died: the fallback names an OpenAI model (`gpt-4o-transcribe`) against a DashScope endpoint,
    which has no such model. Two layers away from the actual mistake, which was not asking for the
    captions that existed.
    """
    langs = YtDlpMediaAdapter.CAPTION_LANGS
    assert "zh" in langs and "zh-Hans" in langs, "ask for the captions a Chinese video has"
    # English first: an English video with a Chinese TRANSLATION track must still be read from its
    # own language rather than from the translation.
    assert langs.index("en-orig") < langs.index("zh"), "English stays the preferred source"
    assert langs.index("zh-Hans") < langs.index("zh-Hant"), "Simplified before Traditional"

    # And the file-picking order must cover the same languages, including the "-zh" suffix yt-dlp
    # writes on the from-Chinese tracks. Two separate lists is how the request and the pick drift
    # apart — asking for a track and then never looking for it is exactly this bug again.
    # Selection is by prefix now (see the test above), so there is no second list to keep in step.


def test_language_is_counted_not_asked():
    """A language is visible in the characters. Spending a model call to learn what a regex can see
    would add a failure mode for nothing — and this one has to be right, since it gates three
    stages."""
    seg = lambda text: TranscriptSegment(0, 1000, None, text)
    assert not ImportPipeline._is_chinese_source([seg("The fight over open source AI regulation.")])
    assert ImportPipeline._is_chinese_source([seg("这一集我们聊聊开源 AI 的监管之争。")])
    # A Chinese talk quoting English terms heavily is still Chinese — common in tech podcasts, and
    # a threshold tuned too high would send it down the translation path.
    assert ImportPipeline._is_chinese_source(
        [seg("我们聊 AI safety 和 alignment 的落地问题，还有 Anthropic 的立场。")])
    # An English episode that mentions Chinese must not flip.
    assert not ImportPipeline._is_chinese_source(
        [seg("He said the word 中文 once, then went back to English for the rest of the hour.")])
    assert not ImportPipeline._is_chinese_source([])


def test_the_chunk_pass_may_answer_in_english():
    """The first real run produced NO page at all, silently. The chunk prompt said "IN CHINESE"
    and the model — reading an English transcript — answered in English, so `chinese_prose` dropped
    every claim, both lists came back empty, `_clean_insight` returned None, and nothing was
    logged. No page, no error.

    Asking a pass that is reading English to answer in Chinese is fighting it. The chunk pass now
    works in its own language and the synthesis pass translates, which is also where the length
    and inference rules apply.
    """
    chunk = OpenAIAdapter.INSIGHT_CHUNK
    assert "IN CHINESE" not in chunk, "the chunk pass must not be asked to translate"
    assert "the language you are reading" in chunk

    # And the synthesis pass must not claim to know which language it is handed. It said "in
    # English … TRANSLATED INTO CHINESE", which is false for a Chinese source — telling a model to
    # translate text that needs no translating invites it to rewrite what was already right.
    synthesis = OpenAIAdapter.INSIGHT_SYNTHESIS
    assert "in order, in English" not in synthesis
    assert "already Chinese" in synthesis, "both cases named explicitly"


def test_a_takeaway_that_only_restates_is_dropped():
    """The 洞察 page exists so an hour can be understood in five minutes, and its takeaways are the
    part that has to be an INFERENCE. "Do not restate" is exactly the instruction a model
    satisfies by rewording, so it is enforced here rather than hoped for in the prompt: a reader
    who finds restatement in this section stops trusting it, and an empty section is honest.
    """
    page = ImportPipeline._clean_insight({
        "thesis": "这集在争论 AI 监管是真安全还是商业策略",
        "claims": [{"claim": "风险叙事服务于监管套利", "evidence": "没有方法论", "at_ms": 1000}],
        "facts": [{"fact": "预测 50% 的知识工作岗位将消失", "sourced": False, "at_ms": 2000}],
        "takeaways": [
            "监管辩论的真实战场是标准制定权，而不是安全本身",
            "这集在争论 AI 监管究竟是真安全还是商业策略",
        ],
    }, total_ms=60_000)
    assert page["takeaways"] == ["监管辩论的真实战场是标准制定权，而不是安全本身"]


def test_a_figure_is_unsourced_unless_it_says_otherwise():
    """A number said off the cuff, shown as established, is what this flag prevents — the reader
    would go on to quote it. So anything not explicitly `true` is treated as unsourced."""
    page = ImportPipeline._clean_insight({
        "thesis": "这集讨论前沿实验室的融资压力",
        "claims": [{"claim": "融资环境正在收紧", "at_ms": 0}],
        "facts": [
            {"fact": "该研究发表在 Nature 上", "sourced": True},
            {"fact": "预测 50% 岗位消失", "sourced": "yes"},   # not a bool
            {"fact": "算力成本翻了三倍"},                        # absent
        ],
    }, total_ms=60_000)
    assert [f["sourced"] for f in page["facts"]] == [True, False, False]


def test_an_anchor_outside_the_episode_is_not_offered():
    """Tapping a timestamp seeks the audio. One past the end would seek nowhere, which is worse
    than a claim with no anchor at all."""
    page = ImportPipeline._clean_insight({
        "thesis": "这集讨论监管与竞争",
        "claims": [{"claim": "标准制定权是真正的战场", "at_ms": 9_999_999}],
        "facts": [{"fact": "两家公司主导了草案", "sourced": True, "at_ms": 30_000}],
        "anchors": [{"at_ms": 30_000, "why": "交锋处"}, {"at_ms": 9_999_999, "why": "越界"}],
    }, total_ms=60_000)
    assert page["claims"][0]["at_ms"] is None, "out of range, so no offset offered"
    assert [a["at_ms"] for a in page["anchors"]] == [30_000], "and the bad anchor is gone"


def test_the_page_is_capped_to_a_five_minute_read():
    """Length is the whole point: a page you cannot read in 5-10 minutes has not replaced the
    hour. Facts are trimmed before claims, because the claims carry the argument."""
    page = ImportPipeline._clean_insight({
        "thesis": "这集讨论监管",
        "claims": [{"claim": "论点" + "、内容详尽" * 60, "at_ms": 0} for _ in range(5)],
        "facts": [{"fact": "事实" + "、数字若干" * 60, "sourced": True} for _ in range(8)],
    }, total_ms=60_000)
    assert ImportPipeline._insight_length(page) <= ImportPipeline.MAX_INSIGHT_CHARS
    assert len(page["claims"]) >= 3, "the argument survives the trim"


def test_an_english_page_is_no_page():
    """Asked for Chinese and answered in English is a failure mode this session has seen on every
    field it applied to — 196 of 196 cards once. The reader cannot use an English summary."""
    assert ImportPipeline._clean_insight({
        "thesis": "This episode argues about whether AI regulation is safety or strategy",
        "claims": [{"claim": "The risk narrative serves regulatory capture"}],
    }, total_ms=60_000) is None


def test_a_leading_context_qualifier_is_dropped():
    """The model also writes the qualifier in FRONT: "（本语境中）一种刻意夸张的姿态". It sits at
    position 1, so the clause-boundary search has nothing earlier to cut back to and kept the whole
    string — 3 of 137 definitions still opened by announcing they were about this episode.
    """
    trim = ImportPipeline._general_definition
    assert trim("（本语境中）一种刻意夸张的危机反应姿态，表现为反复强调风险") == "一种刻意夸张的危机反应姿态，表现为反复强调风险"
    assert trim("（本语境特指）一种模糊泛化的政治标签，指代左翼倾向") == "一种模糊泛化的政治标签，指代左翼倾向"

    # A parenthetical that is part of the definition stays: only ones announcing the episode go.
    kept = "（构词：centi- + billionaire）非正式造词，指身家达百亿美元的富豪"
    assert trim(kept) == kept
    # And a short gloss is not mangled.
    assert trim("科技寡头") == "科技寡头"


def test_only_one_general_definition_exists():
    """An earlier edit left TWO `_general_definition` methods in the class. Python keeps the last,
    so the fixed copy was dead code and the leading-qualifier strip silently did nothing — the
    tests passed, and `inspect.getsource` was what finally showed the version being run was not
    the version I had edited.
    """
    source = Path("src/nexa_insight_api/pipeline.py").read_text()
    assert source.count("def _general_definition(") == 1


def test_the_prompt_reserves_null_for_real_coinages():
    """Three wrong diagnoses preceded this one: batch too large, batch dropped, batch too small.
    The log showed zero failures, and expressions declined a batch of 20 declined a group of 5 and
    declined when asked ALONE — so batch size was never the mechanism.

    The cause was my own wording. "no general currency — a metaphor someone invented, a term
    coined for one argument" reads as a licence to decline anything whose pairing feels new, so
    rage baiting, golden vote and pearl-clutching all came back null despite being perfectly
    reusable English. The instruction now says the bar is high, names those very cases as ones to
    answer, and states why guessing null is not free: an omission and a genuine coinage look
    identical on the card.
    """
    prompt = OpenAIAdapter.GENERIC_USAGE
    assert "ONLY when" in prompt, "the bar must be stated as narrow"
    assert "rage baiting" in prompt, "the borderline cases are named, not left to judgement"
    assert "identical to the learner" in prompt, "declining has a stated cost"


class FlakyUsageAI(FakeAI):
    """Fails the first general-usage call, succeeds on the retry."""

    def __init__(self):
        self.calls = 0

    def classify_material(self, sentences):
        return "native"

    def hidden_traps(self, sentences):
        return [{"text": "hello", "kind": "set_phrase", "chinese": "x",
                 "example": "hello world.", "example_chinese": "y", "sentence_position": 0}]

    def generic_usage(self, texts):
        self.calls += 1
        if self.calls == 1:
            raise RuntimeError("provider hiccup")
        return {"hello": "\u53e3\u8bed\uff0c\u591a\u7528\u4e8e\u95ee\u5019"}


def test_a_failed_usage_batch_retries_and_says_so(repo, tmp_path, capsys):
    """A failed batch returns {} for all 20 of its expressions, which looks exactly like "none of
    these has a general usage". 52 cards were missing the section and the log said nothing, so a
    dropped batch and an honest answer were indistinguishable.

    Fifth instance this session of a swallowed failure that produced plausible-looking output.
    """
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ai = FlakyUsageAI()
    ImportPipeline(repo, settings, FakeMedia(tmp_path), ai).run(job_id)

    assert ai.calls == 2, "the batch is retried rather than abandoned"
    card = repo.list_learning_expressions(episode_id)[0]
    assert card.when_to_use, "the retry's answer reaches the card"
    assert "failed" in capsys.readouterr().out, "and the first failure is on the record"


def test_the_word_null_is_not_a_usage_section():
    """A model asked to return null sometimes writes the WORD. One card stored "null" as its
    常见用法, because checking for emptiness alone does not catch a non-empty placeholder —
    and stored verbatim it reads as content."""
    ai = PlaceholderUsageAI({"items": [
        {"text": "unobfuscate these thinking tokens", "usage": "null"},
        {"text": "doomerism", "usage": "  None  "},
        {"text": "pearl-clutching", "usage": "讽刺性习语，多用于文化批评"},
    ]})
    usages = ai.generic_usage(["unobfuscate these thinking tokens", "doomerism", "pearl-clutching"])

    assert "unobfuscate these thinking tokens" not in usages
    assert "doomerism" not in usages
    assert usages["pearl-clutching"].startswith("讽刺性习语")


def test_an_example_is_never_a_paragraph():
    """The example is the one section a card cannot do without, so it is capped rather than
    dropped. A tolerant `or` fallback to the model's raw text stored 4699 characters on one real
    card — after I had already "fixed" the 1590-character version of the same mistake."""
    long_passage = "Nothing relevant here. " * 200
    line = ImportPipeline._example_line("back channel", long_passage)
    assert len(line) <= ImportPipeline.MAX_EXAMPLE_CHARS
    assert line.endswith("…"), "truncation is visible, not silent"

    # A real sentence is returned whole.
    exact = ImportPipeline._example_line("back channel", "They used a back channel to settle it.")
    assert exact == "They used a back channel to settle it."


class PollutedFieldsAI(FakeAI):
    """Returns exactly what the model produced on a real run: a definition carrying this
    episode's argument, and an English register note."""

    def classify_material(self, sentences):
        return "native"

    def hidden_traps(self, sentences):
        return [{
            "text": "hello",
            "kind": "set_phrase",
            "chinese": "\u5bf9\u65e0\u5bb3\u4e4b\u4e8b\u5938\u5f20\u5730\u8868\u73b0\u9053\u5fb7\u9707\u60ca；\u6b64\u5904\u6307 Anthropic \u7684\u53d9\u4e8b\u98ce\u683c",
            "context_meaning": "\u4e3b\u64ad\u7528\u5b83\u6279\u8bc4\u5bf9\u65b9",
            "example": "hello world.",
            "example_chinese": "y",
            "sentence_position": 0,
        }]

    def generic_usage(self, texts):
        return {"hello": "Informal, often ironic register; used in commentary and op-eds."}


def test_the_pipeline_applies_both_guards_not_just_defines_them(repo, tmp_path):
    """Driven through `run` rather than calling the helpers, because testing a helper alone passes
    even when nothing calls it — which is exactly what happened when I first wrote these two."""
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    ImportPipeline(repo, settings, FakeMedia(tmp_path), PollutedFieldsAI()).run(job_id)

    card = repo.list_learning_expressions(episode_id)[0]
    # The definition stops before 此处; the argument lives in 这集里, which already has it.
    assert "此处" not in (card.chinese or ""), card.chinese
    assert "Anthropic" not in (card.chinese or "")
    assert card.chinese.startswith("对无害之事")
    # An English register note is dropped rather than rendered as an explanation.
    assert not card.when_to_use, card.when_to_use


def test_this_episodes_argument_is_cut_out_of_the_definition():
    """The prompt forbids folding the speaker's argument into the gloss and 22 of 132 cards did it
    anyway: "…夸张地做出惊恐姿态；此处被 speaker 用作批判性标签，特指 Anthropic 在 AI 风险叙事
    中…". Meeting the word elsewhere, the learner is then taught the accusation. 这集里 already
    holds that half, so it is duplication as well as pollution.

    Cut rather than rejected — the part BEFORE the deixis is a good definition, and dropping it
    would lose the one section every card needs.
    """
    trim = ImportPipeline._general_definition

    polluted = "字面意为‘攥紧珍珠’，形容夸张地做出惊恐姿态；此处被 speaker 用作批判性标签，特指 Anthropic 的叙事风格"
    assert trim(polluted) == "字面意为‘攥紧珍珠’，形容夸张地做出惊恐姿态"

    # The deixis can sit INSIDE a parenthetical, and cutting there left an unclosed bracket on a
    # real card: "…（源自计算机操作‘双击’打开文件/信息".
    parenthetical = "深入探究某事的深层原因或细节（源自计算机操作‘双击’，此处为比喻性引申）"
    assert trim(parenthetical) == "深入探究某事的深层原因或细节"

    # A definition that OPENS with the deixis is not pollution — "a term the speaker coined" is
    # what a coined term's definition looks like. Cutting would leave nothing, so it stays.
    coined = "说话人临时创造的术语，指模型生成过程中的中间推理表征"
    assert trim(coined) == coined

    # A company name is not evidence: "frontier labs" legitimately MEANS those companies.
    legit = "前沿实验室：指在基础模型研发上最领先的少数机构（如 OpenAI、Anthropic、DeepMind）"
    assert trim(legit) == legit


def test_a_chinese_field_holding_english_is_dropped():
    """One run produced 196 of 196 cards whose 这集里 was raw English transcript. The model had
    ignored the field name and a tolerant `or` fallback quietly substituted the old value, so
    every card looked populated and taught nothing.

    The card renders whatever is in the field, so a wrong-language value is worse than an empty
    one: it occupies the section that was meant to explain what the speaker meant.
    """
    keep = chinese_prose
    assert keep("监管俘获：被监管方让规则服务自己") is not None
    # Chinese prose quoting English terms is still Chinese prose.
    assert keep("主播指 Anthropic 借 AI safety 推动监管") is not None

    assert keep("I know the Silicon Valley shorthand where regulation equals") is None
    assert keep("") is None
    assert keep(None) is None
    assert keep("ok") is None, "too short to be an explanation"


def test_the_source_line_is_one_sentence_without_transcript_artefacts():
    """The field averaged 111 characters and ran to 1590 on a real episode, at which point it
    held the same text as the example and neither showed the expression's shape."""
    line = ImportPipeline._source_line(
        "center myself",
        ">> he did respond to me. I mean, I I want to center myself, but the reality is he did "
        "not respond to what Gavin said.")
    assert line.startswith("I mean, I want to center myself"), line
    assert ">>" not in line, "speaker markers are transcription artefacts, not English"
    assert "I I" not in line, "so are stutters"

    # A speaker change is a sentence boundary even without punctuation. Stripping only a LEADING
    # marker left a second one mid-sentence on a real card.
    two_speakers = ">> When's the last time we heard >> Unfortunately, it was written by us."
    assert ">>" not in ImportPipeline._source_line("written by us", two_speakers)

    # Absent from the passage: return NOTHING. Matching on the first word gave "clear all the
    # pathways" the line "Now, [clears throat] do it." — a wrong source line is worse than an
    # absent one, because the learner cannot tell it is wrong.
    assert ImportPipeline._source_line(
        "clear all the pathways", "Now, [clears throat] do it. Now, do it for homes.") == ""


def test_a_verb_and_its_bare_object_are_one_card():
    """ep8 produced "obfuscate", "obfuscates it" and "promulgates" as separate cards. A trailing
    object pronoun carries no meaning of its own, and the stemmer was asymmetric: it stripped
    both letters of "es", so "obfuscates" became "obfuscat" while "obfuscate" kept its e and the
    two never met."""
    key = lambda text: ImportPipeline._dedup_key(text, "set_phrase")
    assert key("obfuscate") == key("obfuscates it")
    assert key("obfuscate") == key("promulgate".replace("promulgate", "obfuscates"))
    assert key("job displacement") == key("job displacements")

    # Anchored to the END, so a pronoun inside a phrase is untouched — "call it a day" is not
    # "call a day".
    assert key("call it a day") != key("call a day")
    # And the user's line on what stays separate: containment and prefixes are different cards,
    # because "jailbreak models" and "unobfuscate" can be distinct things to learn.
    assert key("jailbreak") != key("jailbreak models")
    assert key("obfuscate") != key("unobfuscate")
    assert key("headcount") != key("entry level headcount")


def test_one_concept_rephrased_is_one_card():
    """A real native run produced "intelligence sovereignty" beside "intelligent sovereignty" —
    one concept the speaker kept rephrasing, and three passes each caught a different wording.
    Keys are stemmed so a word's grammatical form is not a second card."""
    key = lambda text: ImportPipeline._dedup_key(text, "set_phrase")
    assert key("intelligence sovereignty") == key("intelligent sovereignty")
    assert key("job displacement") == key("job displacements")

    # Word order still separates expressions, so keys are NOT sorted: these two differ by a
    # particle that carries the whole meaning.
    assert key("check in") != key("check out")
    # A synonym is not an inflection. Merging "AI" into "intelligence" needs judgement about
    # meaning, which a stemmer has no business making.
    assert key("AI sovereignty") != key("intelligence sovereignty")
    # And a longer expression containing a shorter one stays its own card.
    assert key("headcount") != key("entry level headcount")

    # Short words survive stemming: stripping "s" from "is" or "es" from "yes" would merge
    # unrelated expressions.
    assert ImportPipeline._stem("is") == "is"
    assert ImportPipeline._stem("yes") == "yes"


def test_the_same_phrase_with_a_different_determiner_is_one_card():
    """A real run produced both "tip your housekeeper" and "tip the housekeeper". Keying on
    exact text splits every phrase whose determiner the speaker varied between mentions."""
    key = ImportPipeline._dedup_key
    assert key("tip your housekeeper") == key("tip the housekeeper")
    assert key("Check In") == key("check in")
    assert key("drop off the bags") == key("drop off your bags")
    # Distinct expressions must stay distinct: stripping determiners cannot collapse them.
    assert key("check in") != key("check out")
    assert key("card on file") != key("on file")


def test_core_meaning_drops_the_explanatory_aside():
    core = OpenAIAdapter._core_meaning
    assert core("迷你吧（酒店房间内收费的小冰箱）") == "迷你吧"
    assert core("客房服务（酒店提供的送餐到房间的服务）") == "客房服务"
    # Several senses is not one meaning; the comparison takes the first.
    assert core("已存档；已登记在系统中") == "已存档"
    assert core("退房；查看；检查") == "退房"
    # Nothing to strip leaves the meaning alone, and a meaning that is ONLY an aside is
    # kept rather than reduced to nothing.
    assert core("支付押金") == "支付押金"
    assert core("（无）") == "（无）"


def test_a_403_says_what_to_do_about_it():
    """`HTTP Error 403: Forbidden` reached the learner verbatim and reads like the video is
    private or the network is blocked. It is neither: YouTube periodically changes how media
    URLs are signed, and a yt-dlp older than that change computes a signature the CDN rejects.
    Seen with 2026.07.04 against a public video whose formats listed fine — metadata worked and
    only the download 403'd, which is the fingerprint.

    Driven through _run rather than calling _known_failure directly: testing the helper alone
    passes even when nothing raises its result, which is exactly the vacuous test this repo
    keeps producing.
    """
    adapter = YtDlpMediaAdapter()
    failure = subprocess.CalledProcessError(
        1, ["yt-dlp"], stderr="ERROR: unable to download video data: HTTP Error 403: Forbidden")
    with patch("subprocess.run", side_effect=failure):
        with pytest.raises(RuntimeError) as raised:
            adapter._run(["yt-dlp", "--version"])
    message = str(raised.value)
    assert "yt-dlp" in message and "date" in message, message
    assert "403" in message

def test_other_youtube_refusals_are_named_too():
    known = YtDlpMediaAdapter._known_failure
    assert "bot" in (known("ERROR: Sign in to confirm you're not a bot") or "")
    assert "private" in (known("ERROR: Private video. Sign in if you've been granted access") or "")
    # Anything unrecognised keeps its raw text, which is more useful than a wrong guess.
    assert known("ERROR: some brand new failure mode") is None
    assert known("") is None


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
