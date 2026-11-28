from pathlib import Path

from pydantic import AliasChoices, Field
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
    completed_audio_retention_hours: int = 24
    incomplete_audio_retention_days: int = 7

    # OpenAI
    openai_api_key: str = ""

    # Composio (third-party actions)
    composio_api_key: str = ""

    # STT
    stt_provider: str = "openai"
    stt_model: str = "gpt-4o-transcribe"
    stt_language: str = "it"

    # Deepgram (alternative STT provider)
    deepgram_api_key: str = ""
    deepgram_model: str = "nova-3"

    # pyannoteAI: who spoke when in a closed conversation (services/diarization.py); unset:
    # Deepgram's speakers. PYNOTES_API_KEY is accepted too, the name first used in .env
    pyannote_api_key: str = Field(
        "", validation_alias=AliasChoices("PYANNOTE_API_KEY", "PYNOTES_API_KEY")
    )
    pyannote_model: str = "precision-2"
    # A conversation not diarized by then keeps Deepgram's speakers
    pyannote_timeout_s: int = 300

    # WhatsApp, read-only, through the bridge (whatsapp/); unset: no WhatsApp at all
    whatsapp_bridge_url: str = ""
    whatsapp_bridge_token: str = ""

    # LLM - analysis (async, economico)
    llm_analysis_provider: str = "openai"
    # Best on the evaluations (docs/MODEL-EVALUATION.md); gpt-4o-mini shuts down 2027-01-14
    llm_analysis_model: str = "gpt-6-luna"
    # For reasoning models (gpt-5/gpt-6 families): "none", "low", ... Empty for models
    # that take a temperature instead (gpt-4o). With chat completions, OpenAI accepts
    # function tools only with "none".
    llm_analysis_reasoning_effort: str = "low"
    # "chat" (chat completions) or "responses": reasoning models need "responses" to call
    # tools with any effort above "none"
    llm_analysis_api: str = "chat"

    # LLM - query (RAG, qualità)
    llm_query_provider: str = "openai"
    # Memory answers and the actions agent (gpt-4o shuts down 2027-01-14). Tools with
    # reasoning need the Responses API
    llm_query_model: str = "gpt-6-luna"
    llm_query_reasoning_effort: str = "low"
    llm_query_api: str = "responses"

    # The intent check before a chat or voice request that may need an app: it runs
    # before the answer starts, so it is fast (no reasoning); 10/10 on the evaluations
    llm_intent_model: str = "gpt-6-luna"
    llm_intent_reasoning_effort: str = "none"
    llm_intent_api: str = "chat"

    # Vision: answers a question about a photo from the wearable camera and describes it
    # for memory (no tools: chat completions, ~2 s per photo)
    llm_vision_model: str = "gpt-6-luna"
    llm_vision_reasoning_effort: str = "low"
    llm_vision_api: str = "chat"

    # Wearable camera: a photo request the wearable has not answered by then fails, and
    # the user is told in the chat
    photo_request_timeout_s: int = 90
    photo_max_bytes: int = 1024 * 1024

    # Embeddings
    embedding_provider: str = "openai"
    embedding_model: str = "text-embedding-3-small"  # 1536 dimensions, fixed by the schema

    # Chunking
    chunk_size_tokens: int = 500
    chunk_overlap_tokens: int = 50

    # Conversation segmentation
    silence_timeout_ms: int = 120000  # 2 minutes of silence = new conversation
    max_conversation_duration_ms: int = 2 * 60 * 60 * 1000  # split conversations after 2 hours

    # Conversation titles/summaries, generated once a conversation is closed
    summary_check_interval_s: int = 300
    summary_batch_size: int = 10
    summary_min_words: int = 10

    # API
    api_prefix: str = "/api"

    # Bearer token Prometheus uses for /metrics (without it, /metrics needs an API key)
    metrics_token: str = ""

    # The server operator's token (X-Admin-Token) for /api/admin: the failed jobs of every
    # user. Empty: those endpoints do not exist
    admin_token: str = ""

    # Anyone with the app can create an account (POST /api/auth/register); false closes
    # it, and accounts are then made only with `make create-user`
    registration_open: bool = True

    # Sign in with Google: comma-separated OAuth client IDs of the app (iOS, web, Android)
    # from Google Cloud Console. An ID token is accepted only when made for one of them.
    # Empty: POST /api/auth/google does not exist
    google_client_ids: str = ""

    # CORS: comma-separated browser origins allowed to call the API. Empty by default: the
    # app and the connected apps are not browsers ("*" allows any site)
    cors_origins: str = ""

    # Circuit breaker — protects against cascading failures from OpenAI outages
    circuit_breaker_failure_threshold: int = 5  # failures before opening circuit
    circuit_breaker_recovery_timeout: int = 60  # seconds to wait before half-open

    # Speaker detection
    speaker_energy_threshold: int = 0  # manual override (0 = auto-calibrate)
    # Auto-calibration: energy percentile above which a segment is "self" (0..1)
    speaker_threshold_percentile: float = 0.7

    # Voice fingerprints (who is speaking): an ONNX speaker-embedding model, baked into the
    # image. Without it the energy rule above decides "You" / "Others".
    voice_model_path: str = "/opt/models/voice_embedding.onnx"
    # Cosine similarity to a voice profile: from this, the voice is that person's...
    voice_match_threshold: float = 0.6
    # ...from this (below the match), the transcript asks "Marco?"
    voice_suggest_threshold: float = 0.45
    # ...and only this far ahead of the next closest voice: one between two is no one's
    # (Omi's margin, the same WeSpeaker model)
    voice_match_margin: float = 0.10
    # The same three on fingerprints with the pendant's own sound taken away (the mean of
    # the user's recent fingerprints, services/voice_profiles.channel_center). Raw, every
    # voice through the pendant scored ~0.75 to every other; taken away, the user and
    # another voice scored -0.2, confirmed segments 0.23-1.0 to their own (2026-11-22)
    voice_centered_match_threshold: float = 0.35
    voice_centered_suggest_threshold: float = 0.15
    voice_centered_margin: float = 0.30
    # Fingerprints the pendant's sound is taken from; fewer and fingerprints stay raw
    voice_center_min_segments: int = 30
    # A segment this loud among the user's recent ones (percentile) is most likely the
    # user's own voice, near the microphone: never given to someone else automatically
    voice_loud_percentile: float = 0.85
    # Less speech than this gives an unreliable fingerprint (a short command still has one)
    voice_min_seconds: float = 1.5

    # Web search while answering (services/web_search.py): "openai" or "none"
    web_search_provider: str = "openai"

    # Plans (services/plans.py): changes to the defaults, per plan, as JSON in .env, e.g.
    # PLANS={"plus": {"monthly_minutes": 1200, "web_searches_per_day": 20}}
    plans: dict[str, dict[str, int]] = {}
    # The plan of a new account, from the app or from `make create-user`; an unknown name
    # is free
    new_account_plan: str = "free"
    # To-dos from what is said in a conversation (promises, "I'll send it Friday"); off:
    # only when the user asks Echo ("Echo, segnami...")
    conversation_promises: bool = False
    # The shortest password registration takes; 1 for now (any password), 10 before
    min_password_length: int = 1

    # A closed conversation transcribed again whole, for the context its segments lack
    # (services/retranscription.py): a second speech-to-text pass on its minutes
    conversation_retranscription: bool = True

    # The website's beta form (routers/beta.py) mails each address here; off without a host
    beta_notify_email: str = "erik@man.ovh"
    smtp_host: str = ""
    # 465: SSL; any other port: STARTTLS
    smtp_port: int = 465
    smtp_user: str = ""
    smtp_password: str = ""
    smtp_from: str = ""
    # The website (site/), served at / when the folder is there (docker-compose mounts it)
    site_dir: str = "/site"

    # User's local timezone (IANA name): calendar events, relative dates in extraction
    user_timezone: str = "Europe/Rome"

    # Local hour (in user_timezone) when the daily digest of the previous day is written
    digest_local_hour: int = 4

    # Run tracking (core/runs.py): each coordinator request and routine run, with its
    # steps, in agent_runs / agent_steps for `make runs`. Off: nothing is written
    run_tracking_enabled: bool = False
    # A run still `running` after this many seconds was cut off (a restart, a crash):
    # closed as `interrupted`. The longest real request plus 60 s
    run_interrupted_after_seconds: int = 180
    # Tracking rows older than this are deleted by the retention loop
    run_retention_days: int = 30
    # How long the correlation ID of an uploaded segment or photo is kept in Redis
    # (corr:{kind}:{id}) for the workers that pick it up: 7 days
    correlation_key_ttl_seconds: int = 604800

    model_config = SettingsConfigDict(
        env_file=(_REPO_ROOT / ".env", ".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )


settings = Settings()
