from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


class Episode(Base):
    __tablename__ = "episodes"

    id: Mapped[int] = mapped_column(primary_key=True)
    source_url: Mapped[str] = mapped_column(String(1000), unique=True)
    youtube_id: Mapped[str | None] = mapped_column(String(32))
    title: Mapped[str | None] = mapped_column(String(500))
    channel: Mapped[str | None] = mapped_column(String(300))
    duration_ms: Mapped[int | None] = mapped_column(Integer)
    thumbnail_url: Mapped[str | None] = mapped_column(String(1000))
    audio_path: Mapped[str | None] = mapped_column(String(1000))
    stream_url: Mapped[str | None] = mapped_column(Text)
    stream_url_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    status: Mapped[str] = mapped_column(String(32), default="queued")
    error: Mapped[str | None] = mapped_column(Text)
    # "native" (made for native speakers) or "teaching" (an English lesson).
    # Decides which extraction strategy runs, since the two serve different goals.
    material_kind: Mapped[str | None] = mapped_column(String(16))
    # The 洞察 page's content, as JSON. One column rather than five tables: it is written whole,
    # read whole, and never queried by its parts — a thesis, its claims, the facts worth keeping,
    # what follows from them, and where to listen.
    insight_json: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)

    chapters: Mapped[list[Chapter]] = relationship(cascade="all, delete-orphan")
    sentences: Mapped[list[Sentence]] = relationship(cascade="all, delete-orphan")
    jobs: Mapped[list[ImportJob]] = relationship(cascade="all, delete-orphan")
    learning_expressions: Mapped[list[LearningExpression]] = relationship(cascade="all, delete-orphan")


class ImportJob(Base):
    __tablename__ = "import_jobs"

    id: Mapped[int] = mapped_column(primary_key=True)
    episode_id: Mapped[int] = mapped_column(ForeignKey("episodes.id", ondelete="CASCADE"), index=True)
    stage: Mapped[str] = mapped_column(String(32), default="metadata")
    status: Mapped[str] = mapped_column(String(32), default="queued")
    progress: Mapped[int] = mapped_column(Integer, default=0)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now, onupdate=utc_now)


class ImportChunk(Base):
    __tablename__ = "import_chunks"

    id: Mapped[int] = mapped_column(primary_key=True)
    job_id: Mapped[int] = mapped_column(ForeignKey("import_jobs.id", ondelete="CASCADE"), index=True)
    position: Mapped[int] = mapped_column(Integer)
    start_ms: Mapped[int] = mapped_column(Integer)
    end_ms: Mapped[int] = mapped_column(Integer)
    path: Mapped[str] = mapped_column(String(1000))
    status: Mapped[str] = mapped_column(String(32), default="queued")
    transcript_json: Mapped[str | None] = mapped_column(Text)
    error: Mapped[str | None] = mapped_column(Text)


class Chapter(Base):
    __tablename__ = "chapters"

    id: Mapped[int] = mapped_column(primary_key=True)
    episode_id: Mapped[int] = mapped_column(ForeignKey("episodes.id", ondelete="CASCADE"), index=True)
    title: Mapped[str] = mapped_column(String(300))
    summary: Mapped[str] = mapped_column(Text, default="")
    start_ms: Mapped[int] = mapped_column(Integer)
    end_ms: Mapped[int] = mapped_column(Integer)


class Sentence(Base):
    __tablename__ = "sentences"

    id: Mapped[int] = mapped_column(primary_key=True)
    episode_id: Mapped[int] = mapped_column(ForeignKey("episodes.id", ondelete="CASCADE"), index=True)
    chapter_id: Mapped[int | None] = mapped_column(ForeignKey("chapters.id", ondelete="SET NULL"), index=True)
    position: Mapped[int] = mapped_column(Integer)
    start_ms: Mapped[int] = mapped_column(Integer, index=True)
    end_ms: Mapped[int] = mapped_column(Integer)
    speaker: Mapped[str | None] = mapped_column(String(100))
    source_text: Mapped[str] = mapped_column(Text)
    chinese: Mapped[str] = mapped_column(Text)


class LearningExpression(Base):
    __tablename__ = "learning_expressions"

    id: Mapped[int] = mapped_column(primary_key=True)
    episode_id: Mapped[int] = mapped_column(ForeignKey("episodes.id", ondelete="CASCADE"), index=True)
    text: Mapped[str] = mapped_column(String(500))
    kind: Mapped[str] = mapped_column(String(32))
    # One of the eight extraction types. `kind` stays for the older three-value
    # client contract; `type` carries the real granularity.
    type: Mapped[str | None] = mapped_column(String(32))
    chinese: Mapped[str] = mapped_column(Text)
    pronunciation: Mapped[str | None] = mapped_column(String(500))
    example: Mapped[str] = mapped_column(Text)
    example_chinese: Mapped[str] = mapped_column(Text)
    # Native-speed material: the sound actually produced ("kinda"), and the full
    # form a learner needs restored to parse the line.
    heard_as: Mapped[str | None] = mapped_column(String(500))
    restored: Mapped[str | None] = mapped_column(Text)
    why_hard: Mapped[str | None] = mapped_column(Text)
    # Teaching material: the situation that calls for it, and the Chinese-English
    # attempt it replaces.
    when_to_use: Mapped[str | None] = mapped_column(Text)
    common_mistake: Mapped[str | None] = mapped_column(Text)
    formality: Mapped[str | None] = mapped_column(String(16))
    # "auto" for batch extraction, "manual" for one the learner asked for. A
    # reprocess replaces everything it produced, so without this a re-parse would
    # also delete the notes the learner made by hand — the one kind of row here
    # that cannot be regenerated.
    source: Mapped[str] = mapped_column(String(16), default="auto", server_default="auto")
    # What the learner asked for, when they asked for something specific
    # ("只讲时态"). Kept so a note can say why it looks the way it does.
    request: Mapped[str | None] = mapped_column(Text)
    occurrences: Mapped[list[ExpressionOccurrence]] = relationship(cascade="all, delete-orphan", order_by="ExpressionOccurrence.id")


class ExpressionOccurrence(Base):
    __tablename__ = "expression_occurrences"

    id: Mapped[int] = mapped_column(primary_key=True)
    expression_id: Mapped[int] = mapped_column(ForeignKey("learning_expressions.id", ondelete="CASCADE"), index=True)
    sentence_id: Mapped[int] = mapped_column(ForeignKey("sentences.id", ondelete="CASCADE"), index=True)
    start_offset: Mapped[int] = mapped_column(Integer)
    end_offset: Mapped[int] = mapped_column(Integer)
    sentence: Mapped[Sentence] = relationship()
