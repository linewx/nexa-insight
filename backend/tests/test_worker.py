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
