from collections.abc import Iterator
from contextlib import contextmanager

from sqlalchemy import create_engine, select
from sqlalchemy import text
from sqlalchemy.orm import Session, sessionmaker

from .models import Base, Chapter, Episode, ImportChunk, ImportJob, Sentence
from .settings import Settings


class Repository:
    def __init__(self, database_url: str):
        connect_args = {"check_same_thread": False} if database_url.startswith("sqlite") else {}
        self.engine = create_engine(database_url, connect_args=connect_args)
        self._sessions = sessionmaker(self.engine, expire_on_commit=False)

    @classmethod
    def from_settings(cls, settings: Settings) -> "Repository":
        return cls(settings.database_url)

    def create_schema(self) -> None:
        Base.metadata.create_all(self.engine)
        self._ensure_episode_stream_columns()

    def _ensure_episode_stream_columns(self) -> None:
        if self.engine.dialect.name != "sqlite":
            return
        with self.engine.begin() as connection:
            columns = {row[1] for row in connection.execute(text("PRAGMA table_info(episodes)"))}
            if "stream_url" not in columns:
                connection.execute(text("ALTER TABLE episodes ADD COLUMN stream_url TEXT"))
            if "stream_url_expires_at" not in columns:
                connection.execute(text("ALTER TABLE episodes ADD COLUMN stream_url_expires_at DATETIME"))

    @contextmanager
    def session(self) -> Iterator[Session]:
        session = self._sessions()
        try:
            yield session
        finally:
            session.close()

    def get_episode(self, episode_id: int) -> Episode:
        with self.session() as session:
            episode = session.get(Episode, episode_id)
            if episode is None:
                raise LookupError("Episode not found")
            session.expunge(episode)
            return episode

    def get_job(self, job_id: int) -> ImportJob:
        with self.session() as session:
            job = session.get(ImportJob, job_id)
            if job is None:
                raise LookupError("Job not found")
            session.expunge(job)
            return job

    def list_sentences(self, episode_id: int) -> list[Sentence]:
        with self.session() as session:
            return list(session.scalars(
                select(Sentence).where(Sentence.episode_id == episode_id).order_by(Sentence.position)
            ))

    def list_chapters(self, episode_id: int) -> list[Chapter]:
        with self.session() as session:
            return list(session.scalars(
                select(Chapter).where(Chapter.episode_id == episode_id).order_by(Chapter.start_ms)
            ))

    def upsert_job(self, job_id: int, *, stage: str, progress: int, status: str = "running", error: str | None = None) -> None:
        with self.session() as session:
            job = session.get(ImportJob, job_id)
            if job is None:
                raise LookupError("Job not found")
            job.stage, job.progress, job.status, job.error = stage, progress, status, error
            session.commit()

    def fail_episode(self, episode_id: int, error: str) -> None:
        with self.session() as session:
            episode = session.get(Episode, episode_id)
            if episode is None:
                raise LookupError("Episode not found")
            episode.status = "failed"
            episode.error = error
            session.commit()

    def claim_next_job(self) -> ImportJob | None:
        with self.session() as session:
            job = session.scalar(
                select(ImportJob).where(ImportJob.status == "queued").order_by(ImportJob.created_at, ImportJob.id).limit(1)
            )
            if job is None:
                return None
            job.status = "running"
            job.attempts += 1
            session.commit()
            session.expunge(job)
            return job

    def completed_chunks(self, job_id: int) -> dict[int, ImportChunk]:
        with self.session() as session:
            chunks = session.scalars(
                select(ImportChunk).where(ImportChunk.job_id == job_id, ImportChunk.status == "complete")
            )
            return {chunk.position: chunk for chunk in chunks}

    def save_chunk(self, job_id: int, position: int, start_ms: int, end_ms: int, path: str, transcript_json: str) -> None:
        with self.session() as session:
            chunk = session.scalar(
                select(ImportChunk).where(ImportChunk.job_id == job_id, ImportChunk.position == position)
            )
            if chunk is None:
                chunk = ImportChunk(job_id=job_id, position=position, start_ms=start_ms, end_ms=end_ms, path=path)
                session.add(chunk)
            chunk.status, chunk.transcript_json = "complete", transcript_json
            session.commit()

    def replace_learning_content(self, episode_id: int, chapters: list[dict], sentences: list[dict]) -> None:
        with self.session() as session:
            session.query(Sentence).filter_by(episode_id=episode_id).delete()
            session.query(Chapter).filter_by(episode_id=episode_id).delete()
            chapter_rows: list[Chapter] = []
            for item in chapters:
                chapter = Chapter(episode_id=episode_id, **item)
                session.add(chapter)
                chapter_rows.append(chapter)
            session.flush()
            for position, item in enumerate(sentences):
                chapter = next((c for c in chapter_rows if c.start_ms <= item["start_ms"] < c.end_ms), None)
                session.add(Sentence(episode_id=episode_id, chapter_id=chapter.id if chapter else None, position=position, **item))
            episode = session.get(Episode, episode_id)
            episode.status = "ready"
            session.commit()

    def set_audio_path(self, episode_id: int, path: str) -> None:
        with self.session() as session:
            episode = session.get(Episode, episode_id)
            if episode is None:
                raise LookupError("Episode not found")
            episode.audio_path = path
            session.commit()

    def set_stream_url(self, episode_id: int, url: str | None, expires_at) -> None:
        with self.session() as session:
            episode = session.get(Episode, episode_id)
            if episode is None:
                raise LookupError("Episode not found")
            episode.stream_url = url
            episode.stream_url_expires_at = expires_at
            session.commit()
