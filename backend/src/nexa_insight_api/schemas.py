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


class EpisodeBundle(BaseModel):
    episode: EpisodeView
    chapters: list[ChapterView]
    sentences: list[SentenceView]
    has_audio: bool
    has_stream: bool
