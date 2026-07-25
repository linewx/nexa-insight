from nexa_insight_api.schemas import EpisodeBundle, EpisodeView, ImportRequest


def test_import_request_parses_url():
    assert ImportRequest(url="https://youtu.be/x").url == "https://youtu.be/x"


def test_episode_view_includes_audio_path_field():
    assert "audio_path" in EpisodeView.model_fields


def test_bundle_has_expected_fields():
    for field in ("episode", "chapters", "sentences", "has_audio"):
        assert field in EpisodeBundle.model_fields
