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


def test_import_creates_episode_and_job_then_returns_existing_duplicate(client):
    first = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"})
    assert first.status_code == 201
    body = first.json()
    assert body["episode"]["status"] == "queued"
    assert body["job"]["status"] == "queued"
    dup = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"})
    assert dup.status_code == 201
    assert dup.json()["episode"]["id"] == body["episode"]["id"]
    assert dup.json()["job"]["id"] == body["job"]["id"]


def test_import_duplicate_failed_episode_requeues_existing_job(client):
    created = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"}).json()
    job_id = created["job"]["id"]
    episode_id = created["episode"]["id"]
    repo = client.app.state.repo
    repo.upsert_job(job_id, stage="translation", progress=70, status="failed", error="boom")
    repo.fail_episode(episode_id, "boom")

    retried = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"})

    assert retried.status_code == 201
    assert retried.json()["episode"]["status"] == "queued"
    assert retried.json()["job"]["id"] == job_id
    assert retried.json()["job"]["status"] == "queued"


def test_import_duplicate_ready_episode_without_audio_requeues_backfill(client):
    created = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"}).json()
    job_id = created["job"]["id"]
    episode_id = created["episode"]["id"]
    repo = client.app.state.repo
    repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 2000}],
        [{"start_ms": 0, "end_ms": 1000, "speaker": None, "source_text": "Hi", "chinese": "嗨"}],
    )
    repo.upsert_job(job_id, stage="complete", progress=100, status="complete")

    retried = client.post("/api/episodes/import", json={"url": "https://www.youtube.com/watch?v=abcdefghijk&t=347s"})

    assert retried.status_code == 201
    body = retried.json()
    assert body["episode"]["id"] == episode_id
    assert body["episode"]["status"] == "queued"
    assert body["job"]["id"] == job_id
    assert body["job"]["stage"] == "audio_backfill"
    assert body["job"]["status"] == "queued"


def test_retry_requeues(client):
    created = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"}).json()
    job_id = created["job"]["id"]
    retried = client.post(f"/api/jobs/{job_id}/retry")
    assert retried.status_code == 200
    assert retried.json()["status"] == "queued"
