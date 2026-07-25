from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from nexa_insight_api.models import Base, Chapter, Episode, ImportChunk, ImportJob, Sentence


def make_session() -> Session:
    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)
    return Session(engine)


def test_episode_relations_cascade():
    session = make_session()
    episode = Episode(source_url="https://youtu.be/abc", youtube_id="abcdefghijk", status="queued")
    session.add(episode)
    session.flush()
    session.add(ImportJob(episode_id=episode.id))
    session.add(Chapter(episode_id=episode.id, title="c", summary="s", start_ms=0, end_ms=1000))
    session.add(Sentence(episode_id=episode.id, position=0, start_ms=0, end_ms=500, source_text="Hi", chinese="嗨"))
    session.commit()
    assert len(episode.jobs) == 1
    assert len(episode.chapters) == 1
    assert len(episode.sentences) == 1


def test_no_tutor_tables_exist():
    # The trimmed backend must not carry class/discussion/shadowing tables.
    assert "class_sessions" not in Base.metadata.tables
    assert "discussions" not in Base.metadata.tables
    assert "shadowing_recordings" not in Base.metadata.tables
