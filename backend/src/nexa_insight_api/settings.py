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
    learning_expression_batch_size: int = 40
    learning_expression_concurrency: int = 4
