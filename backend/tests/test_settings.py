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
