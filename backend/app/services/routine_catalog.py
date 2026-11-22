"""The catalog of ready-made routines: added from the app with one tap (Ask → Routines).

Each entry is a routine written well once, in the user's language, with a default time the
user can change before adding it. Added, it is an ordinary routine of theirs (source
"catalog", its `catalog_key` kept so the app shows it as added and can remove it). They
read only Echo's own memory: none needs an app.
"""

from dataclasses import dataclass

DEFAULT_LANGUAGE = "en"


@dataclass(frozen=True)
class CatalogRoutine:
    key: str
    emoji: str
    # language -> (title, summary, instruction, example)
    texts: dict[str, tuple[str, str, str, str]]
    schedule: dict
    mode: str = "always"

    def text(self, language: str) -> tuple[str, str, str, str]:
        return self.texts.get(language) or self.texts[DEFAULT_LANGUAGE]


CATALOG: tuple[CatalogRoutine, ...] = (
    CatalogRoutine(
        key="morning_brief",
        emoji="☀️",
        schedule={"kind": "daily", "time": "08:00"},
        texts={
            "it": (
                "Briefing del mattino",
                "Impegni, promesse in scadenza, chi vedi oggi",
                "Dimmi in breve cosa mi aspetta oggi, dalla mia memoria: gli impegni, le "
                "promesse in scadenza e le persone che vedrò.",
                "Oggi la riunione con Sara alle 10. Scade la promessa di mandare il budget "
                "ad Ada.",
            ),
            "en": (
                "Morning briefing",
                "Plans, promises due, who you'll see today",
                "Tell me briefly what today holds, from my memory: plans, promises due and "
                "the people I will see.",
                "The meeting with Sara at 10 today. The budget you promised Ada is due.",
            ),
        },
    ),
    CatalogRoutine(
        key="evening_diary",
        emoji="🌙",
        schedule={"kind": "daily", "time": "21:30"},
        mode="only_if",
        texts={
            "it": (
                "Diario della sera",
                "La tua giornata in poche righe",
                "Scrivi in poche righe com'è andata la mia giornata, dalle conversazioni di "
                "oggi: cosa ho fatto, chi ho visto, cosa resta da fare. Se oggi non ho "
                "parlato con nessuno, non scrivere niente.",
                "Mattina in ufficio sul progetto Atlas, pranzo con Ada. Resta da chiamare "
                "il dentista.",
            ),
            "en": (
                "Evening diary",
                "Your day in a few lines",
                "Write in a few lines how my day went, from today's conversations: what I "
                "did, who I saw, what is left to do. If I spoke with no one today, write "
                "nothing.",
                "Morning at the office on Atlas, lunch with Ada. Still to do: call the "
                "dentist.",
            ),
        },
    ),
    CatalogRoutine(
        key="weekly_summary",
        emoji="🗓️",
        schedule={"kind": "weekly", "time": "18:00", "days": [5]},
        texts={
            "it": (
                "Riassunto della settimana",
                "Decisioni, persone, cose aperte",
                "Riassumi la mia settimana dalle conversazioni: cosa è stato deciso, con chi "
                "ho parlato e cosa è rimasto aperto.",
                "Deciso: demo di Atlas il 2 dicembre. Hai visto Ada, Marco e Sara. Aperto: "
                "mandare il budget ad Ada.",
            ),
            "en": (
                "Week in review",
                "Decisions, people, open things",
                "Summarize my week from my conversations: what was decided, who I spoke "
                "with and what is still open.",
                "Decided: the Atlas demo on December 2. You saw Ada, Marco and Sara. Open: "
                "send Ada the budget.",
            ),
        },
    ),
    CatalogRoutine(
        key="open_promises",
        emoji="🤝",
        schedule={"kind": "weekly", "time": "09:00", "days": [1]},
        mode="only_if",
        texts={
            "it": (
                "Promesse da mantenere",
                "Cosa hai detto che avresti fatto",
                "Elenca le promesse che ho fatto nelle conversazioni e non ho ancora "
                "mantenuto: cosa, a chi e per quando. Se non ce ne sono, non scrivere "
                "niente.",
                "Mandare il budget ad Ada (entro venerdì). Richiamare Tom per il report.",
            ),
            "en": (
                "Promises to keep",
                "What you said you would do",
                "List the promises I made in my conversations and have not kept yet: what, "
                "to whom and by when. If there are none, write nothing.",
                "Send Ada the budget (by Friday). Call Tom back about the report.",
            ),
        },
    ),
    CatalogRoutine(
        key="keep_in_touch",
        emoji="👋",
        schedule={"kind": "weekly", "time": "18:00", "days": [7]},
        mode="only_if",
        texts={
            "it": (
                "Persone da risentire",
                "Chi non senti da un po'",
                "Tra le persone con cui parlavo spesso, dimmi quelle che non sento da più di "
                "due settimane. Se non ce ne sono, non scrivere niente.",
                "Non senti Giulia da 3 settimane: l'ultima volta parlavate del trasloco a "
                "Torino.",
            ),
            "en": (
                "People to catch up with",
                "Who you haven't heard from lately",
                "Among the people I used to talk with often, tell me those I have not heard "
                "from in over two weeks. If there are none, write nothing.",
                "You haven't heard from Giulia in 3 weeks: last time you talked about her "
                "move to Turin.",
            ),
        },
    ),
    CatalogRoutine(
        key="monthly_expenses",
        emoji="💶",
        schedule={"kind": "monthly", "time": "09:00", "day_of_month": 1},
        mode="only_if",
        texts={
            "it": (
                "Spese del mese",
                "Quanto hai speso, dagli scontrini salvati",
                "Fammi il riepilogo delle spese del mese scorso dagli scontrini che ho "
                "salvato: il totale e le voci più grandi. Se non ne ho salvati, non scrivere "
                "niente.",
                "Novembre: 412 € in 9 scontrini. Le voci più grandi: spesa (186 €), cene "
                "(94 €).",
            ),
            "en": (
                "Monthly spending",
                "What you spent, from saved receipts",
                "Summarize last month's spending from the receipts I saved: the total and "
                "the biggest items. If I saved none, write nothing.",
                "November: €412 across 9 receipts. Biggest: groceries (€186), dinners "
                "(€94).",
            ),
        },
    ),
)

BY_KEY = {entry.key: entry for entry in CATALOG}
