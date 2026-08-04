import pytest

from nexa_insight_api.models import Episode, ImportJob


def _seed_episode(repo) -> int:
    with repo.session() as session:
        episode = Episode(source_url="https://youtu.be/x", youtube_id="abcdefghijk", status="queued")
        session.add(episode)
        session.flush()
        session.add(ImportJob(episode_id=episode.id, status="queued"))
        session.commit()
        return episode.id


def test_claim_next_job_marks_running_and_increments_attempts(repo):
    _seed_episode(repo)
    job = repo.claim_next_job()
    assert job is not None
    assert job.status == "running"
    assert job.attempts == 1
    assert repo.claim_next_job() is None  # no more queued jobs


def test_requeue_running_jobs_restores_interrupted_work(repo):
    _seed_episode(repo)
    job = repo.claim_next_job()

    assert repo.requeue_running_jobs() == 1

    reclaimed = repo.claim_next_job()
    assert reclaimed is not None
    assert reclaimed.id == job.id
    assert reclaimed.attempts == 2


def test_replace_learning_content_sets_ready_and_assigns_chapters(repo):
    episode_id = _seed_episode(repo)
    chapters = [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 1000}]
    sentences = [
        {"start_ms": 0, "end_ms": 500, "speaker": None, "source_text": "Hi", "chinese": "嗨"},
        {"start_ms": 500, "end_ms": 1000, "speaker": None, "source_text": "Bye", "chinese": "拜"},
    ]
    repo.replace_learning_content(episode_id, chapters, sentences)
    stored = repo.list_sentences(episode_id)
    assert [s.position for s in stored] == [0, 1]
    assert all(s.chapter_id is not None for s in stored)
    assert repo.get_episode(episode_id).status == "ready"
    assert len(repo.list_chapters(episode_id)) == 1


def test_replace_learning_content_ignores_unknown_expression_fields(repo):
    """An extra key from the model must not fail the whole import."""
    episode_id = _seed_episode(repo)
    repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 1000}],
        [{"start_ms": 0, "end_ms": 500, "speaker": None, "source_text": "Hi there", "chinese": "嗨"}],
        [{
            "text": "Hi there",
            "kind": "phrase",
            "chinese": "你好",
            "pronunciation": None,
            "example": "Hi there.",
            "example_chinese": "你好。",
            "confidence": 0.9,  # not a column
            "occurrences": [{"sentence_position": 0, "start_offset": 0, "end_offset": 8}],
        }],
    )

    expressions = repo.list_learning_expressions(episode_id)
    assert [item.text for item in expressions] == ["Hi there"]
    assert len(expressions[0].occurrences) == 1


def test_replace_learning_content_locates_the_expression_itself(repo):
    """Model-counted offsets are wrong ~97% of the time, so they are recomputed.

    The offsets below are plausible (in range, start < end) but point at the wrong
    words, which is exactly why the old range-only check let them through.
    """
    episode_id = _seed_episode(repo)
    host = "Okay, Patrick. Thanks so much for being here."
    repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 1000}],
        [{"start_ms": 0, "end_ms": 500, "speaker": None, "source_text": host, "chinese": "嗨"}],
        [{
            "text": "Thanks so much",
            "kind": "phrase",
            "chinese": "非常感谢",
            "pronunciation": None,
            "example": host,
            "example_chinese": "非常感谢。",
            # Points at "Okay, Patrick" — the real failure seen in production.
            "occurrences": [{"sentence_position": 0, "start_offset": 0, "end_offset": 13}],
        }],
    )

    occurrences = repo.list_learning_expressions(episode_id)[0].occurrences
    assert len(occurrences) == 1
    found = occurrences[0]
    assert host[found.start_offset:found.end_offset] == "Thanks so much"


def test_replace_learning_content_drops_an_expression_absent_from_its_sentence(repo):
    """An invented expression cannot be highlighted, so it stores no occurrence."""
    episode_id = _seed_episode(repo)
    repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 1000}],
        [{"start_ms": 0, "end_ms": 500, "speaker": None, "source_text": "Hello world.", "chinese": "嗨"}],
        [{
            "text": "never said this",
            "kind": "phrase",
            "chinese": "没说过",
            "pronunciation": None,
            "example": "n/a",
            "example_chinese": "无",
            "occurrences": [{"sentence_position": 0, "start_offset": 0, "end_offset": 5}],
        }],
    )

    expressions = repo.list_learning_expressions(episode_id)
    assert [item.text for item in expressions] == ["never said this"]
    assert expressions[0].occurrences == []


def test_replace_learning_content_matches_ignoring_case_and_spacing(repo):
    episode_id = _seed_episode(repo)
    host = "We  should  transcend the plane of instructions."
    repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 1000}],
        [{"start_ms": 0, "end_ms": 500, "speaker": None, "source_text": host, "chinese": "嗨"}],
        [{
            "text": "Transcend  The Plane",
            "kind": "phrase",
            "chinese": "超越层面",
            "pronunciation": None,
            "example": host,
            "example_chinese": "超越层面。",
            "occurrences": [{"sentence_position": 0, "start_offset": 99, "end_offset": 200}],
        }],
    )

    occurrences = repo.list_learning_expressions(episode_id)[0].occurrences
    assert len(occurrences) == 1
    assert host[occurrences[0].start_offset:occurrences[0].end_offset] == "transcend the plane"


def test_replace_learning_content_locates_an_inflected_form(repo):
    """"work out" is spoken as "worked out", and that occurrence still counts."""
    episode_id = _seed_episode(repo)
    host = "We worked out a solution."
    repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 1000}],
        [{"start_ms": 0, "end_ms": 500, "speaker": None, "source_text": host, "chinese": "嗨"}],
        [{
            "text": "work out",
            "kind": "phrase",
            "chinese": "想出",
            "pronunciation": None,
            "example": host,
            "example_chinese": "我们想出了解决方案。",
            "occurrences": [{"sentence_position": 0, "start_offset": 0, "end_offset": 8}],
        }],
    )

    occurrences = repo.list_learning_expressions(episode_id)[0].occurrences
    assert len(occurrences) == 1
    assert host[occurrences[0].start_offset:occurrences[0].end_offset] == "worked out"


def test_replace_learning_content_does_not_match_a_longer_unrelated_word(repo):
    """Allowing a suffix must not let "work" match "network" or "out" match "outside"."""
    episode_id = _seed_episode(repo)
    repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 1000}],
        [{"start_ms": 0, "end_ms": 500, "speaker": None, "source_text": "The network outside failed.", "chinese": "嗨"}],
        [{
            "text": "work out",
            "kind": "phrase",
            "chinese": "想出",
            "pronunciation": None,
            "example": "n/a",
            "example_chinese": "无",
            "occurrences": [{"sentence_position": 0, "start_offset": 0, "end_offset": 8}],
        }],
    )

    assert repo.list_learning_expressions(episode_id)[0].occurrences == []


def test_replace_learning_content_normalizes_expression_kind(repo):
    """The iOS enum only accepts word/phrase/pattern, so nothing else may be stored."""
    episode_id = _seed_episode(repo)
    kinds = ["phrasal verb", "collocation", "transferable sentence pattern", "ACRONYM", "banana"]
    repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 1000}],
        [{"start_ms": 0, "end_ms": 500, "speaker": None, "source_text": "Hi there", "chinese": "嗨"}],
        [
            {
                "text": f"expr {index}",
                "kind": kind,
                "chinese": "中",
                "pronunciation": None,
                "example": "e",
                "example_chinese": "例",
                "occurrences": [],
            }
            for index, kind in enumerate(kinds)
        ],
    )

    stored = [item.kind for item in repo.list_learning_expressions(episode_id)]
    assert stored == ["phrase", "phrase", "pattern", "word", "phrase"]


def test_clear_learning_content_removes_chapters_and_sentences(repo):
    episode_id = _seed_episode(repo)
    repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 1000}],
        [{"start_ms": 0, "end_ms": 500, "speaker": None, "source_text": "Hi", "chinese": "嗨"}],
    )

    repo.clear_learning_content(episode_id)

    assert repo.list_chapters(episode_id) == []
    assert repo.list_sentences(episode_id) == []


def test_set_audio_path(repo):
    episode_id = _seed_episode(repo)
    repo.set_audio_path(episode_id, "episodes/1/source.mp3")
    assert repo.get_episode(episode_id).audio_path == "episodes/1/source.mp3"


def test_get_missing_episode_raises(repo):
    with pytest.raises(LookupError):
        repo.get_episode(999)
