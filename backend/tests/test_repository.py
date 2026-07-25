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


def test_set_audio_path(repo):
    episode_id = _seed_episode(repo)
    repo.set_audio_path(episode_id, "episodes/1/source.mp3")
    assert repo.get_episode(episode_id).audio_path == "episodes/1/source.mp3"


def test_get_missing_episode_raises(repo):
    with pytest.raises(LookupError):
        repo.get_episode(999)
