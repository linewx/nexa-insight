from pathlib import Path
from urllib.parse import parse_qs, urlparse

from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import Episode, ImportJob
from .pipeline import YtDlpMediaAdapter
from .repositories import Repository
from .schemas import ChapterView, EpisodeBundle, EpisodeView, ImportRequest, ImportView, JobView, LearningExpressionView, SentenceView
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

    app = FastAPI(title="Nexa Insight Import API")
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
        existing = session.scalar(
            select(Episode).where((Episode.youtube_id == video_id) | (Episode.source_url == request.url))
        )
        if existing:
            job = session.scalar(
                select(ImportJob).where(ImportJob.episode_id == existing.id).order_by(ImportJob.created_at.desc())
            )
            audio_missing = not existing.audio_path or not (settings.data_dir / existing.audio_path).exists()
            if job is None:
                job = ImportJob(episode_id=existing.id, stage="metadata", status="queued", progress=0)
                session.add(job)
            elif existing.status == "failed" or job.status == "failed":
                job.status, job.error = "queued", None
                existing.status, existing.error = "queued", None
            elif existing.status == "ready" and audio_missing:
                job.stage, job.status, job.progress, job.error = "audio_backfill", "queued", 0, None
                existing.status, existing.error = "queued", None
            session.commit()
            return ImportView(episode=EpisodeView.model_validate(existing), job=JobView.model_validate(job))
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

    @app.post("/api/episodes/{episode_id}/reprocess", response_model=ImportView)
    def reprocess_episode(episode_id: int, session: Session = Depends(db)) -> ImportView:
        episode = session.get(Episode, episode_id)
        if not episode:
            raise HTTPException(404, "Episode not found")
        running = session.scalar(
            select(ImportJob)
            .where(ImportJob.episode_id == episode_id, ImportJob.status.in_(["queued", "running"]))
            .order_by(ImportJob.created_at.desc())
        )
        if running:
            return ImportView(episode=EpisodeView.model_validate(episode), job=JobView.model_validate(running))
        job = ImportJob(episode_id=episode_id, stage="metadata", status="queued", progress=0)
        session.add(job)
        episode.status = "queued"
        episode.error = None
        session.commit()
        return ImportView(episode=EpisodeView.model_validate(episode), job=JobView.model_validate(job))

    @app.get("/api/episodes/{episode_id}/bundle", response_model=EpisodeBundle)
    def get_bundle(episode_id: int, session: Session = Depends(db)) -> EpisodeBundle:
        episode = session.get(Episode, episode_id)
        if not episode:
            raise HTTPException(404, "Episode not found")
        chapters = repo.list_chapters(episode_id)
        sentences = repo.list_sentences(episode_id)
        expressions = repo.list_learning_expressions(episode_id)
        has_audio = bool(episode.audio_path) and (settings.data_dir / episode.audio_path).exists()
        return EpisodeBundle(
            episode=EpisodeView.model_validate(episode),
            chapters=[ChapterView.model_validate(c) for c in chapters],
            sentences=[SentenceView.model_validate(s) for s in sentences],
            has_audio=has_audio,
            has_stream=bool(episode.stream_url),
            has_learning_pack=bool(expressions),
            learning_expressions=[LearningExpressionView.model_validate(item) for item in expressions],
        )

    @app.post("/api/episodes/{episode_id}/stream", response_model=EpisodeView)
    def refresh_stream(episode_id: int, session: Session = Depends(db)) -> Episode:
        episode = session.get(Episode, episode_id)
        if not episode:
            raise HTTPException(404, "Episode not found")
        stream_url, expires_at = YtDlpMediaAdapter().stream(episode.source_url)
        if not stream_url:
            raise HTTPException(404, "Playable video stream not found")
        episode.stream_url = stream_url
        episode.stream_url_expires_at = expires_at
        session.commit()
        return episode

    @app.get("/api/episodes/{episode_id}/audio")
    def get_audio(episode_id: int, session: Session = Depends(db)) -> FileResponse:
        episode = session.get(Episode, episode_id)
        if not episode or not episode.audio_path:
            raise HTTPException(404, "Audio not found")
        path = settings.data_dir / episode.audio_path
        if not path.exists():
            raise HTTPException(404, "Audio file missing")
        return FileResponse(path, media_type="audio/mpeg")

    return app


app = create_app()
