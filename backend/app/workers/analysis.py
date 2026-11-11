"""Analysis worker: transcribed segments become conversations, entities and chunks.

`queue:analysis` holds the ids of segments with a meaningful transcription; the analysis
pipeline (app/services/analysis_pipeline.py) groups each into its conversation, extracts
entities and indexes it for search.
"""

import asyncio
import logging
import uuid

import redis.asyncio as redis

from app.core.database import async_session
from app.core.logging import restore_correlation_for
from app.models.segment import Segment
from app.services.analysis_pipeline import AnalysisPipeline
from app.services.embedding_openai import get_embedding_service
from app.services.llm_openai import get_llm_analysis_service
from app.workers.dead_letter import push_to_dead_letter
from app.workers.queue import done, take
from app.workers.retry import RetryExhaustedError

logger = logging.getLogger(__name__)

ANALYSIS_QUEUE = "queue:analysis"


async def process_analysis(redis_client: redis.Redis, shutdown_event: asyncio.Event):
    """Process analysis queue: extract entities, group conversations, create embeddings."""
    llm_service = get_llm_analysis_service()
    embedding_service = get_embedding_service()
    pipeline = AnalysisPipeline(llm_service, embedding_service)

    while not shutdown_event.is_set():
        raw = await take(redis_client, ANALYSIS_QUEUE)
        if raw is None:
            continue
        try:
            await _analyse(redis_client, pipeline, raw)
        finally:
            await done(redis_client, ANALYSIS_QUEUE, raw)


async def _analyse(redis_client: redis.Redis, pipeline: AnalysisPipeline, raw) -> None:
    """One queued segment: analysed, or sent to the dead letter queue."""
    segment_id = uuid.UUID(raw.decode())
    await restore_correlation_for(redis_client, "segment", segment_id)
    logger.info(f"Processing analysis for segment {segment_id}")

    async with async_session() as db:
        try:
            # Get segment with transcription
            segment = await db.get(Segment, segment_id)
            if segment is None or segment.transcription is None:
                return

            analysis_result = await pipeline.analyze_segment(db, segment)
            logger.info(
                f"Analysis completed for segment {segment_id}: "
                f"{analysis_result.extracted_entity_count} entities, "
                f"{analysis_result.chunk_count} chunks"
            )

        except RetryExhaustedError as e:
            logger.error(f"Analysis failed permanently for segment {segment_id}: {e}")
            await db.rollback()
            await push_to_dead_letter(
                redis_client, segment_id, "analysis", str(e.last_error), e.attempts
            )

        except asyncio.CancelledError:
            logger.info(
                f"[Shutdown] Analysis interrupted for segment {segment_id}, requeueing"
            )
            await db.rollback()
            await redis_client.lpush(ANALYSIS_QUEUE, str(segment_id))
            raise

        except Exception as e:
            logger.error(f"Analysis unexpected error for segment {segment_id}: {e}")
            await db.rollback()
            await push_to_dead_letter(redis_client, segment_id, "analysis", str(e))
