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
