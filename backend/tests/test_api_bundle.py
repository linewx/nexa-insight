import pytest
from fastapi.testclient import TestClient

from nexa_insight_api.app import create_app
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
