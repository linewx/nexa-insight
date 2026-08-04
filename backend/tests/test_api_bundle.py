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
    assert body["has_learning_pack"] is False
    assert body["learning_expressions"] == []


def test_bundle_includes_learning_expressions(client):
    episode_id = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"}).json()["episode"]["id"]
    client.repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 2000}],
        [{"start_ms": 0, "end_ms": 1000, "speaker": None, "source_text": "Hello world", "chinese": "你好世界"}],
        [{
            "text": "Hello world", "kind": "phrase", "chinese": "你好世界", "pronunciation": None,
            "example": "Hello world again.", "example_chinese": "再次你好世界。",
            "occurrences": [{"sentence_position": 0, "start_offset": 0, "end_offset": 11}],
        }],
    )

    body = client.get(f"/api/episodes/{episode_id}/bundle").json()

    assert body["has_learning_pack"] is True
    assert body["learning_expressions"][0]["text"] == "Hello world"
    assert body["learning_expressions"][0]["occurrences"] == [{"sentence_id": body["sentences"][0]["id"], "start_offset": 0, "end_offset": 11}]


def test_bundle_deduplicates_repeated_expression(client):
    episode_id = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"}).json()["episode"]["id"]
    client.repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 2000}],
        [
            {"start_ms": 0, "end_ms": 1000, "speaker": None, "source_text": "Work out the plan.", "chinese": "制定计划。"},
            {"start_ms": 1000, "end_ms": 2000, "speaker": None, "source_text": "We worked out a solution.", "chinese": "我们想出了解决方案。"},
        ],
        [
            {"text": "work out", "kind": "phrase", "chinese": "制定；想出", "pronunciation": None, "example": "Work it out.", "example_chinese": "把它想出来。", "occurrences": [{"sentence_position": 0, "start_offset": 0, "end_offset": 8}]},
            {"text": "Work Out", "kind": "phrase", "chinese": "制定；想出", "pronunciation": None, "example": "Work it out.", "example_chinese": "把它想出来。", "occurrences": [{"sentence_position": 1, "start_offset": 3, "end_offset": 13}]},
        ],
    )

    expressions = client.get(f"/api/episodes/{episode_id}/bundle").json()["learning_expressions"]

    assert len(expressions) == 1
    assert len(expressions[0]["occurrences"]) == 2


def test_bundle_ignores_invalid_expression_occurrence(client):
    episode_id = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"}).json()["episode"]["id"]
    client.repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 1000}],
        [{"start_ms": 0, "end_ms": 1000, "speaker": None, "source_text": "Hello world", "chinese": "你好世界"}],
        [{
            "text": "world", "kind": "word", "chinese": "世界", "pronunciation": "wɜːrld",
            "example": "A new world.", "example_chinese": "一个新世界。",
            "occurrences": [
                {"sentence_position": 0, "start_offset": 6, "end_offset": 11},
                {"sentence_position": 0, "start_offset": 6, "end_offset": 99},
            ],
        }],
    )

    expressions = client.get(f"/api/episodes/{episode_id}/bundle").json()["learning_expressions"]

    assert len(expressions) == 1
    assert [(item["start_offset"], item["end_offset"]) for item in expressions[0]["occurrences"]] == [(6, 11)]


def test_bundle_normalizes_numeric_expression_offsets_and_ignores_invalid_types(client):
    episode_id = client.post("/api/episodes/import", json={"url": "https://youtu.be/abcdefghijk"}).json()["episode"]["id"]
    client.repo.replace_learning_content(
        episode_id,
        [{"title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 1000}],
        [{"start_ms": 0, "end_ms": 1000, "speaker": None, "source_text": "Hello world", "chinese": "你好世界"}],
        [{
            "text": "world", "kind": "word", "chinese": "世界", "pronunciation": "wɜːrld",
            "example": "A new world.", "example_chinese": "一个新世界。",
            "occurrences": [
                {"sentence_position": "0", "start_offset": "6", "end_offset": "11"},
                {"sentence_position": "zero", "start_offset": "6", "end_offset": "11"},
                {"sentence_position": 0, "start_offset": "six", "end_offset": "11"},
            ],
        }],
    )

    expressions = client.get(f"/api/episodes/{episode_id}/bundle").json()["learning_expressions"]

    assert expressions[0]["occurrences"] == [{"sentence_id": expressions[0]["occurrences"][0]["sentence_id"], "start_offset": 6, "end_offset": 11}]


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
