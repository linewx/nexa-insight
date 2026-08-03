from collections.abc import Iterator
from contextlib import contextmanager

from sqlalchemy import create_engine, select
from sqlalchemy import text
from sqlalchemy.orm import Session, sessionmaker

from .models import Base, Chapter, Episode, ExpressionOccurrence, ImportChunk, ImportJob, LearningExpression, Sentence
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

    def list_learning_expressions(self, episode_id: int) -> list[LearningExpression]:
        with self.session() as session:
            rows = list(session.scalars(
                select(LearningExpression).where(LearningExpression.episode_id == episode_id).order_by(LearningExpression.id)
            ))
            for row in rows:
                for occurrence in row.occurrences:
                    occurrence.sentence
            return rows

    def has_learning_content(self, episode_id: int) -> bool:
        with self.session() as session:
            return session.scalar(select(Sentence.id).where(Sentence.episode_id == episode_id).limit(1)) is not None

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

    def requeue_running_jobs(self) -> int:
        with self.session() as session:
            jobs = list(session.scalars(select(ImportJob).where(ImportJob.status == "running")))
            for job in jobs:
                job.status = "queued"
            session.commit()
            return len(jobs)

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

    def clear_learning_content(self, episode_id: int) -> None:
        with self.session() as session:
            session.query(Sentence).filter_by(episode_id=episode_id).delete()
            session.query(Chapter).filter_by(episode_id=episode_id).delete()
            session.commit()

    def replace_learning_content(self, episode_id: int, chapters: list[dict], sentences: list[dict], learning_expressions: list[dict] | None = None) -> None:
        with self.session() as session:
            session.query(ExpressionOccurrence).filter(ExpressionOccurrence.expression_id.in_(select(LearningExpression.id).where(LearningExpression.episode_id == episode_id))).delete(synchronize_session=False)
            session.query(LearningExpression).filter_by(episode_id=episode_id).delete()
            session.query(Sentence).filter_by(episode_id=episode_id).delete()
            session.query(Chapter).filter_by(episode_id=episode_id).delete()
            chapter_rows: list[Chapter] = []
            for item in chapters:
                chapter = Chapter(episode_id=episode_id, **item)
                session.add(chapter)
                chapter_rows.append(chapter)
            session.flush()
            sentence_rows: list[Sentence] = []
            for position, item in enumerate(sentences):
                chapter = next((c for c in chapter_rows if c.start_ms <= item["start_ms"] < c.end_ms), None)
                sentence = Sentence(episode_id=episode_id, chapter_id=chapter.id if chapter else None, position=position, **item)
                session.add(sentence)
                sentence_rows.append(sentence)
            session.flush()
            expressions_by_text: dict[str, LearningExpression] = {}
            stored_occurrences: dict[str, set[tuple[int, int, int]]] = {}
            for item in learning_expressions or []:
                expression_data = dict(item)
                occurrences = expression_data.pop("occurrences", [])
                normalized_text = " ".join(expression_data["text"].casefold().split())
                expression = expressions_by_text.get(normalized_text)
                if expression is None:
                    expression = LearningExpression(episode_id=episode_id, **expression_data)
                    session.add(expression)
                    session.flush()
                    expressions_by_text[normalized_text] = expression
                    stored_occurrences[normalized_text] = set()
                for occurrence in occurrences:
                    position = occurrence["sentence_position"]
                    if not 0 <= position < len(sentence_rows):
                        continue
                    sentence = sentence_rows[position]
                    start, end = occurrence["start_offset"], occurrence["end_offset"]
                    if not 0 <= start < end <= len(sentence.source_text):
                        continue
                    occurrence_key = (sentence.id, start, end)
                    if occurrence_key in stored_occurrences[normalized_text]:
                        continue
                    stored_occurrences[normalized_text].add(occurrence_key)
                    session.add(ExpressionOccurrence(expression_id=expression.id, sentence_id=sentence.id, start_offset=start, end_offset=end))
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
