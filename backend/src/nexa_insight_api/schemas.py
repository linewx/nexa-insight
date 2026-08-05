from datetime import datetime

from pydantic import BaseModel, ConfigDict


class ORMModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


class ImportRequest(BaseModel):
    url: str


class EpisodeView(ORMModel):
    id: int
    source_url: str
    youtube_id: str | None
    title: str | None
    channel: str | None
    duration_ms: int | None
    thumbnail_url: str | None
    audio_path: str | None
    stream_url: str | None
    stream_url_expires_at: datetime | None
    status: str
    error: str | None
    material_kind: str | None = None
    created_at: datetime


class JobView(ORMModel):
    id: int
    episode_id: int
    stage: str
    status: str
    progress: int
    attempts: int
    error: str | None


class ImportView(BaseModel):
    episode: EpisodeView
    job: JobView


class ChapterView(ORMModel):
    id: int
    title: str
    summary: str
    start_ms: int
    end_ms: int


class SentenceView(ORMModel):
    id: int
    episode_id: int
    chapter_id: int | None
    position: int
    start_ms: int
    end_ms: int
    speaker: str | None
    source_text: str
    chinese: str


class ExpressionOccurrenceView(ORMModel):
    sentence_id: int
    start_offset: int
    end_offset: int


class LearningExpressionView(ORMModel):
    id: int
    text: str
    kind: str
    type: str | None = None
    chinese: str
    pronunciation: str | None
    example: str
    example_chinese: str
    heard_as: str | None = None
    restored: str | None = None
    why_hard: str | None = None
    when_to_use: str | None = None
    common_mistake: str | None = None
    formality: str | None = None
    # "auto" or "manual". The client needs it to know which rows it may drop when
    # a bundle arrives, and to mark a note as the learner's own.
    source: str = "auto"
    request: str | None = None
    occurrences: list[ExpressionOccurrenceView]


class EpisodeBundle(BaseModel):
    episode: EpisodeView
    chapters: list[ChapterView]
    sentences: list[SentenceView]
    has_audio: bool
    has_stream: bool
    has_learning_pack: bool = False
    learning_expressions: list[LearningExpressionView] = []
