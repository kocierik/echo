from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

# backend/app/core/config.py → repo root (where .env lives)
_REPO_ROOT = Path(__file__).resolve().parents[3]


class Settings(BaseSettings):
    # Database
    database_url: str = "postgresql+asyncpg://echo:echo@localhost:5432/echo"

    # Redis
    redis_url: str = "redis://localhost:6379/0"

    # Audio storage
    audio_storage_path: str = "/data/audio"
    audio_retention_days: int = 30

    # OpenAI
    openai_api_key: str = ""

    # STT
    stt_provider: str = "openai"
    stt_model: str = "whisper-1"
    stt_language: str = "it"

    # LLM - analysis (async, economico)
    llm_analysis_provider: str = "openai"
    llm_analysis_model: str = "gpt-4o-mini"

    # LLM - query (RAG, qualità)
    llm_query_provider: str = "openai"
    llm_query_model: str = "gpt-4o"

    # Embeddings
    embedding_provider: str = "openai"
    embedding_model: str = "text-embedding-3-small"
    embedding_dimensions: int = 1536

    # Chunking
    chunk_size_tokens: int = 500
    chunk_overlap_tokens: int = 50

    # Conversation segmentation
    silence_timeout_ms: int = 120000  # 2 minutes of silence = new conversation

    # API
    api_prefix: str = "/api"

    # CORS — comma-separated allowed origins (use "*" to allow all)
    cors_origins: str = "*"

    # Circuit breaker — protects against cascading failures from OpenAI outages
    circuit_breaker_failure_threshold: int = 5  # failures before opening circuit
    circuit_breaker_recovery_timeout: int = 60  # seconds to wait before half-open

    # Speaker detection
    speaker_energy_threshold: int = 0  # manual override (0 = auto-calibrate)

    model_config = SettingsConfigDict(
        env_file=(_REPO_ROOT / ".env", ".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )


settings = Settings()
