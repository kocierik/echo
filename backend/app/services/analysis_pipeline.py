"""Shared orchestration for segment analysis."""

import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.timezone import to_user_local_date
from app.models.chunk import Chunk
from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.segment import Segment
from app.services.chunking import chunk_text
from app.services.deduplication import deduplicate_entities
from app.services.embedding_base import EmbeddingService
from app.services.entity_consolidation import consolidate_entities
from app.services.entity_mentions import record_mentions
from app.services.llm_base import LLMMessage, LLMService
from app.services.usage import usage_owner
from app.workers.retry import retry_with_backoff


@dataclass(frozen=True)
class AnalysisResult:
    extracted_entity_count: int
    new_entity_count: int
    chunk_count: int


class AnalysisPipeline:
    def __init__(self, llm_service: LLMService, embedding_service: EmbeddingService):
        self.llm_service = llm_service
        self.embedding_service = embedding_service

    async def analyze_segment(
        self,
        db: AsyncSession,
        segment: Segment,
    ) -> AnalysisResult:
        usage_owner.set(segment.user_id)
        transcription = segment.transcription
        if transcription is None:
            return AnalysisResult(0, 0, 0)

        user_id = segment.user_id

        # --- Conversation grouping ---
        conversation = await assign_to_conversation(db, segment)

        # --- Fetch known people for context-aware extraction ---
        known_people = await known_people_names(db, user_id)

        # --- Entity extraction (with retry + known people context) ---
        # Requests to Echo inside the text are skipped by the extraction prompt itself.
        entities = await retry_with_backoff(
            extract_entities,
            self.llm_service,
            transcription.text,
            user_id,
            transcription.id,
            conversation.id,
            known_people=known_people,
            reference_date=to_user_local_date(segment.recorded_at),
            operation_name=f"Entity extraction segment {segment.id}",
        )

        new_entities = await save_entities(
            db,
            entities,
            user_id,
            self.llm_service,
            self.embedding_service,
            label=f"segment {segment.id}",
        )

        # --- Incremental chunking & embedding ---
        # Only embed the NEW segment's text as an additional chunk,
        # instead of re-chunking the entire conversation every time.
        # Full re-chunking happens only when conversation is "completed".
        new_text = transcription.text.strip()
        new_chunks: list[str] = []
        if new_text and len(new_text.split()) > 5:
            # Get current max chunk_index for this conversation
            max_idx_query = (
                select(Chunk.chunk_index)
                .where(Chunk.conversation_id == conversation.id)
                .order_by(Chunk.chunk_index.desc())
                .limit(1)
            )
            max_idx_result = await db.execute(max_idx_query)
            max_idx_row = max_idx_result.first()
            next_index = (max_idx_row[0] + 1) if max_idx_row else 0

            # Chunk only the new text
            new_chunks = chunk_text(
                new_text, settings.chunk_size_tokens, settings.chunk_overlap_tokens
            )

            if new_chunks:
                new_embeddings = await retry_with_backoff(
                    self.embedding_service.embed_batch,
                    new_chunks,
                    operation_name=f"Incremental embeddings segment {segment.id}",
                )
                for index, (text, embedding) in enumerate(zip(new_chunks, new_embeddings)):
                    chunk = Chunk(
                        conversation_id=conversation.id,
                        text=text,
                        token_count=len(text.split()),
                        chunk_index=next_index + index,
                        embedding=embedding,
                    )
                    db.add(chunk)

        # No per-segment summary: the raw spoken transcript stays the canonical
        # text. Title and summary are written once the conversation is closed
        # by app/workers/summaries.py.
        conversation.analysis_status = "completed"

        await db.commit()
        return AnalysisResult(len(entities), len(new_entities), len(new_chunks))


async def known_people_names(db: AsyncSession, user_id: uuid.UUID, limit: int = 20) -> list[str]:
    """The people the user mentioned most recently, for extraction to name them alike."""
    result = await db.execute(
        select(Entity.name)
        .where(Entity.user_id == user_id)
        .where(Entity.entity_type == "person")
        .order_by(Entity.updated_at.desc())
        .limit(limit)
    )
    return [row[0] for row in result.all()]


async def save_entities(
    db: AsyncSession,
    entities: list[Entity],
    user_id: uuid.UUID,
    llm_service: LLMService,
    embedding_service: EmbeddingService,
    *,
    label: str,
) -> list[Entity]:
    """Store freshly extracted entities as a segment or a photo does: merged into known
    ones when they are the same thing, embedded when new, their mentions recorded, then
    fuzzy duplicates resolved. Returns the new ones (not flushed for the caller's commit)."""
    # Update existing entities if new info refers to something already known,
    # only insert truly new entities
    consolidation = await consolidate_entities(db, entities, user_id)
    new_entities = consolidation.new
    for entity in new_entities:
        db.add(entity)

    # Generate embeddings for NEW entities only (existing ones already have them)
    if new_entities:
        entity_texts = [
            f"{entity.name}: {entity.content}" if entity.content else entity.name
            for entity in new_entities
        ]
        entity_embeddings = await retry_with_backoff(
            embedding_service.embed_batch,
            entity_texts,
            operation_name=f"Entity embeddings {label}",
        )
        for entity, embedding in zip(new_entities, entity_embeddings):
            entity.embedding = embedding

    # Flush to persist entities before dedup, then note where each was mentioned
    # (a merge during dedup moves the mention to the surviving entity)
    await db.flush()
    await record_mentions(db, consolidation.resolved)

    # Deduplicate entities (catches remaining fuzzy duplicates)
    await deduplicate_entities(db, user_id, llm_service)
    return new_entities


def _segment_end(segment: Segment) -> datetime:
    return segment.recorded_at + timedelta(milliseconds=segment.duration_ms or 0)


def starts_new_conversation(latest: Conversation | None, segment: Segment) -> bool:
    """Whether a segment opens a new conversation instead of extending the latest.

    A new conversation starts when any of these holds:
    - the device measured a long enough silence before the segment;
    - the wall-clock gap since the latest conversation ended is long enough
      (covers background noise keeping the VAD busy, reboots and lost silence);
    - the latest conversation already spans the maximum duration.
    """
    if latest is None:
        return True

    timeout = timedelta(milliseconds=settings.silence_timeout_ms)
    if (segment.silence_before_ms or 0) >= settings.silence_timeout_ms:
        return True

    latest_end = latest.ended_at or latest.started_at
    if segment.recorded_at - latest_end >= timeout:
        return True

    max_duration = timedelta(milliseconds=settings.max_conversation_duration_ms)
    return segment.recorded_at - latest.started_at >= max_duration


async def assign_to_conversation(db: AsyncSession, segment: Segment) -> Conversation:
    """Assign a segment to the latest conversation or open a new one."""
    user_id = segment.user_id

    # Find the latest conversation for this user
    query = (
        select(Conversation)
        .where(Conversation.user_id == user_id)
        .order_by(Conversation.started_at.desc())
        .limit(1)
    )
    result = await db.execute(query)
    latest_conversation = result.scalar_one_or_none()

    segment_end = _segment_end(segment)
    if starts_new_conversation(latest_conversation, segment):
        conversation = Conversation(
            user_id=user_id,
            started_at=segment.recorded_at,
            ended_at=segment_end,
            analysis_status="pending",
        )
        db.add(conversation)
        await db.flush()
    else:
        conversation = latest_conversation
        # Segments can arrive out of order (buffered on the wearable): never shrink
        if conversation.ended_at is None or segment_end > conversation.ended_at:
            conversation.ended_at = segment_end

    # Link segment to conversation
    segment.conversation_id = conversation.id
    return conversation


GIORNI_SETTIMANA = [
    "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica",
]


async def extract_entities(
    llm_service,
    text: str,
    user_id: uuid.UUID,
    transcription_id: uuid.UUID | None,
    conversation_id: uuid.UUID,
    known_people: list[str] | None = None,
    reference_date: date | None = None,
) -> list[Entity]:
    """Use LLM to extract structured entities from transcription text.

    Args:
        llm_service: LLM service for extraction.
        text: Transcription text to analyze.
        user_id: Owner user ID.
        transcription_id: Source transcription.
        conversation_id: Parent conversation.
        known_people: Optional list of known person names to help LLM
                      recognize and normalize references.
        reference_date: Day the speech was recorded (user's timezone), used to
                        resolve relative dates ("domani", "venerdì") to ISO dates.
    """
    # Build system prompt with known people context
    people_context = ""
    if known_people:
        names_list = ", ".join(known_people[:15])
        people_context = (
            f"\n\nPersone già note all'utente: {names_list}. "
            "Se riconosci riferimenti a queste persone (anche con varianti del nome, "
            "soprannomi, o pronomi), usa il nome canonico dalla lista."
        )

    date_context = ""
    if reference_date:
        weekday = GIORNI_SETTIMANA[reference_date.weekday()]
        date_context = (
            f"\n\nData di riferimento (giorno della registrazione): "
            f"{weekday} {reference_date.isoformat()}. "
            "Converti le date relative ('domani', 'venerdì', 'tra due settimane') "
            "in date assolute YYYY-MM-DD rispetto a questa data."
        )

    messages = [
        LLMMessage(
            role="system",
            content=(
                "Sei un sistema di estrazione di conoscenza. "
                "Estrai entità strutturate dal testo fornito. "
                "Rispondi in JSON con il seguente formato:\n"
                '{"entities": [{"type": "person|task|idea|event|note", "name": "...", '
                '"content": "...", "metadata": {...}}]}\n\n'
                "Tipi:\n"
                "- person: persone menzionate (metadata: {role, notes})\n"
                "- task: SOLO le promesse dell'utente (vedi 'Promesse' sotto). Non estrarre "
                "altre cose da fare, piani, doveri o promemoria: quando l'utente vuole un "
                "to-do lo chiede a Echo "
                "(metadata: {done: false, due_date: YYYY-MM-DD, promise: true, promise_to})\n"
                "- idea: idee, suggerimenti, concetti (metadata: {tags})\n"
                "- event: eventi, appuntamenti, date (metadata: {event_date: YYYY-MM-DD, "
                "event_time: HH:MM, duration_minutes: intero, location})\n"
                "- note: qualsiasi altra informazione rilevante (metadata: {tags})\n\n"
                "Regole importanti:\n"
                "- Estrai SOLO informazioni esplicitamente presenti nel testo\n"
                "- Per i task, formula il nome come azione (verbo all'infinito)\n"
                "- Promesse: una frase dell'utente (righe [You] o [Tu]) che è un impegno "
                "esplicito verso una persona a fare una cosa concreta (\"Marco, ti mando il "
                "preventivo entro venerdì\", \"ti richiamo domani, Giulia\"): un task con "
                "metadata promise: true e promise_to: il nome della persona (ometti "
                "promise_to se non si capisce). NON sono promesse: piani o doveri per sé "
                "(\"devo comprare il latte\", \"domani devo chiamare Marco\"), frasi "
                "ipotetiche o condizionate (\"se riesco ti chiamo\"), formule di cortesia "
                "senza un'azione precisa (\"ci sentiamo\", \"ti faccio sapere\", \"lo "
                "faccio io\"), domande e offerte (\"vuoi che ti mandi le foto?\"), ciò che "
                "l'utente riporta di altri (\"Marco ha detto che mi manda...\"), gli impegni "
                "presi da altri (righe [Others] o [Altri]). Nel dubbio non è una promessa\n"
                "- Per le persone, usa il nome completo se disponibile\n"
                "- Ignora filler e parole senza contenuto informativo\n"
                "- Le richieste rivolte all'assistente \"Echo\" (es. \"Echo, segnami il "
                "dentista giovedì\", \"Ehi Echo, riassumimi le mail\") sono comandi per "
                "l'assistente, non fatti da ricordare: non estrarre entità da queste "
                "richieste. Le menzioni di un prodotto o della parola \"Echo\" sono "
                "testo normale\n"
                "- Date sempre in formato YYYY-MM-DD, orari in formato HH:MM (24h)\n"
                "- Se l'orario o la durata non sono detti, ometti event_time o "
                "duration_minutes: non inventarli\n"
                '- Se non ci sono entità da estrarre, rispondi con {"entities": []}.'
                f"{people_context}"
                f"{date_context}"
            ),
        ),
        LLMMessage(role="user", content=f"Testo:\n\n{text}"),
    ]

    result = await llm_service.complete_json(messages)
    entities_data = result.get("entities", [])

    entities = []
    for entity_data in entities_data:
        # Skip entities with empty names
        name = entity_data.get("name", "").strip()
        if not name:
            continue
        metadata = entity_data.get("metadata") or {}
        # To-dos come only from the user's promises; others are asked of Echo
        if entity_data.get("type") == "task" and metadata.get("promise") is not True:
            continue

        entity = Entity(
            user_id=user_id,
            entity_type=entity_data.get("type", "note"),
            name=name,
            content=entity_data.get("content"),
            metadata_=entity_data.get("metadata", {}),
            source_transcription_id=transcription_id,
            conversation_id=conversation_id,
        )
        entities.append(entity)

    return entities


UNTITLED_CONVERSATION = "Untitled conversation"


@dataclass(frozen=True)
class ConversationSummary:
    title: str
    summary: str
    emoji: str | None  # None when the model gave none or something that is not one emoji


# An emoji is at most a few code points (flags, skin tones, ZWJ sequences); words are not
_MAX_EMOJI_CHARS = 8


def _clean_emoji(value) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value or len(value) > _MAX_EMOJI_CHARS or any(c.isalnum() for c in value):
        return None
    return value


async def generate_conversation_summary(llm_service, full_text: str) -> ConversationSummary:
    """Generate a short title, a summary and one emoji for a conversation using LLM.

    Args:
        llm_service: LLM service instance.
        full_text: Full concatenated transcription text of the conversation.
    """
    # Truncate if too long (save tokens)
    max_chars = 3000
    text_for_summary = full_text[:max_chars] if len(full_text) > max_chars else full_text

    messages = [
        LLMMessage(
            role="system",
            content=(
                "You organize the user's conversations. "
                "Given the transcript of a conversation (often in Italian), write:\n"
                "1. A short title (max 60 characters) naming the main topic\n"
                "2. A 2-3 sentence summary of the key points\n"
                "3. One emoji for the topic (e.g. 💼 work, 🍝 food, 🏥 health)\n\n"
                "Write the title and summary in English. Keep names of people and places as "
                "spoken.\n"
                "Answer in JSON with the format:\n"
                '{"title": "...", "summary": "...", "emoji": "..."}'
            ),
        ),
        LLMMessage(role="user", content=f"Conversation:\n\n{text_for_summary}"),
    ]

    result = await llm_service.complete_json(messages)
    return ConversationSummary(
        title=result.get("title") or UNTITLED_CONVERSATION,
        summary=result.get("summary", ""),
        emoji=_clean_emoji(result.get("emoji")),
    )
