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
    #
    # 12, not 6. Measured on a 122-line lesson: the learning stage was 79s of a 110s import,
    # and the wave arithmetic explains it — verification is ~56 calls (two per unique candidate,
    # and the pair is sequential because the second call needs the first's output), so 6 workers
    # means ten waves of waiting. Raising it halves the stage. Provider rate limits are the
    # ceiling here, not CPU: these threads are asleep on network I/O.
    scan_concurrency: int = 12
