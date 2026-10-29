"""Owner-scoped conversation deletion with reversible audio staging."""

import logging
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.conversation import Conversation
from app.models.segment import Segment
from app.models.user_fact import UserFact
from app.services.entity_mentions import release_conversation

logger = logging.getLogger(__name__)


class ConversationNotFoundError(Exception):
    """The requested conversation is not visible to the current owner."""


class ConversationStorageError(Exception):
    """Audio staging failed before the database delete was attempted."""


class ConversationStorage(Protocol):
    def exists(self, path: Path) -> bool: ...

    def rename(self, source: Path, destination: Path) -> None: ...

    def unlink(self, path: Path) -> None: ...


class LocalConversationStorage:
    def exists(self, path: Path) -> bool:
        return path.exists()

    def rename(self, source: Path, destination: Path) -> None:
        source.rename(destination)

    def unlink(self, path: Path) -> None:
        path.unlink()


@dataclass(frozen=True)
class ConversationDeleteResult:
    cleanup_warnings: tuple[str, ...] = ()


_LOCAL_STORAGE = LocalConversationStorage()


def get_conversation_storage() -> ConversationStorage:
    return _LOCAL_STORAGE


def _restore_staged_files(
    storage: ConversationStorage,
    staged_files: list[tuple[Path, Path]],
) -> list[str]:
    warnings: list[str] = []
    for original_path, staged_path in reversed(staged_files):
        try:
            if storage.exists(staged_path):
                storage.rename(staged_path, original_path)
        except OSError as error:
            warning = f"Failed to restore staged audio {staged_path}: {error}"
            warnings.append(warning)
            logger.exception(warning)
    return warnings


async def delete_conversation(
    db: AsyncSession,
    user_id: uuid.UUID,
    conversation_id: uuid.UUID,
    storage: ConversationStorage | None = None,
) -> ConversationDeleteResult:
    """Permanently delete one owned conversation and its stored audio."""
    storage = storage or get_conversation_storage()

    conversation_result = await db.execute(
        select(Conversation)
        .where(Conversation.id == conversation_id)
        .where(Conversation.user_id == user_id)
        .with_for_update()
    )
    conversation = conversation_result.scalar_one_or_none()
    if conversation is None:
        raise ConversationNotFoundError

    segment_result = await db.execute(
        select(Segment.id, Segment.audio_path)
        .where(Segment.conversation_id == conversation_id)
        .order_by(Segment.recorded_at, Segment.id)
    )
    segments = segment_result.all()

    staged_files: list[tuple[Path, Path]] = []
    for _segment_id, audio_path in segments:
        if not audio_path or not audio_path.strip():
            continue

        original_path = Path(audio_path)
        staged_path = original_path.with_name(f".echo-delete-{uuid.uuid4()}")
        try:
            if not storage.exists(original_path):
                continue
            storage.rename(original_path, staged_path)
        except FileNotFoundError:
            continue
        except OSError as error:
            restore_warnings = _restore_staged_files(storage, staged_files)
            if restore_warnings:
                logger.error(
                    "Conversation audio staging rollback was incomplete: %s",
                    "; ".join(restore_warnings),
                )
            raise ConversationStorageError(
                "Unable to stage conversation audio for deletion"
            ) from error
        staged_files.append((original_path, staged_path))

    try:
        # People and tasks also mentioned in other conversations are kept
        await release_conversation(db, conversation.id)
        # What Echo noticed in it and the user has not kept goes with it
        await db.execute(
            delete(UserFact).where(
                UserFact.conversation_id == conversation.id, UserFact.status != "kept"
            )
        )
        await db.delete(conversation)
        await db.commit()
    except Exception:
        try:
            await db.rollback()
        except Exception:
            logger.exception("Failed to roll back conversation deletion")
        restore_warnings = _restore_staged_files(storage, staged_files)
        if restore_warnings:
            logger.error(
                "Conversation audio restoration after database failure was incomplete: %s",
                "; ".join(restore_warnings),
            )
        raise

    cleanup_warnings: list[str] = []
    for _original_path, staged_path in staged_files:
        try:
            storage.unlink(staged_path)
        except FileNotFoundError:
            continue
        except OSError as error:
            warning = f"Failed to remove staged audio {staged_path}: {error}"
            cleanup_warnings.append(warning)
            logger.exception(warning)

    return ConversationDeleteResult(cleanup_warnings=tuple(cleanup_warnings))
