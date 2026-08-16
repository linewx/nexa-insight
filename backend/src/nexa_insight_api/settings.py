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
    translation_batch_size: int = 10
    translation_concurrency: int = 4
    # How many scan calls run at once.
    #
    # The scan was the slowest stage of an import: ~180 sequential calls and ~10 minutes for a
    # 122-line video, because every batch is scanned TRAP_PASSES times and each candidate costs
    # two verification calls. Nothing in it depends on anything else in it, so the only reason
    # it was slow was that it waited.
    scan_concurrency: int = 6
