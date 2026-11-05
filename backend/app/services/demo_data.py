"""Example data (Profile → Example data): a few days of conversations, things the user
said about themselves, saved things and places, to see Echo filled in before the
wearable has heard anything. Turned off, every row it made is deleted, and only those.

The conversations are made as the wearable's would be (segments with their transcript,
in the past) and analysed by the worker like any other: people, tasks, events, search
and summaries come from the real pipeline. Every row made is listed in demo_items.
"""

import logging
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timezone import to_user_local_date
from app.models.conversation import Conversation
from app.models.demo_item import DemoItem
from app.models.digest import Digest
from app.models.health_day import HealthDay
from app.models.place_visit import PlaceVisit
from app.models.saved import SavedItem, SavedList
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.models.user import User
from app.models.user_fact import UserFact
from app.models.weekly_digest import WeeklyDigest
from app.services.conversation_deleter import ConversationNotFoundError, delete_conversation
from app.services.language import account_languages
from app.services.saved import Moment, save_item
from app.services.weekly_digest import week_start_of

logger = logging.getLogger(__name__)

# A week of the Health app (Profile → Health), oldest first: (sleep min, steps, workout)
_HEALTH_WEEK = (
    (412, 7840, None), (385, 9120, "Corsa 35 min, 6,2 km"), (448, 6530, None),
    (342, 11870, "Palestra 50 min"), (430, 8210, None), (465, 5480, None),
    (398, 12650, "Corsa 48 min, 8,4 km"),
)

ANALYSIS_QUEUE = "queue:analysis"
# Seconds between one line and the next in a conversation
LINE_GAP_S = 4
# About how fast people speak, for each line's length
WORDS_PER_SECOND = 2.5


@dataclass(frozen=True)
class _Conversation:
    hours_ago: float
    # (speaker, text): "self" is the user, "other" whoever they talk to
    lines: tuple[tuple[str, str], ...]


@dataclass(frozen=True)
class _Saved:
    list_name: str
    title: str
    details: str | None
    fields: dict


@dataclass(frozen=True)
class _Place:
    hours_ago: float
    minutes: int
    name: str
    address: str
    latitude: float
    longitude: float


@dataclass(frozen=True)
class _Content:
    conversations: tuple[_Conversation, ...]
    facts: tuple[str, ...]
    saved: tuple[_Saved, ...]
    places: tuple[_Place, ...]


_PLACES_IT = (
    _Place(27, 40, "Bar Centrale", "Via dell'Indipendenza 12, Bologna", 44.4983, 11.3436),
    _Place(50, 75, "Palestra Fit Point", "Via Marconi 30, Bologna", 44.4990, 11.3360),
    _Place(73, 25, "Libreria Due Torri", "Strada Maggiore 4, Bologna", 44.4939, 11.3467),
)

ITALIAN = _Content(
    conversations=(
        _Conversation(3, (
            ("other", "Allora, per lo sprint: il rilascio della nuova dashboard lo facciamo "
                      "venerdì mattina, prima del weekend non voglio sorprese."),
            ("self", "Va bene. Io finisco la documentazione delle API entro giovedì, così "
                     "il team di supporto la può leggere prima."),
            ("other", "Perfetto. Io preparo la demo per il cliente e la mando a Paolo "
                      "domani pomeriggio."),
            ("self", "Ricordati che Paolo vuole vedere anche i grafici dei costi, "
                     "l'ha chiesto due volte."),
            ("other", "Giusto, li aggiungo. Ci sentiamo giovedì alle dieci per l'ultimo "
                      "controllo, Giulia."),
        )),
        _Conversation(7, (
            ("other", "Ciao tesoro, domenica vieni a pranzo? Faccio le lasagne."),
            ("self", "Certo mamma, arrivo verso l'una. Porto io il dolce, prendo la "
                     "torta di riso dalla pasticceria sotto casa."),
            ("other", "Brava. E non dimenticare che sabato prossimo è il compleanno di "
                      "zia Rosa, compie settant'anni."),
            ("self", "Hai ragione, le prendo un regalo. Magari un libro di cucina, le "
                     "piacciono tanto."),
        )),
        _Conversation(26, (
            ("other", "Il controllo è andato bene, solo un po' di tartaro. Le fissiamo la "
                      "pulizia per martedì prossimo alle quindici e trenta?"),
            ("self", "Sì, martedì alle tre e mezza va bene. Devo portare qualcosa?"),
            ("other", "No, solo la tessera sanitaria. Lo studio è sempre in via Saragozza "
                      "18, dalla dottoressa Bianchi."),
        )),
        _Conversation(29, (
            ("other", "Allora Lisbona a dicembre la facciamo? Ho visto voli a 90 euro dal "
                      "dodici al quindici."),
            ("self", "Sì dai, prenoto io i voli entro domenica, prima che salgano i prezzi."),
            ("other", "Io cerco un appartamento in Alfama. E devi assolutamente leggere "
                      "Il barone rampante, te lo porto la prossima volta."),
            ("self", "Ottimo, Marco. Allora tu pensi alla casa e io ai voli."),
        )),
        _Conversation(51, (
            ("other", "Bel allenamento oggi. Domenica corriamo la dieci chilometri ai "
                      "Giardini Margherita?"),
            ("self", "Sì, partenza alle nove. Il mio obiettivo è stare sotto i cinquanta "
                     "minuti."),
            ("other", "Ce la fai. Io intanto mi iscrivo anche per tutti e due, sono quindici "
                      "euro a testa. Ci vediamo lì, Luca."),
        )),
        _Conversation(76, (
            ("self", "Allora, cose da ricordare: devo rinnovare l'assicurazione della "
                     "macchina entro fine mese, scade il trenta."),
            ("self", "E poi voglio provare a fare il pane in casa nel weekend, con il "
                     "lievito madre che mi ha dato Sara."),
            ("self", "Idea per il lavoro: un piccolo script che controlla ogni mattina "
                     "i certificati in scadenza e manda un messaggio sul canale del team."),
        )),
    ),
    facts=(
        "Bevo il caffè senza zucchero",
        "Ho un cane che si chiama Briciola",
        "Corro tre volte a settimana, di solito la mattina presto",
    ),
    saved=(
        _Saved("Vini", "Barolo 2019", "Bevuto a cena da Giulia, ottimo con il brasato",
               {"voto": "9/10", "prezzo": "45 €"}),
        _Saved("Libri da leggere", "Il barone rampante", "Consigliato da Marco", {}),
        _Saved("Ristoranti", "Trattoria da Gianni", "Tortellini in brodo da provare",
               {"zona": "Bologna centro"}),
    ),
    places=_PLACES_IT,
)

ENGLISH = _Content(
    conversations=(
        _Conversation(3, (
            ("other", "So, for the sprint: we ship the new dashboard on Friday morning, "
                      "I don't want surprises before the weekend."),
            ("self", "Fine. I'll finish the API documentation by Thursday, so the support "
                     "team can read it first."),
            ("other", "Great. I'll prepare the customer demo and send it to Paul tomorrow "
                      "afternoon."),
            ("self", "Remember Paul wants to see the cost charts too, he asked twice."),
            ("other", "Right, I'll add them. Let's talk Thursday at ten for a last check, "
                      "it's Julia here, see you."),
        )),
        _Conversation(7, (
            ("other", "Hi love, are you coming for lunch on Sunday? I'm making lasagne."),
            ("self", "Sure mum, I'll be there around one. I'll bring dessert, the rice cake "
                     "from the bakery downstairs."),
            ("other", "Lovely. And don't forget that next Saturday is aunt Rose's birthday, "
                      "she turns seventy."),
            ("self", "You're right, I'll get her a present. Maybe a cookbook, she loves them."),
        )),
        _Conversation(26, (
            ("other", "The check-up went well, just a little tartar. Shall we book the "
                      "cleaning for next Tuesday at half past three?"),
            ("self", "Yes, Tuesday at three thirty works. Do I need to bring anything?"),
            ("other", "No, just your health card. The practice is still at 18 Saragozza "
                      "street, with doctor White."),
        )),
        _Conversation(29, (
            ("other", "So, Lisbon in December? I saw flights for 90 euros from the twelfth "
                      "to the fifteenth."),
            ("self", "Yes, let's do it. I'll book the flights by Sunday, before prices go up."),
            ("other", "I'll look for a flat in Alfama. And you really must read The Baron "
                      "in the Trees, I'll bring it next time."),
            ("self", "Great, Mark. You sort out the flat and I'll do the flights."),
        )),
        _Conversation(51, (
            ("other", "Good workout today. Shall we run the 10k at the park on Sunday?"),
            ("self", "Yes, start at nine. My goal is to finish under fifty minutes."),
            ("other", "You can do it. I'll sign us both up, it's fifteen euros each. "
                      "See you there, Luke here."),
        )),
        _Conversation(76, (
            ("self", "Right, things to remember: I have to renew the car insurance by the "
                     "end of the month, it expires on the thirtieth."),
            ("self", "And I want to try baking bread at the weekend, with the sourdough "
                     "starter Sarah gave me."),
            ("self", "Work idea: a small script that checks every morning which "
                     "certificates expire soon and posts it in the team channel."),
        )),
    ),
    facts=(
        "I take my coffee without sugar",
        "I have a dog called Crumb",
        "I run three times a week, usually early in the morning",
    ),
    saved=(
        _Saved("Wines", "Barolo 2019", "Had it at dinner at Julia's, great with braised beef",
               {"rating": "9/10", "price": "45 €"}),
        _Saved("Books to read", "The Baron in the Trees", "Recommended by Mark", {}),
        _Saved("Restaurants", "Gianni's trattoria", "Tortellini in broth to try",
               {"area": "Bologna centre"}),
    ),
    places=_PLACES_IT,
)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def content_for(language: str) -> _Content:
    return ITALIAN if language == "it" else ENGLISH


async def is_on(db: AsyncSession, user_id: uuid.UUID) -> bool:
    found = await db.scalar(select(DemoItem.item_id).where(DemoItem.user_id == user_id).limit(1))
    return found is not None


async def _lock(db: AsyncSession, user_id: uuid.UUID) -> None:
    """One turn on or off at a time per account (two taps make one set)."""
    await db.execute(select(User.id).where(User.id == user_id).with_for_update())


def _record(db: AsyncSession, user_id: uuid.UUID, kind: str, item_id: uuid.UUID) -> None:
    db.add(DemoItem(user_id=user_id, kind=kind, item_id=item_id))


async def turn_on(
    db: AsyncSession, user_id: uuid.UUID, *, redis_client, embedding_service=None,
    now: datetime | None = None,
) -> bool:
    """Makes the example data; False when it is there already."""
    await _lock(db, user_id)
    if await is_on(db, user_id):
        await db.rollback()
        return False
    now = now or _now()
    language, _ = await account_languages(db, user_id)
    content = content_for(language)

    segment_ids: list[uuid.UUID] = []
    for spec in sorted(content.conversations, key=lambda c: -c.hours_ago):
        segment_ids += _add_conversation(db, user_id, spec, language, now)

    for text in content.facts:
        fact = UserFact(
            id=uuid.uuid4(), user_id=user_id, text=text, status="kept", source="you",
            created_at=now,
        )
        db.add(fact)
        _record(db, user_id, "fact", fact.id)

    new_lists: set[uuid.UUID] = set()
    for spec in content.saved:
        existing = await db.scalar(
            select(SavedList.id).where(
                SavedList.user_id == user_id, func.lower(SavedList.name) == spec.list_name.lower()
            )
        )
        item, created = await save_item(
            db, user_id, list_name=spec.list_name, title=spec.title,
            moment=Moment(source="chat"), details=spec.details, fields=dict(spec.fields),
            embedding_service=embedding_service,
        )
        if created:
            _record(db, user_id, "saved_item", item.id)
        if existing is None and item.list_id not in new_lists:
            new_lists.add(item.list_id)
            _record(db, user_id, "saved_list", item.list_id)

    # A week of Health, never over the user's own days
    for back, (sleep, steps, workout) in enumerate(reversed(_HEALTH_WEEK), start=1):
        day = to_user_local_date(now) - timedelta(days=back - 1)
        if await db.get(HealthDay, (user_id, day)) is None:
            db.add(HealthDay(
                user_id=user_id, day=day, sleep_minutes=sleep, steps=steps,
                distance_km=round(steps * 0.00072, 1), exercise_minutes=40 if workout else 12,
                workouts=workout, source="demo",
            ))

    for spec in content.places:
        arrived = now - timedelta(hours=spec.hours_ago)
        visit = PlaceVisit(
            id=uuid.uuid4(), user_id=user_id, key=f"demo:{uuid.uuid4()}",
            arrived_at=arrived, left_at=arrived + timedelta(minutes=spec.minutes),
            latitude=spec.latitude, longitude=spec.longitude, accuracy_m=20.0,
            name=spec.name, address=spec.address, source="ios",
        )
        db.add(visit)
        _record(db, user_id, "place_visit", visit.id)

    await db.commit()
    # Oldest first, as the wearable would send them: the worker groups and analyses them
    for segment_id in segment_ids:
        await redis_client.lpush(ANALYSIS_QUEUE, str(segment_id))
    return True


def _add_conversation(
    db: AsyncSession, user_id: uuid.UUID, spec: _Conversation, language: str, now: datetime
) -> list[uuid.UUID]:
    start = now - timedelta(hours=spec.hours_ago)
    moment = start
    segments: list[Segment] = []
    for speaker, text in spec.lines:
        duration_ms = int(max(3.0, len(text.split()) / WORDS_PER_SECOND) * 1000)
        segment = Segment(
            id=uuid.uuid4(), user_id=user_id, received_at=moment, recorded_at=moment,
            duration_ms=duration_ms, speaker=speaker, transcription_status="completed",
        )
        segment.transcription = Transcription(
            id=uuid.uuid4(), text=text, speaker_label=speaker, language=language,
            confidence=0.95, stt_provider="example", stt_model="example",
        )
        segments.append(segment)
        moment += timedelta(milliseconds=duration_ms, seconds=LINE_GAP_S)
    conversation = Conversation(
        id=uuid.uuid4(), user_id=user_id, started_at=start, ended_at=moment,
        analysis_status="pending",
    )
    db.add(conversation)
    for segment in segments:
        segment.conversation_id = conversation.id
        db.add(segment)
    _record(db, user_id, "conversation", conversation.id)
    return [segment.id for segment in segments]


@dataclass(frozen=True)
class Removed:
    # Daily and weekly summaries written while the example data was there: to write again
    days: list[date]
    weeks: list[date]


async def turn_off(db: AsyncSession, user_id: uuid.UUID) -> Removed:
    """Deletes every row the example data made, and the summaries written over it."""
    await _lock(db, user_id)
    rows = (await db.execute(select(DemoItem).where(DemoItem.user_id == user_id))).scalars().all()
    if not rows:
        await db.rollback()
        return Removed([], [])
    since = min(row.created_at for row in rows)
    ids: dict[str, list[uuid.UUID]] = {}
    for row in rows:
        ids.setdefault(row.kind, []).append(row.item_id)

    days: set[date] = set()
    for conversation_id in ids.get("conversation", []):
        conversation = await db.get(Conversation, conversation_id)
        if conversation is None or conversation.user_id != user_id:
            continue
        days.add(to_user_local_date(conversation.started_at))
    # Each conversation with its people, tasks and suggestions (kept when also elsewhere);
    # the list of what was made goes last, so an interrupted turn-off can be done again
    for conversation_id in ids.get("conversation", []):
        try:
            await delete_conversation(db, user_id, conversation_id)
        except ConversationNotFoundError:
            continue

    if ids.get("fact"):
        await db.execute(
            delete(UserFact).where(UserFact.user_id == user_id, UserFact.id.in_(ids["fact"]))
        )
    if ids.get("saved_item"):
        await db.execute(
            delete(SavedItem).where(
                SavedItem.user_id == user_id, SavedItem.id.in_(ids["saved_item"])
            )
        )
    for list_id in ids.get("saved_list", []):
        # A list the user has put their own things in since stays
        if await db.scalar(select(SavedItem.id).where(SavedItem.list_id == list_id).limit(1)):
            continue
        await db.execute(
            delete(SavedList).where(SavedList.user_id == user_id, SavedList.id == list_id)
        )
    await db.execute(
        delete(HealthDay).where(HealthDay.user_id == user_id, HealthDay.source == "demo")
    )
    if ids.get("place_visit"):
        await db.execute(
            delete(PlaceVisit).where(
                PlaceVisit.user_id == user_id, PlaceVisit.id.in_(ids["place_visit"])
            )
        )

    # Summaries of those days written while the examples were there mention them
    stale_days = list(
        await db.scalars(
            delete(Digest)
            .where(
                Digest.user_id == user_id,
                Digest.digest_date.in_(days),
                Digest.created_at >= since,
            )
            .returning(Digest.digest_date)
        )
    ) if days else []
    weeks = {week_start_of(day) for day in days}
    stale_weeks = list(
        await db.scalars(
            delete(WeeklyDigest)
            .where(
                WeeklyDigest.user_id == user_id,
                WeeklyDigest.week_start.in_(weeks),
                WeeklyDigest.created_at >= since,
            )
            .returning(WeeklyDigest.week_start)
        )
    ) if weeks else []

    await db.execute(delete(DemoItem).where(DemoItem.user_id == user_id))
    await db.commit()
    return Removed(sorted(stale_days), sorted(stale_weeks))
