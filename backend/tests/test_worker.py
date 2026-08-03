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
    assert repo.get_job(job_id).error == "kaboom"


def test_run_once_preserves_pipeline_error_detail(repo):
    with repo.session() as session:
        episode = Episode(source_url="https://youtu.be/y", youtube_id="abcdefghijk", status="queued")
        session.add(episode)
        session.flush()
        job = ImportJob(episode_id=episode.id, status="queued")
        session.add(job)
        session.commit()
        job_id = job.id

    class DetailedBoom:
        def run(self, job_id: int) -> None:
            repo.upsert_job(job_id, stage="audio", progress=15, status="failed", error="yt-dlp timed out")
            raise RuntimeError("wrapped failure")

    assert run_once(repo, DetailedBoom()) is True
    assert repo.get_job(job_id).status == "failed"
    assert repo.get_job(job_id).error == "yt-dlp timed out"
