"""Does the memory search find the right conversation?

    python -m evals.retrieval

A small made-up memory (evals/cases/retrieval.json: conversations, the people in them)
goes into the database inside a transaction that is rolled back at the end, embedded with
the configured embedding service (real API calls). Each question goes through
retrieve_memory_context, as a chat question does (dates read from the question), and
scores where its expected conversation lands among the sources:

  hit@1  the first source is an expected conversation
  hit@5  one of the first five is
  MRR    the mean of 1/rank (0 when not found)

Real questions on a real memory, read only (nothing is written), from a git-ignored file:

    python -m evals.retrieval --mine evals/data/retrieval.json

    {"user": "you@example.com", "questions": [{"q": "...", "expect": ["<conversation id>"]}]}

The conversation ids are in the app's links, or in the conversations table.
"""

import argparse
import asyncio
import json
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

from sqlalchemy import select

from app.core.config import settings
from app.core.database import async_session
from app.models.chunk import Chunk
from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.entity_mention import EntityMention
from app.models.user import User
from app.services.chunking import chunk_text
from app.services.embedding_openai import get_embedding_service
from app.services.memory_retrieval import retrieve_memory_context
from app.services.temporal import extract_date_range

CASES = Path(__file__).parent / "cases" / "retrieval.json"


@dataclass
class Scored:
    question: str
    rank: int | None  # 1-based rank of the first expected conversation among the sources


def rank_of(expected: set[str], found: list[str]) -> int | None:
    """The 1-based rank of the first expected key in `found` (deduplicated), else None."""
    seen: list[str] = []
    for key in found:
        if key not in seen:
            seen.append(key)
    for position, key in enumerate(seen, start=1):
        if key in expected:
            return position
    return None


def summarize(scored: list[Scored]) -> dict[str, float]:
    total = len(scored) or 1
    return {
        "hit@1": sum(s.rank == 1 for s in scored) / total,
        "hit@5": sum(s.rank is not None and s.rank <= 5 for s in scored) / total,
        "mrr": sum(1 / s.rank for s in scored if s.rank) / total,
    }


async def _load(db, user_id: uuid.UUID, conversations: list[dict], embedder) -> dict:
    """The cases' conversations, chunked and embedded as the pipeline does: key -> id."""
    ids: dict[str, uuid.UUID] = {}
    people: dict[str, Entity] = {}
    for case in conversations:
        started = datetime.fromisoformat(case["started_at"])
        conversation = Conversation(
            user_id=user_id,
            started_at=started,
            ended_at=started + timedelta(minutes=case.get("minutes", 15)),
            title=case["title"],
            summary=case["summary"],
            analysis_status="completed",
        )
        db.add(conversation)
        await db.flush()
        ids[case["key"]] = conversation.id
        texts = chunk_text(case["text"], settings.chunk_size_tokens, settings.chunk_overlap_tokens)
        for index, (text, embedding) in enumerate(zip(texts, await embedder.embed_batch(texts))):
            db.add(Chunk(
                conversation_id=conversation.id,
                text=text,
                token_count=len(text.split()),
                chunk_index=index,
                embedding=embedding,
            ))
        for name in case.get("people", []):
            person = people.get(name)
            if person is None:
                person = Entity(
                    user_id=user_id,
                    entity_type="person",
                    name=name,
                    conversation_id=conversation.id,
                )
                db.add(person)
                await db.flush()
                people[name] = person
            db.add(EntityMention(entity_id=person.id, conversation_id=conversation.id))
    await db.flush()
    return ids


async def run(only: str | None, mine: Path | None = None) -> list[Scored]:
    cases = json.loads((mine or CASES).read_text())
    questions = [q for q in cases["questions"] if not only or only in q["q"]]
    now = datetime.fromisoformat(cases["now"]) if "now" in cases else datetime.now().astimezone()
    embedder = get_embedding_service()
    scored: list[Scored] = []
    async with async_session() as db:
        try:
            if mine:
                user = (
                    await db.execute(select(User).where(User.email == cases["user"]))
                ).scalar_one()
                # A real memory's conversations are named by their own id
                def name(conversation_id):
                    return str(conversation_id)
            else:
                user = User(email=f"eval-{uuid.uuid4().hex[:8]}@echo.invalid", password_hash="")
                db.add(user)
                await db.flush()
                ids = await _load(db, user.id, cases["conversations"], embedder)
                key_of = {conversation_id: key for key, conversation_id in ids.items()}

                def name(conversation_id):
                    return key_of.get(conversation_id, "?")
            for case in questions:
                memory = await retrieve_memory_context(
                    db,
                    user.id,
                    case["q"],
                    date_range=extract_date_range(case["q"], now=now),
                    embedding_service=embedder,
                )
                found = [name(source["conversation_id"]) for source in memory.sources]
                rank = rank_of(set(case["expect"]), found)
                scored.append(Scored(case["q"], rank))
                mark = "ok  " if rank == 1 else ("near" if rank else "MISS")
                print(f"  {mark} {rank or '-':>2}  {case['q']}")
                if rank != 1:
                    print(f"            expected {case['expect']}, got {found[:5]}")
        finally:
            await db.rollback()
    return scored


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--only", help="only the questions containing this text")
    parser.add_argument("--mine", type=Path, help="real questions on a real memory (read only)")
    args = parser.parse_args()
    scored = asyncio.run(run(args.only, args.mine))
    totals = summarize(scored)
    print(
        f"\n{len(scored)} questions  hit@1 {totals['hit@1']:.0%}  "
        f"hit@5 {totals['hit@5']:.0%}  MRR {totals['mrr']:.2f}"
    )


if __name__ == "__main__":
    main()
