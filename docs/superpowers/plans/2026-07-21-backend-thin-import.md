# Thin Import Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A self-contained thin Python backend under `nexa_insight_ios/backend/` that imports a YouTube URL, transcribes/translates/chapters it, and serves the packaged episode (mp3 + bilingual sentences JSON) for an iOS app to download.

**Architecture:** Copy and trim the proven import pipeline from `nexa_insight` (yt-dlp download, caption scraping, ffmpeg splitting, transcription, batched translation, chaptering). Keep the async worker + job-polling model. Drop everything about the tutor, discussions, class sessions, shadowing, and the SDP proxy. Add two new download endpoints (`/bundle`, `/audio`) so the phone pulls a whole episode in one request plus the audio file.

**Tech Stack:** Python 3.12+, FastAPI, SQLAlchemy 2.x, SQLite, Pydantic Settings, OpenAI SDK, `yt-dlp`, `ffmpeg`, pytest + pytest-asyncio.

This is Plan 1 of 3. Plans 2 (iOS foundation + study) and 3 (iOS voice classroom) build on the episode bundle format this plan defines.

## Global Constraints

- Python `>=3.12`. Package the app under `backend/src/nexa_insight_api/`.
- Runtime deps pinned to the original ranges: `fastapi>=0.116,<1`, `httpx>=0.28,<1`, `openai>=1.99,<2`, `pydantic-settings>=2.10,<3`, `sqlalchemy>=2.0,<3`, `uvicorn[standard]>=0.35,<1`. Dev: `pytest>=8.4,<9`, `pytest-asyncio>=1.1,<2`.
- Env prefix for settings is `NEXA_INSIGHT_` (distinct from the original `NEXA_INSIGHT_` so both projects can run side-by-side without env collisions).
- Audio output format is **mp3** (iOS `AVPlayer` plays it natively; no transcoding).
- This project must NOT import from, or write into, the sibling `nexa_insight/` directory. All reused code is copied in, then trimmed.
- Data (SQLite db + episode files) lives under `backend/data/` by default and is git-ignored.
- Do NOT port: `Discussion`, `DiscussionTurn`, `ClassSession`, `ClassEvent`, `ShadowingRecording`, `realtime.py`, or any tutor/realtime/class/discussion endpoint.

---

### Task 1: Project scaffold and settings

**Files:**
- Create: `backend/pyproject.toml`
- Create: `backend/src/nexa_insight_api/__init__.py`
- Create: `backend/src/nexa_insight_api/settings.py`
- Create: `backend/.env.example`
- Create: `backend/tests/__init__.py`
- Create: `backend/tests/test_settings.py`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `Settings` class with attributes `database_url: str`, `data_dir: Path`, `openai_api_key: str`, `openai_base_url: str | None`, `transcription_model: str`, `text_model: str`. Env prefix `NEXA_INSIGHT_`, reads `backend/.env`.

- [ ] **Step 1: Write `backend/pyproject.toml`**

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "nexa-insight-api"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
  "fastapi>=0.116,<1",
  "httpx>=0.28,<1",
  "openai>=1.99,<2",
  "pydantic-settings>=2.10,<3",
  "python-multipart>=0.0.20,<1",
  "sqlalchemy>=2.0,<3",
  "uvicorn[standard]>=0.35,<1",
]

[project.optional-dependencies]
dev = [
  "pytest>=8.4,<9",
  "pytest-asyncio>=1.1,<2",
]

[tool.hatch.build.targets.wheel]
packages = ["src/nexa_insight_api"]

[tool.pytest.ini_options]
pythonpath = ["src"]
testpaths = ["tests"]
```

- [ ] **Step 2: Create empty `backend/src/nexa_insight_api/__init__.py` and `backend/tests/__init__.py`**

Both files are empty.

- [ ] **Step 3: Write the failing test `backend/tests/test_settings.py`**

```python
from pathlib import Path

from nexa_insight_api.settings import Settings


def test_settings_have_ios_env_prefix_and_defaults(monkeypatch):
    monkeypatch.setenv("NEXA_INSIGHT_OPENAI_API_KEY", "sk-test")
    settings = Settings(_env_file=None)
    assert settings.openai_api_key == "sk-test"
    assert settings.transcription_model == "gpt-4o-transcribe"
    assert settings.text_model == "gpt-4.1-mini"
    assert isinstance(settings.data_dir, Path)
    assert settings.database_url.startswith("sqlite:///")
```

- [ ] **Step 4: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_settings.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'nexa_insight_api.settings'`

- [ ] **Step 5: Write `backend/src/nexa_insight_api/settings.py`**

```python
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file="backend/.env", env_prefix="NEXA_INSIGHT_")

    database_url: str = "sqlite:///backend/data/nexa_insight.db"
    data_dir: Path = Path("backend/data")
    openai_api_key: str = ""
    openai_base_url: str | None = None
    transcription_model: str = "gpt-4o-transcribe"
    text_model: str = "gpt-4.1-mini"
```

- [ ] **Step 6: Write `backend/.env.example`**

```
NEXA_INSIGHT_OPENAI_API_KEY=
# Optional: point at an OpenAI-compatible gateway
NEXA_INSIGHT_OPENAI_BASE_URL=
NEXA_INSIGHT_TRANSCRIPTION_MODEL=gpt-4o-transcribe
NEXA_INSIGHT_TEXT_MODEL=gpt-4.1-mini
```

- [ ] **Step 7: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_settings.py -v`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add backend/pyproject.toml backend/src/nexa_insight_api backend/tests backend/.env.example
git commit -m "feat(backend): project scaffold and settings"
```

---

### Task 2: Database models

**Files:**
- Create: `backend/src/nexa_insight_api/models.py`
- Create: `backend/tests/test_models.py`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: SQLAlchemy `Base` and models `Episode`, `ImportJob`, `ImportChunk`, `Chapter`, `Sentence`. Field shapes match the original project exactly (see below) so the pipeline copies cleanly. `Episode.audio_path`, `Episode.status`, `Episode.error` present. NO `ShadowingRecording`, `Discussion`, `DiscussionTurn`, `ClassSession`, `ClassEvent`.

- [ ] **Step 1: Write the failing test `backend/tests/test_models.py`**

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_models.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'nexa_insight_api.models'`

- [ ] **Step 3: Write `backend/src/nexa_insight_api/models.py`**

```python
from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import ForeignKey, Integer, String, Text
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
    status: Mapped[str] = mapped_column(String(32), default="queued")
    error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)

    chapters: Mapped[list[Chapter]] = relationship(cascade="all, delete-orphan")
    sentences: Mapped[list[Sentence]] = relationship(cascade="all, delete-orphan")
    jobs: Mapped[list[ImportJob]] = relationship(cascade="all, delete-orphan")


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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_models.py -v`
Expected: PASS (both tests)

- [ ] **Step 5: Commit**

```bash
git add backend/src/nexa_insight_api/models.py backend/tests/test_models.py
git commit -m "feat(backend): trimmed database models"
```

---

### Task 3: Repository

**Files:**
- Create: `backend/src/nexa_insight_api/repositories.py`
- Create: `backend/tests/conftest.py`
- Create: `backend/tests/test_repository.py`

**Interfaces:**
- Consumes: `Settings` (Task 1), models (Task 2).
- Produces: `Repository` class with methods:
  - `from_settings(settings) -> Repository` (classmethod)
  - `create_schema() -> None`
  - `session() -> contextmanager[Session]`
  - `get_episode(episode_id: int) -> Episode` (raises `LookupError`)
  - `get_job(job_id: int) -> ImportJob` (raises `LookupError`)
  - `list_sentences(episode_id: int) -> list[Sentence]`
  - `list_chapters(episode_id: int) -> list[Chapter]`
  - `upsert_job(job_id, *, stage, progress, status="running", error=None) -> None`
  - `fail_episode(episode_id: int, error: str) -> None`
  - `claim_next_job() -> ImportJob | None`
  - `completed_chunks(job_id: int) -> dict[int, ImportChunk]`
  - `save_chunk(job_id, position, start_ms, end_ms, path, transcript_json) -> None`
  - `replace_learning_content(episode_id, chapters: list[dict], sentences: list[dict]) -> None`
  - `set_audio_path(episode_id: int, path: str) -> None`
- Note: the original's `sentence_window` / `classroom_context` are NOT ported here — that logic moves to the iOS client (Plan 2). `list_chapters` and `set_audio_path` are new helpers this plan needs.

- [ ] **Step 1: Write `backend/tests/conftest.py`**

```python
import pytest

from nexa_insight_api.repositories import Repository


@pytest.fixture
def repo() -> Repository:
    repository = Repository("sqlite://")
    repository.create_schema()
    return repository
```

- [ ] **Step 2: Write the failing test `backend/tests/test_repository.py`**

```python
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_repository.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'nexa_insight_api.repositories'`

- [ ] **Step 4: Write `backend/src/nexa_insight_api/repositories.py`**

```python
from collections.abc import Iterator
from contextlib import contextmanager

from sqlalchemy import create_engine, select
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_repository.py -v`
Expected: PASS (all four tests)

- [ ] **Step 6: Commit**

```bash
git add backend/src/nexa_insight_api/repositories.py backend/tests/conftest.py backend/tests/test_repository.py
git commit -m "feat(backend): repository for episodes, jobs, chunks, content"
```

---

### Task 4: Import pipeline (copied and trimmed)

**Files:**
- Create: `backend/src/nexa_insight_api/pipeline.py`
- Create: `backend/tests/test_pipeline.py`

**Interfaces:**
- Consumes: `Repository` (Task 3), `Settings` (Task 1).
- Produces:
  - Dataclasses `MediaMetadata(youtube_id, title, channel, duration_ms, thumbnail_url)`, `TranscriptSegment(start_ms, end_ms, speaker, text)`.
  - Protocols `MediaAdapter` (`metadata`, `captions`, `download_audio`, `split_audio`) and `AIAdapter` (`transcribe`, `translate`, `chapters`).
  - `YtDlpMediaAdapter` and `OpenAIAdapter(settings)` concrete implementations.
  - `ImportPipeline(repo, settings, media, ai)` with `run(job_id: int) -> None`. After a successful run the episode is `ready`, its `audio_path` is set when audio was downloaded, and learning content is stored.
- This is the highest-value copied code. Port it from `nexa_insight/apps/api/src/nexa_insight_api/pipeline.py` with one change: after downloading audio, call `repo.set_audio_path`. When captions already exist (no audio download), `audio_path` stays null and `/audio` will 404 (acceptable: caption-only episodes have no local audio to shadow against).

- [ ] **Step 1: Write the failing test `backend/tests/test_pipeline.py`**

```python
import json
from pathlib import Path

from nexa_insight_api.models import Episode, ImportJob
from nexa_insight_api.pipeline import ImportPipeline, MediaMetadata, TranscriptSegment
from nexa_insight_api.settings import Settings


class FakeMedia:
    def __init__(self, tmp: Path):
        self.tmp = tmp

    def metadata(self, url):
        return MediaMetadata("abcdefghijk", "Title", "Channel", 60000, "http://thumb")

    def captions(self, url, destination):
        source_text = [TranscriptSegment(0, 2000, None, "Hello world."), TranscriptSegment(2000, 4000, None, "Goodbye.")]
        return source_text, None  # no chinese captions -> triggers translation

    def download_audio(self, url, destination):  # not used when captions exist
        raise AssertionError("should not download audio when captions exist")

    def split_audio(self, audio, output_dir):
        raise AssertionError("should not split audio when captions exist")


class FakeAI:
    def transcribe(self, path, offset_ms):
        return []

    def translate(self, texts):
        return [f"[zh]{t}" for t in texts]

    def chapters(self, sentences):
        return [{"title": "All", "summary": "whole", "start_ms": 0, "end_ms": 4000}]


def _seed(repo):
    with repo.session() as session:
        episode = Episode(source_url="https://youtu.be/x", youtube_id="abcdefghijk", status="queued")
        session.add(episode)
        session.flush()
        job = ImportJob(episode_id=episode.id, status="running")
        session.add(job)
        session.commit()
        return episode.id, job.id


def test_pipeline_produces_ready_bilingual_episode(repo, tmp_path):
    episode_id, job_id = _seed(repo)
    settings = Settings(_env_file=None, data_dir=tmp_path)
    pipeline = ImportPipeline(repo, settings, FakeMedia(tmp_path), FakeAI())
    pipeline.run(job_id)
    sentences = repo.list_sentences(episode_id)
    assert [s.sourceText for s in sentences] == ["Hello world.", "Goodbye."]
    assert [s.chinese for s in sentences] == ["[zh]Hello world.", "[zh]Goodbye."]
    assert repo.get_episode(episode_id).status == "ready"
    assert repo.get_job(job_id).status == "complete"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_pipeline.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'nexa_insight_api.pipeline'`

- [ ] **Step 3: Write `backend/src/nexa_insight_api/pipeline.py`**

Copy the full contents of `nexa_insight/apps/api/src/nexa_insight_api/pipeline.py`, changing only the imports (`from .repositories import Repository`, `from .settings import Settings`) and adding an audio-path write. Concretely, the file is identical to the original EXCEPT the audio-download branch inside `ImportPipeline.run` sets the audio path. Replace the original block:

```python
                audio = root / "source.mp3"
                if not audio.exists():
                    self.media.download_audio(episode.source_url, audio)
                parts = self.media.split_audio(audio, root / "chunks")
```

with:

```python
                audio = root / "source.mp3"
                if not audio.exists():
                    self.media.download_audio(episode.source_url, audio)
                self.repo.set_audio_path(episode.id, str(audio.relative_to(self.settings.data_dir)))
                parts = self.media.split_audio(audio, root / "chunks")
```

Everything else (`MediaMetadata`, `TranscriptSegment`, `MediaAdapter`, `AIAdapter`, `YtDlpMediaAdapter`, `OpenAIAdapter`, `_parse_json3`, `_align_chinese`, `_translate`, `_translate_exact`, the `CHUNK_MS`/`TRANSLATION_BATCH` constants) is copied verbatim.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_pipeline.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/src/nexa_insight_api/pipeline.py backend/tests/test_pipeline.py
git commit -m "feat(backend): import/transcription pipeline (copied + audio_path)"
```

---

### Task 5: Pydantic schemas

**Files:**
- Create: `backend/src/nexa_insight_api/schemas.py`
- Create: `backend/tests/test_schemas.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ImportRequest(url: str)`
  - `EpisodeView` (from_attributes) — id, source_url, youtube_id, title, channel, duration_ms, thumbnail_url, audio_path, status, error, created_at
  - `JobView` (from_attributes) — id, episode_id, stage, status, progress, attempts, error
  - `ImportView` — episode: EpisodeView, job: JobView
  - `ChapterView` (from_attributes) — id, title, summary, start_ms, end_ms
  - `SentenceView` (from_attributes) — id, episode_id, chapter_id, position, start_ms, end_ms, speaker, source_text, chinese
  - `EpisodeBundle` — episode: EpisodeView, chapters: list[ChapterView], sentences: list[SentenceView], has_audio: bool

- [ ] **Step 1: Write the failing test `backend/tests/test_schemas.py`**

```python
from nexa_insight_api.schemas import EpisodeBundle, EpisodeView, ImportRequest


def test_import_request_parses_url():
    assert ImportRequest(url="https://youtu.be/x").url == "https://youtu.be/x"


def test_episode_view_includes_audio_path_field():
    assert "audio_path" in EpisodeView.model_fields


def test_bundle_has_expected_fields():
    for field in ("episode", "chapters", "sentences", "has_audio"):
        assert field in EpisodeBundle.model_fields
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_schemas.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'nexa_insight_api.schemas'`

- [ ] **Step 3: Write `backend/src/nexa_insight_api/schemas.py`**

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_schemas.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/src/nexa_insight_api/schemas.py backend/tests/test_schemas.py
git commit -m "feat(backend): pydantic schemas incl. episode bundle"
```

---

### Task 6: FastAPI app — import, list, job, retry

**Files:**
- Create: `backend/src/nexa_insight_api/app.py`
- Create: `backend/tests/test_api_import.py`

**Interfaces:**
- Consumes: `Settings`, `Repository`, models, schemas.
- Produces: `create_app(settings=None) -> FastAPI` and module-level `app = create_app()`. Endpoints in this task:
  - `GET /api/health` → `{"status": "ok"}`
  - `POST /api/episodes/import` (201) → `ImportView`; rejects non-YouTube URLs with 422, duplicate URL with 409
  - `GET /api/episodes` → `list[EpisodeView]` (newest first)
  - `GET /api/episodes/{id}` → `EpisodeView` (404 if missing)
  - `GET /api/episodes/{id}/job` → `JobView` (404 if none)
  - `POST /api/jobs/{id}/retry` → `JobView` (re-queues job + episode)
  - Helper `youtube_id(url: str) -> str | None` (copied from original).

- [ ] **Step 1: Write the failing test `backend/tests/test_api_import.py`**

```python
import pytest
from fastapi.testclient import TestClient

from nexa_insight_api.app import create_app
from nexa_insight_api.settings import Settings


@pytest.fixture
def client(tmp_path) -> TestClient:
    settings = Settings(_env_file=None, data_dir=tmp_path, database_url="sqlite:///" + str(tmp_path / "t.db"))
    return TestClient(create_app(settings))


def test_health(client):
    assert client.get("/api/health").json() == {"status": "ok"}


def test_import_rejects_non_youtube(client):
    assert client.post("/api/episodes/import", json={"url": "https://example.com"}).status_code == 422


def test_import_creates_episode_and_job_then_rejects_duplicate(client):
    first = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"})
    assert first.status_code == 201
    body = first.json()
    assert body["episode"]["status"] == "queued"
    assert body["job"]["status"] == "queued"
    dup = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"})
    assert dup.status_code == 409


def test_retry_requeues(client):
    created = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"}).json()
    job_id = created["job"]["id"]
    retried = client.post(f"/api/jobs/{job_id}/retry")
    assert retried.status_code == 200
    assert retried.json()["status"] == "queued"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_api_import.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'nexa_insight_api.app'`

- [ ] **Step 3: Write `backend/src/nexa_insight_api/app.py`**

```python
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from fastapi import Depends, FastAPI, HTTPException, Response
from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import Episode, ImportJob
from .repositories import Repository
from .schemas import EpisodeView, ImportRequest, ImportView, JobView
from .settings import Settings


def youtube_id(url: str) -> str | None:
    parsed = urlparse(url)
    host = parsed.hostname or ""
    if host in {"youtu.be", "www.youtu.be"}:
        value = parsed.path.strip("/").split("/")[0]
    elif host in {"youtube.com", "www.youtube.com", "m.youtube.com"}:
        value = parse_qs(parsed.query).get("v", [None])[0]
    else:
        return None
    return value if value and len(value) == 11 else None


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    if settings.database_url.startswith("sqlite:///"):
        Path(settings.database_url.removeprefix("sqlite:///")).parent.mkdir(parents=True, exist_ok=True)
    repo = Repository.from_settings(settings)
    repo.create_schema()

    app = FastAPI(title="Nexa Insight iOS Import API")
    app.state.settings = settings
    app.state.repo = repo

    def db() -> Session:
        with repo.session() as session:
            yield session

    @app.get("/api/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/api/episodes/import", response_model=ImportView, status_code=201)
    def import_episode(request: ImportRequest, session: Session = Depends(db)) -> ImportView:
        video_id = youtube_id(request.url)
        if not video_id:
            raise HTTPException(422, "Enter a public YouTube URL")
        existing = session.scalar(select(Episode).where(Episode.source_url == request.url))
        if existing:
            raise HTTPException(409, "This episode has already been imported")
        episode = Episode(source_url=request.url, youtube_id=video_id, status="queued")
        session.add(episode)
        session.flush()
        job = ImportJob(episode_id=episode.id, stage="metadata", status="queued", progress=0)
        session.add(job)
        session.commit()
        return ImportView(episode=EpisodeView.model_validate(episode), job=JobView.model_validate(job))

    @app.get("/api/episodes", response_model=list[EpisodeView])
    def list_episodes(session: Session = Depends(db)) -> list[Episode]:
        return list(session.scalars(select(Episode).order_by(Episode.created_at.desc())))

    @app.get("/api/episodes/{episode_id}", response_model=EpisodeView)
    def get_episode(episode_id: int, session: Session = Depends(db)) -> Episode:
        episode = session.get(Episode, episode_id)
        if not episode:
            raise HTTPException(404, "Episode not found")
        return episode

    @app.get("/api/episodes/{episode_id}/job", response_model=JobView)
    def get_episode_job(episode_id: int, session: Session = Depends(db)) -> ImportJob:
        job = session.scalar(
            select(ImportJob).where(ImportJob.episode_id == episode_id).order_by(ImportJob.created_at.desc())
        )
        if not job:
            raise HTTPException(404, "Import job not found")
        return job

    @app.post("/api/jobs/{job_id}/retry", response_model=JobView)
    def retry_job(job_id: int, session: Session = Depends(db)) -> ImportJob:
        job = session.get(ImportJob, job_id)
        if not job:
            raise HTTPException(404, "Job not found")
        job.status, job.error = "queued", None
        episode = session.get(Episode, job.episode_id)
        episode.status, episode.error = "queued", None
        session.commit()
        return job

    return app


app = create_app()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_api_import.py -v`
Expected: PASS (all four tests)

- [ ] **Step 5: Commit**

```bash
git add backend/src/nexa_insight_api/app.py backend/tests/test_api_import.py
git commit -m "feat(backend): FastAPI import/list/job/retry endpoints"
```

---

### Task 7: Bundle and audio download endpoints

**Files:**
- Modify: `backend/src/nexa_insight_api/app.py` (add two endpoints + imports)
- Create: `backend/tests/test_api_bundle.py`

**Interfaces:**
- Consumes: everything from Task 6, plus `ChapterView`, `SentenceView`, `EpisodeBundle` (Task 5), `FileResponse`.
- Produces:
  - `GET /api/episodes/{id}/bundle` → `EpisodeBundle` (404 if episode missing). `has_audio` is true iff `episode.audio_path` is set and the file exists.
  - `GET /api/episodes/{id}/audio` → `FileResponse` mp3 (404 if no audio path or file missing).

- [ ] **Step 1: Write the failing test `backend/tests/test_api_bundle.py`**

```python
import pytest
from fastapi.testclient import TestClient

from nexa_insight_api.app import create_app
from nexa_insight_api.models import Episode
from nexa_insight_api.settings import Settings


@pytest.fixture
def client(tmp_path) -> TestClient:
    settings = Settings(_env_file=None, data_dir=tmp_path, database_url="sqlite:///" + str(tmp_path / "t.db"))
    app = create_app(settings)
    client = TestClient(app)
    client.app_settings = settings  # stash for the test
    client.repo = app.state.repo
    return client


def _ready_episode(client) -> int:
    created = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"}).json()
    episode_id = created["episode"]["id"]
    client.repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 2000}],
        [{"start_ms": 0, "end_ms": 1000, "speaker": None, "source_text": "Hi", "chinese": "嗨"}],
    )
    return episode_id


def test_bundle_returns_content_and_no_audio(client):
    episode_id = _ready_episode(client)
    body = client.get(f"/api/episodes/{episode_id}/bundle").json()
    assert body["episode"]["status"] == "ready"
    assert len(body["chapters"]) == 1
    assert len(body["sentences"]) == 1
    assert body["has_audio"] is False


def test_audio_404_when_absent(client):
    episode_id = _ready_episode(client)
    assert client.get(f"/api/episodes/{episode_id}/audio").status_code == 404


def test_audio_served_when_present(client):
    episode_id = _ready_episode(client)
    audio_dir = client.app_settings.data_dir / "episodes" / str(episode_id)
    audio_dir.mkdir(parents=True, exist_ok=True)
    (audio_dir / "source.mp3").write_bytes(b"ID3fake-mp3-bytes")
    client.repo.set_audio_path(episode_id, f"episodes/{episode_id}/source.mp3")
    resp = client.get(f"/api/episodes/{episode_id}/audio")
    assert resp.status_code == 200
    assert resp.content == b"ID3fake-mp3-bytes"
    bundle = client.get(f"/api/episodes/{episode_id}/bundle").json()
    assert bundle["has_audio"] is True
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_api_bundle.py -v`
Expected: FAIL (404 for `/bundle` route not found → assertion error or 404 on a route that doesn't exist yet)

- [ ] **Step 3: Add endpoints to `backend/src/nexa_insight_api/app.py`**

Update the imports at the top:

```python
from fastapi import Depends, FastAPI, HTTPException, Response
from fastapi.responses import FileResponse
```

and

```python
from .schemas import ChapterView, EpisodeBundle, EpisodeView, ImportRequest, ImportView, JobView, SentenceView
```

Add these two endpoints inside `create_app`, just before `return app`:

```python
    @app.get("/api/episodes/{episode_id}/bundle", response_model=EpisodeBundle)
    def get_bundle(episode_id: int, session: Session = Depends(db)) -> EpisodeBundle:
        episode = session.get(Episode, episode_id)
        if not episode:
            raise HTTPException(404, "Episode not found")
        chapters = repo.list_chapters(episode_id)
        sentences = repo.list_sentences(episode_id)
        has_audio = bool(episode.audio_path) and (settings.data_dir / episode.audio_path).exists()
        return EpisodeBundle(
            episode=EpisodeView.model_validate(episode),
            chapters=[ChapterView.model_validate(c) for c in chapters],
            sentences=[SentenceView.model_validate(s) for s in sentences],
            has_audio=has_audio,
        )

    @app.get("/api/episodes/{episode_id}/audio")
    def get_audio(episode_id: int, session: Session = Depends(db)) -> FileResponse:
        episode = session.get(Episode, episode_id)
        if not episode or not episode.audio_path:
            raise HTTPException(404, "Audio not found")
        path = settings.data_dir / episode.audio_path
        if not path.exists():
            raise HTTPException(404, "Audio file missing")
        return FileResponse(path, media_type="audio/mpeg")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_api_bundle.py -v`
Expected: PASS (all three tests)

- [ ] **Step 5: Commit**

```bash
git add backend/src/nexa_insight_api/app.py backend/tests/test_api_bundle.py
git commit -m "feat(backend): episode bundle and audio download endpoints"
```

---

### Task 8: Worker and run scripts

**Files:**
- Create: `backend/src/nexa_insight_api/worker.py`
- Create: `backend/tests/test_worker.py`
- Create: `backend/scripts/dev.sh`
- Create: `backend/README.md`

**Interfaces:**
- Consumes: `Repository`, `Settings`, `ImportPipeline`, `YtDlpMediaAdapter`, `OpenAIAdapter`.
- Produces: `worker.run_once(repo, pipeline) -> bool` (claims one job, runs it, returns whether a job was processed) and `main() -> None` (the polling loop). Factoring the single-iteration step out of the loop makes it testable without an infinite loop.

- [ ] **Step 1: Write the failing test `backend/tests/test_worker.py`**

```python
from nexa_insight_api.models import Episode, ImportJob
from nexa_insight_api.worker import run_once


class RecordingPipeline:
    def __init__(self):
        self.ran = []

    def run(self, job_id: int) -> None:
        self.ran.append(job_id)


def test_run_once_claims_and_runs_a_job(repo):
    with repo.session() as session:
        episode = Episode(source_url="https://youtu.be/x", youtube_id="abcdefghijk", status="queued")
        session.add(episode)
        session.flush()
        session.add(ImportJob(episode_id=episode.id, status="queued"))
        session.commit()
    pipeline = RecordingPipeline()
    assert run_once(repo, pipeline) is True
    assert len(pipeline.ran) == 1
    # No more queued jobs.
    assert run_once(repo, pipeline) is False


def test_run_once_marks_failed_job(repo):
    with repo.session() as session:
        episode = Episode(source_url="https://youtu.be/y", youtube_id="abcdefghijk", status="queued")
        session.add(episode)
        session.flush()
        job = ImportJob(episode_id=episode.id, status="queued")
        session.add(job)
        session.commit()
        job_id = job.id

    class Boom:
        def run(self, job_id: int) -> None:
            raise RuntimeError("kaboom")

    assert run_once(repo, Boom()) is True
    assert repo.get_job(job_id).status == "failed"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_worker.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'nexa_insight_api.worker'`

- [ ] **Step 3: Write `backend/src/nexa_insight_api/worker.py`**

```python
import logging
import time

from .pipeline import ImportPipeline, OpenAIAdapter, YtDlpMediaAdapter
from .repositories import Repository
from .settings import Settings


def run_once(repo: Repository, pipeline) -> bool:
    """Claim and run one queued job. Returns True if a job was processed."""
    job = repo.claim_next_job()
    if job is None:
        return False
    try:
        pipeline.run(job.id)
    except Exception:
        logging.exception("Import job %s failed", job.id)
        try:
            current = repo.get_job(job.id)
            repo.upsert_job(job.id, stage=current.stage, progress=current.progress, status="failed", error="Import failed")
        except LookupError:
            pass
    return True


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    settings = Settings()
    repo = Repository.from_settings(settings)
    repo.create_schema()
    pipeline = ImportPipeline(repo, settings, YtDlpMediaAdapter(), OpenAIAdapter(settings))
    logging.info("Import worker ready")
    while True:
        if not run_once(repo, pipeline):
            time.sleep(2)


if __name__ == "__main__":
    main()
```

Note: the pipeline already marks the job failed on its own exception path, but the worker adds a defensive fallback so a job never stays stuck in `running` if the pipeline raises before its own handler records the failure.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_worker.py -v`
Expected: PASS (both tests)

- [ ] **Step 5: Write `backend/scripts/dev.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export PYTHONPATH=backend/src
uvicorn nexa_insight_api.app:app --host 0.0.0.0 --port 8000 &
API_PID=$!
python -m nexa_insight_api.worker &
WORKER_PID=$!
trap 'kill $API_PID $WORKER_PID 2>/dev/null || true' EXIT
wait
```

Then: `chmod +x backend/scripts/dev.sh`

- [ ] **Step 6: Write `backend/README.md`**

````markdown
# Nexa Insight — iOS Import Backend

Thin backend that imports a YouTube episode, transcribes/translates/chapters it,
and serves the packaged episode (mp3 + bilingual sentences) to the iOS app.

## Requirements

Python 3.12+, `ffmpeg`, `yt-dlp`, and an API key for the configured
transcription + text models.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install -e 'backend/[dev]'
cp backend/.env.example backend/.env   # set NEXA_INSIGHT_OPENAI_API_KEY
```

## Run

```bash
./backend/scripts/dev.sh
```

The API listens on `http://0.0.0.0:8000` (reachable from the iPhone on the same
network via the Mac's LAN IP). The worker polls for queued import jobs.

## Verify

```bash
cd backend && python -m pytest -q
```

## Endpoints

- `POST /api/episodes/import` — `{ "url": "<youtube>" }`
- `GET  /api/episodes` / `GET /api/episodes/{id}` / `GET /api/episodes/{id}/job`
- `POST /api/jobs/{id}/retry`
- `GET  /api/episodes/{id}/bundle` — metadata + chapters + bilingual sentences
- `GET  /api/episodes/{id}/audio` — mp3 (404 for caption-only episodes)
````

- [ ] **Step 7: Run the whole suite**

Run: `cd backend && python -m pytest -q`
Expected: PASS (all tests from Tasks 1–8)

- [ ] **Step 8: Commit**

```bash
git add backend/src/nexa_insight_api/worker.py backend/tests/test_worker.py backend/scripts/dev.sh backend/README.md
git commit -m "feat(backend): import worker, dev script, README"
```

---

## Self-Review

**Spec coverage (backend section of the design spec):**
- Copied/trimmed `pipeline.py`, `settings.py`, `models.py`, `repositories.py` → Tasks 1–4 ✓
- Kept only Episode/ImportJob/ImportChunk/Chapter/Sentence → Task 2 (`test_no_tutor_tables_exist`) ✓
- Dropped tutor/realtime/class/discussion/shadowing → nothing ports them; enforced by Task 2 test ✓
- Endpoints import/job/list/detail/retry → Task 6 ✓
- New `bundle` + `audio` endpoints → Task 7 ✓
- mp3 audio, native playback (no transcoding) → Task 4 sets audio_path to the mp3; Task 7 serves `audio/mpeg` ✓
- Keep worker + job-polling → Task 8 ✓
- Self-contained, does not touch `nexa_insight/` → all code copied in; Global Constraints ✓
- Env prefix `NEXA_INSIGHT_` avoids collision → Task 1 ✓
- Trimmed pytest suite → tests in every task ✓

**Placeholder scan:** No TBD/TODO; every code step contains full code; every command has expected output. ✓

**Type consistency:** `Repository` method names used in later tasks (`list_chapters`, `list_sentences`, `set_audio_path`, `replace_learning_content`, `claim_next_job`, `get_job`, `upsert_job`) all defined in Task 3. `EpisodeBundle`/`EpisodeView`/`ChapterView`/`SentenceView` used in Task 7 all defined in Task 5. `run_once` signature defined and used consistently in Task 8. `ImportPipeline(repo, settings, media, ai)` and `.run(job_id)` consistent between Tasks 4 and 8. ✓

**Note on chunked-transcription path:** the pipeline's audio→chunk→transcribe branch is copied verbatim and exercised by the original project's tests; this plan's `test_pipeline` covers the caption-based bilingual path (the common case). A caption-only-source language episode still translates via the AI adapter. Both paths are preserved by the verbatim copy.
