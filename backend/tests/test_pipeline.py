import json
import os
import threading
import time
from pathlib import Path
from unittest.mock import patch

import pytest

from nexa_insight_api.models import Episode, ImportJob
from nexa_insight_api.repositories import has_slot, is_studiable_expression
from nexa_insight_api.pipeline import ImportPipeline, MediaMetadata, OpenAIAdapter, TranscriptSegment, YtDlpMediaAdapter
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

    def hidden_traps(self, sentences):
        # One shifted sense in the first line of every batch, so remapping is observable.
        return [{
            "text": "Hello world",
            "kind": "shifted",
            "chinese": "\u6253\u62db\u547c",
            "sense_group": "Hello world.",
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
    assert found.restored == "Hello world."
    assert found.heard_as == "你好，世界"
    assert found.when_to_use == "测试用"


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

    def hidden_traps(self, sentences):
        self.calls += 1
        # One item per pass, never repeating — the observed behaviour, taken to its extreme.
        return [{
            "text": f"phrase {self.calls}", "kind": "set_phrase", "chinese": "x",
            "example": "Hello world.", "example_chinese": "y", "sentence_position": 0,
        }]


def test_each_batch_is_scanned_several_times_and_the_union_kept():
    """One pass samples a batch rather than enumerating it: five runs of the same 40 lines
    returned 16 distinct items with ZERO overlap. A single pass therefore drops most of what
    is there, which is why an expression can go missing with nothing rejecting it."""
    ai = SamplingAI()
    pipeline = ImportPipeline.__new__(ImportPipeline)
    pipeline.ai = ai
    found = pipeline._hidden_traps([TranscriptSegment(0, 900, None, "Hello world.")], "native")

    assert ai.calls == ImportPipeline.TRAP_PASSES
    assert [f["text"] for f in found] == [
        f"phrase {n}" for n in range(1, ImportPipeline.TRAP_PASSES + 1)
    ], "every pass contributes; the union is kept rather than the last result"


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
    ImportPipeline(repo, settings, FakeMedia(tmp_path), ai).run(job_id)

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
    ImportPipeline(repo, settings, FakeMedia(tmp_path), ShapesAI()).run(job_id)

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
            # Grounded: FakeMedia's transcript is "Hello world." / "Goodbye."
            item("Hello ___"),
            # Invented: generic English for the topic, in a transcript that never said it.
            item("Could I get ___?"),
            # A frame whose second half was invented must go too — checking only the longest
            # run would pass this.
            item("Hello ___ and welcome to our ___ hotel"),
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
    ImportPipeline(repo, settings, FakeMedia(tmp_path), PatternAI()).run(job_id)

    kept = {e.text for e in repo.list_learning_expressions(episode_id)}
    assert kept == {"Hello ___", "check in"}


class SlotlessPatternAI(FakeAI):
    def classify_material(self, sentences):
        return "teaching"

    def teaching_traps(self, sentences):
        return [
            # Labelled a pattern, but it is a whole quoted line — nothing reusable.
            {"text": "I'd like to check in, please.", "kind": "pattern", "chinese": "x",
             "example": "Hello world.", "example_chinese": "y", "sentence_position": 0},
            # A real frame, short enough to survive either way.
            {"text": "Hello ___", "kind": "pattern", "chinese": "x",
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
    assert stored == {"Hello ___": "pattern"}


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
