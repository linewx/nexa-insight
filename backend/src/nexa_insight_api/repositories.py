import re
from collections.abc import Iterator
from contextlib import contextmanager

from sqlalchemy import create_engine, select
from sqlalchemy import text
from sqlalchemy.orm import Session, sessionmaker

from .models import Base, Chapter, Episode, ExpressionOccurrence, ImportChunk, ImportJob, LearningExpression, Sentence
from .settings import Settings

EXPRESSION_FIELDS = (
    "text", "kind", "type", "chinese", "pronunciation", "example", "example_chinese",
    "heard_as", "restored", "why_hard", "when_to_use", "common_mistake", "formality",
)

# The iOS LearningExpressionKind enum decodes exactly these three, and one
# unknown value fails the whole bundle decode, so the column is narrowed here.
EXPRESSION_KINDS = ("word", "phrase", "pattern")

# Native-speed material is mined for what defeats comprehension; teaching
# material for what the learner should be able to say.
NATIVE_TYPES = ("reduction", "ellipsis", "syntax", "idiom", "reference")
TEACHING_TYPES = ("phrase", "pattern", "collocation")
EXPRESSION_TYPES = (*NATIVE_TYPES, *TEACHING_TYPES, "word", "chunk")


# A studiable item is short enough to carry into another sentence. Beyond this the
# model is quoting the transcript: the teaching prompt returned 28% items of six
# words or more, up to an 18-word sentence, each with a fine gloss and nothing
# reusable. Slotted patterns are exempt — a frame is reusable however long it is.
MAX_EXPRESSION_WORDS = 6


def is_studiable_expression(text: str, type_value: str) -> bool:
    if type_value == "pattern" and "{" in text:
        return True
    return len(text.split()) <= MAX_EXPRESSION_WORDS


def normalize_pronunciation(value: object) -> str | None:
    """Coerce IPA into one string, or nothing.

    qwen-plus returns per-word IPA as a list (["riːl", "tɔːk"]), which SQLite
    refuses to bind — it failed the insert outright. It also sometimes wraps the
    value in slashes, which the card adds itself.
    """
    if isinstance(value, list):
        value = " ".join(str(part) for part in value if part)
    if not isinstance(value, str):
        return None
    text = value.strip().strip("/").strip()
    return text or None


def normalize_expression_type(value: object) -> str:
    """Keep `type` inside the known set, defaulting to the safest label."""
    if not isinstance(value, str):
        return "phrase"
    text = value.strip().casefold().replace("-", " ").replace("_", " ")
    if text in EXPRESSION_TYPES:
        return text
    for known in EXPRESSION_TYPES:
        if known in text:
            return known
    return "phrase"


def locate_expression(text_value: str, host: str) -> tuple[int, int] | None:
    """Find where an expression really sits in its sentence.

    The model reports start/end offsets by counting characters itself, and it is
    wrong about 97% of the time — plausibly wrong, so a range check passes and the
    highlight lands on unrelated words ("Thanks so much" highlighting "Okay,
    Patrick"). Searching for the text is the only way to be right, and returning
    None when it is absent means an invented expression simply gets no highlight
    instead of a misleading one.

    Matching ignores case and treats any run of whitespace as equivalent, because
    transcripts carry double spaces the model silently normalizes. Each word may
    also carry a suffix, so the lemma "work out" still finds "worked out" — the
    form actually spoken. The lookarounds keep that from reaching inside a longer
    word, which would otherwise let "work out" match "network outside".
    """
    if not text_value or not host:
        return None
    words = text_value.split()
    if not words:
        return None
    pattern = r"(?<!\w)" + r"\s+".join(re.escape(word) + r"\w*" for word in words)
    match = re.search(pattern, host, flags=re.IGNORECASE)
    return (match.start(), match.end()) if match else None


def normalize_expression_kind(value: object) -> str:
    """Map whatever the model called this onto a kind the client can decode.

    Asking for "word, phrase, or pattern" in the prompt is not binding: real
    imports produced 19 distinct kinds, including "phrasal verb" and
    "compound noun (YC term)". Anything unrecognized becomes "phrase", the
    safest label for a multi-word expression.
    """
    if not isinstance(value, str):
        return "phrase"
    text = value.strip().casefold()
    if text in EXPRESSION_KINDS:
        return text
    if "pattern" in text:
        return "pattern"
    if "word" in text or "acronym" in text:
        return "word"
    return "phrase"


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
        self._ensure_study_columns()

    def _ensure_episode_stream_columns(self) -> None:
        if self.engine.dialect.name != "sqlite":
            return
        with self.engine.begin() as connection:
            columns = {row[1] for row in connection.execute(text("PRAGMA table_info(episodes)"))}
            if "stream_url" not in columns:
                connection.execute(text("ALTER TABLE episodes ADD COLUMN stream_url TEXT"))
            if "stream_url_expires_at" not in columns:
                connection.execute(text("ALTER TABLE episodes ADD COLUMN stream_url_expires_at DATETIME"))

    def _ensure_study_columns(self) -> None:
        """Add the columns the richer cards need, on an existing database.

        All nullable, so old rows stay valid — they simply carry no explanation,
        which is what a re-import fixes. Values are model-generated and cannot be
        back-computed.
        """
        if self.engine.dialect.name != "sqlite":
            return
        additions = {
            "episodes": {"material_kind": "VARCHAR(16)"},
            "learning_expressions": {
                "type": "VARCHAR(32)",
                "heard_as": "VARCHAR(500)",
                "restored": "TEXT",
                "why_hard": "TEXT",
                "when_to_use": "TEXT",
                "common_mistake": "TEXT",
                "formality": "VARCHAR(16)",
            },
        }
        with self.engine.begin() as connection:
            for table, columns in additions.items():
                existing = {row[1] for row in connection.execute(text(f"PRAGMA table_info({table})"))}
                for column, ddl in columns.items():
                    if column not in existing:
                        connection.execute(text(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}"))

    def set_material_kind(self, episode_id: int, material_kind: str) -> None:
        with self.session() as session:
            episode = session.get(Episode, episode_id)
            if episode is None:
                raise LookupError("Episode not found")
            episode.material_kind = material_kind
            session.commit()

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
                occurrences = item.get("occurrences", [])
                # The model invents extra keys ("confidence", "difficulty"), and
                # one of those reaching the constructor fails the whole import.
                expression_data = {key: item[key] for key in EXPRESSION_FIELDS if key in item}
                if not isinstance(expression_data.get("text"), str) or not expression_data["text"].strip():
                    continue
                # The new prompts return `type`; `kind` is derived from it so the
                # non-nullable column and the older client contract both hold.
                expression_data["pronunciation"] = normalize_pronunciation(expression_data.get("pronunciation"))
                expression_data["type"] = normalize_expression_type(expression_data.get("type"))
                # A pattern is a frame with slots. The model routinely labels whole
                # quoted sentences as patterns, which teaches nothing reusable, so
                # one without slots is recorded as the phrase it actually is.
                if expression_data["type"] == "pattern" and "{" not in expression_data["text"]:
                    expression_data["type"] = "phrase"
                if not is_studiable_expression(expression_data["text"], expression_data["type"]):
                    continue
                expression_data["kind"] = normalize_expression_kind(
                    expression_data.get("kind") or expression_data["type"]
                )
                normalized_text = " ".join(expression_data["text"].casefold().split())
                expression = expressions_by_text.get(normalized_text)
                if expression is None:
                    expression = LearningExpression(episode_id=episode_id, **expression_data)
                    session.add(expression)
                    session.flush()
                    expressions_by_text[normalized_text] = expression
                    stored_occurrences[normalized_text] = set()
                for occurrence in occurrences:
                    try:
                        position = int(occurrence["sentence_position"])
                    except (KeyError, TypeError, ValueError):
                        continue
                    if not 0 <= position < len(sentence_rows):
                        continue
                    sentence = sentence_rows[position]
                    # The reported offsets are discarded; only the sentence index
                    # is trusted, and even that is checked by whether the text is
                    # actually there.
                    located = locate_expression(expression_data["text"], sentence.source_text)
                    if located is None:
                        continue
                    start, end = located
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
