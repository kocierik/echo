"""Making an assistant by answering a few questions (Profile → Assistants → New).

As in GPT Builder's "Create" tab and Gemini's Gems: a template asks its own questions
(written here, no model call), one made from scratch first says what it is for and gets
questions made for that topic; the answers become a proposal (name, emoji, instructions,
first notes) the user reviews in the editor before saving. "Improve" turns a few words of
instructions into full ones, like Gems' "re-write with Gemini".
"""

import logging
import re

from app.services.assistants import (
    DEFAULT_EMOJI,
    MAX_INSTRUCTIONS,
    MAX_NAME,
    MAX_NOTES,
    AssistantError,
    template,
)
from app.services.llm_base import LLMMessage

logger = logging.getLogger(__name__)

MAX_QUESTIONS = 4
MAX_OPTIONS = 6
# What a proposal may use of the limits: room is left for the user and for the notes
# the assistant adds itself
PROPOSED_INSTRUCTIONS = 1200
PROPOSED_NOTES = 600


def _q(qid: str, text: str, options: list[str], multi: bool = False, hint: str = "") -> dict:
    return {"id": qid, "text": text, "options": options, "multi": multi, "hint": hint}


# A template's own questions: what its instructions cannot know about the user
QUESTIONS = {
    "work": {
        "it": [
            _q("role", "Che lavoro fai?", ["Sviluppatore", "Manager", "Freelance", "Studente"],
               hint="Es. DevOps engineer in un'azienda di viaggi"),
            _q("focus", "In cosa ti deve aiutare di più?",
               ["Scadenze e priorità", "Riunioni e decisioni", "Chi fa cosa",
                "Scrivere email e documenti"], multi=True),
            _q("tone", "Come vuoi che risponda?",
               ["Breve e diretto", "Dettagliato", "A elenchi puntati"]),
        ],
        "en": [
            _q("role", "What is your job?", ["Developer", "Manager", "Freelancer", "Student"],
               hint="E.g. DevOps engineer at a travel company"),
            _q("focus", "What should it help with most?",
               ["Deadlines and priorities", "Meetings and decisions", "Who does what",
                "Writing emails and documents"], multi=True),
            _q("tone", "How should it answer?",
               ["Short and direct", "Detailed", "In bullet points"]),
        ],
    },
    "diet": {
        "it": [
            _q("goal", "Qual è il tuo obiettivo?",
               ["Perdere peso", "Mangiare più vario", "Più energia", "Prendere massa"]),
            _q("limits", "Allergie, intolleranze o cose che non mangi?",
               ["Nessuna", "Vegetariano", "Vegano", "Senza glutine", "Senza lattosio"],
               multi=True, hint="Es. niente funghi"),
            _q("help", "Come deve seguirti?",
               ["Annota i pasti che ti dico", "Proponi idee per i pasti",
                "Ricordami di bere acqua"], multi=True),
        ],
        "en": [
            _q("goal", "What is your goal?",
               ["Lose weight", "Eat more varied", "More energy", "Build muscle"]),
            _q("limits", "Allergies, intolerances or things you don't eat?",
               ["None", "Vegetarian", "Vegan", "Gluten free", "Lactose free"],
               multi=True, hint="E.g. no mushrooms"),
            _q("help", "How should it follow you?",
               ["Note the meals I tell it", "Suggest meal ideas", "Remind me to drink water"],
               multi=True),
        ],
    },
    "sleep": {
        "it": [
            _q("improve", "Cosa vuoi migliorare?",
               ["Addormentarmi prima", "Svegliarmi meno di notte", "Svegliarmi riposato",
                "Orari regolari"], multi=True),
            _q("times", "A che ora vorresti andare a letto e svegliarti?",
               ["22:30 – 6:30", "23:00 – 7:00", "00:00 – 8:00"], hint="Es. 23:30 – 7:15"),
            _q("awake", "Cosa ti tiene sveglio?",
               ["Il telefono a letto", "Caffè nel pomeriggio", "Lo stress", "Orari di lavoro"],
               multi=True),
        ],
        "en": [
            _q("improve", "What do you want to improve?",
               ["Fall asleep earlier", "Wake up less at night", "Wake up rested",
                "Regular hours"], multi=True),
            _q("times", "When would you like to go to bed and wake up?",
               ["22:30 – 6:30", "23:00 – 7:00", "00:00 – 8:00"], hint="E.g. 23:30 – 7:15"),
            _q("awake", "What keeps you awake?",
               ["The phone in bed", "Afternoon coffee", "Stress", "Work hours"], multi=True),
        ],
    },
    "fitness": {
        "it": [
            _q("sport", "Che sport fai?", ["Corsa", "Palestra", "Ciclismo", "Nuoto", "Padel"],
               multi=True),
            _q("goal", "Il tuo obiettivo?",
               ["Una gara", "Diventare più forte", "Dimagrire", "Restare in forma"],
               hint="Es. 10 km sotto i 50 minuti a marzo"),
            _q("often", "Quante volte a settimana ti alleni?", ["1–2", "3–4", "5 o più"]),
        ],
        "en": [
            _q("sport", "Which sports do you do?",
               ["Running", "Gym", "Cycling", "Swimming", "Padel"], multi=True),
            _q("goal", "Your goal?", ["A race", "Get stronger", "Lose weight", "Stay fit"],
               hint="E.g. 10k under 50 minutes in March"),
            _q("often", "How many times a week do you train?", ["1–2", "3–4", "5 or more"]),
        ],
    },
    "money": {
        "it": [
            _q("use", "A cosa ti serve?",
               ["Tenere traccia delle spese", "Risparmiare per un obiettivo",
                "Bollette e scadenze", "Spese divise con altri"], multi=True),
            _q("budget", "Hai un budget o un obiettivo?", [],
               hint="Es. 300 € al mese per la spesa, 2.000 € per un viaggio"),
            _q("detail", "Quanto dettaglio vuoi?",
               ["Solo i totali", "Per categoria", "Ogni spesa"]),
        ],
        "en": [
            _q("use", "What is it for?",
               ["Tracking expenses", "Saving for a goal", "Bills and due dates",
                "Shared expenses"], multi=True),
            _q("budget", "Do you have a budget or a goal?", [],
               hint="E.g. 300 € a month for groceries, 2,000 € for a trip"),
            _q("detail", "How much detail?", ["Totals only", "By category", "Every expense"]),
        ],
    },
    "study": {
        "it": [
            _q("what", "Cosa studi?",
               ["Università", "Una lingua", "Un corso online", "Una certificazione"],
               hint="Es. Ingegneria informatica, 2º anno"),
            _q("exam", "Hai un esame o una scadenza?", [], hint="Es. Analisi 2 il 20 gennaio"),
            _q("method", "Come ti deve aiutare?",
               ["Un piano di studio", "Ripassare con domande", "Riassunti",
                "Ricordarmi di studiare"], multi=True),
        ],
        "en": [
            _q("what", "What do you study?",
               ["University", "A language", "An online course", "A certification"],
               hint="E.g. Computer engineering, 2nd year"),
            _q("exam", "Do you have an exam or a deadline?", [],
               hint="E.g. Calculus 2 on 20 January"),
            _q("method", "How should it help?",
               ["A study plan", "Revising with questions", "Summaries", "Reminding me to study"],
               multi=True),
        ],
    },
}

# From scratch, when the model cannot make questions for the topic
GENERIC = {
    "it": [
        _q("goal", "Qual è l'obiettivo?", [], hint="Es. correre una maratona in primavera"),
        _q("keep", "Cosa deve ricordare per te?", [], hint="Es. allenamenti, tempi, dolori"),
        _q("tone", "Come vuoi che risponda?",
           ["Breve e diretto", "Incoraggiante", "Dettagliato"]),
    ],
    "en": [
        _q("goal", "What is the goal?", [], hint="E.g. run a marathon in spring"),
        _q("keep", "What should it remember for you?", [], hint="E.g. workouts, times, pains"),
        _q("tone", "How should it answer?", ["Short and direct", "Encouraging", "Detailed"]),
    ],
}


def _lang(language: str) -> str:
    return "it" if language == "it" else "en"


def _clean_questions(raw) -> list[dict]:
    """The model's questions, checked: text, a few short options, nothing else."""
    out: list[dict] = []
    for index, item in enumerate(raw if isinstance(raw, list) else []):
        if not isinstance(item, dict):
            continue
        text = " ".join(str(item.get("text") or "").split())[:160]
        if not text:
            continue
        options = [
            " ".join(str(o).split())[:40]
            for o in (item.get("options") or [])
            if isinstance(o, str | int | float) and str(o).strip()
        ][:MAX_OPTIONS]
        out.append(_q(
            f"q{index + 1}", text, options, multi=bool(item.get("multi")),
            hint=" ".join(str(item.get("hint") or "").split())[:80],
        ))
        if len(out) == MAX_QUESTIONS:
            break
    return out


async def questions(llm, language: str, *, key: str | None, topic: str | None) -> list[dict]:
    """A template's questions, or ones made for a topic (the generic ones if that fails)."""
    lang = _lang(language)
    if key:
        if key not in QUESTIONS:
            raise AssistantError("No such template")
        return QUESTIONS[key][lang]
    topic = " ".join((topic or "").split())[:300]
    if not topic:
        raise AssistantError("Say what the assistant is for")
    language_name = "Italian" if lang == "it" else "English"
    messages = [
        LLMMessage(role="system", content=(
            "The user is making a personal assistant for one part of their life, inside a "
            "memory app that hears their day. Ask the 3 questions whose answers would most "
            "change how this assistant helps them: their goal, their situation, what it "
            "should keep track of, how it should answer. Each question short, in "
            f"{language_name}, with 3 to 5 short tap-to-answer options (none when only "
            "free text makes sense), multi true when several options can apply, and a short "
            "example answer as hint. Never ask for passwords, health records or bank details.\n"
            'Answer in JSON: {"questions": [{"text": "...", "options": ["..."], '
            '"multi": false, "hint": "..."}]}'
        )),
        LLMMessage(role="user", content=f"The assistant is for: {topic}"),
    ]
    try:
        result = await llm.complete_json(messages, temperature=0.4)
        made = _clean_questions(result.get("questions"))
    except Exception:
        logger.warning("Could not make questions for an assistant", exc_info=True)
        made = []
    return made if len(made) >= 2 else GENERIC[lang]


def _clean_emoji(value, fallback: str) -> str:
    emoji = str(value or "").strip()[:8]
    # Letters are a word, not an emoji
    return emoji if emoji and not re.search(r"[A-Za-z0-9]", emoji) else fallback


def _clean_notes(value) -> str:
    lines = value if isinstance(value, list) else str(value or "").splitlines()
    kept = []
    for line in lines:
        line = " ".join(str(line).split()).lstrip("-• ").strip()
        if line:
            kept.append(f"- {line[:200]}")
    notes = ""
    for line in kept[:6]:
        if len(notes) + len(line) + 1 > PROPOSED_NOTES:
            break
        notes = f"{notes}\n{line}" if notes else line
    return notes


def _answers_text(answers: list[dict]) -> str:
    lines = []
    for item in answers[:MAX_QUESTIONS * 2]:
        question = " ".join(str(item.get("question") or "").split())[:200]
        answer = " ".join(str(item.get("answer") or "").split())[:500]
        if question and answer:
            lines.append(f"Q: {question}\nA: {answer}")
    return "\n".join(lines) or "(no answers)"


async def compose(
    llm, language: str, *, key: str | None, topic: str | None, answers: list[dict]
) -> dict:
    """The proposal from the answers: {name, emoji, instructions, notes}."""
    lang = _lang(language)
    base = template(key, language) if key else None
    language_name = "Italian" if lang == "it" else "English"
    start = (
        f'Start from this template ("{base["name"]}" {base["emoji"]}) and keep what it '
        f"says, adapted to the answers:\n{base['instructions']}"
        if base else f"It is for: {' '.join((topic or '').split())[:300] or 'the user will say'}"
    )
    messages = [
        LLMMessage(role="system", content=(
            "You write a personal assistant for the user, inside a memory app that hears "
            "their day (Echo). From the template or topic and the user's answers write, in "
            f"{language_name}:\n"
            f"- name: 1-3 words, at most {MAX_NAME} characters;\n"
            "- emoji: one emoji for the topic;\n"
            "- instructions: addressed to the assistant in the second person (\"You are "
            "my...\"), from the user's point of view: its role, what to note in its notes, "
            "how to answer (the tone chosen), what to watch for and remind; concrete, using "
            f"the answers, at most {PROPOSED_INSTRUCTIONS} characters, plain text;\n"
            "- notes: the facts from the answers worth keeping (goal, limits, times, "
            "budget, exam dates), one short line each, at most 6 lines.\n"
            "Health topics: general guidance only, never diagnoses or prescriptions. Money: "
            "no investment advice.\n"
            'Answer in JSON: {"name": "...", "emoji": "...", "instructions": "...", '
            '"notes": ["..."]}'
        )),
        LLMMessage(
            role="user", content=f"{start}\n\nThe user's answers:\n{_answers_text(answers)}"
        ),
    ]
    try:
        result = await llm.complete_json(messages, temperature=0.4)
    except Exception as exc:
        logger.warning("Could not write an assistant", exc_info=True)
        raise AssistantError("Echo could not write it now: try again", 503) from exc
    name = " ".join(str(result.get("name") or "").split())[:MAX_NAME] or (
        base["name"] if base else ""
    )
    instructions = str(result.get("instructions") or "").strip()[:MAX_INSTRUCTIONS]
    if not instructions:
        if base is None:
            raise AssistantError("Echo could not write it now: try again", 503)
        instructions = base["instructions"]
    return {
        "name": name or ("Assistente" if lang == "it" else "Assistant"),
        "emoji": _clean_emoji(result.get("emoji"), base["emoji"] if base else DEFAULT_EMOJI),
        "instructions": instructions,
        "notes": _clean_notes(result.get("notes"))[:MAX_NOTES],
    }


async def improve(llm, language: str, *, name: str, instructions: str) -> str:
    """A few words of instructions made into full ones, keeping everything they say."""
    instructions = (instructions or "").strip()
    if len(instructions) < 3:
        raise AssistantError("Write a few words first")
    language_name = "Italian" if _lang(language) == "it" else "English"
    messages = [
        LLMMessage(role="system", content=(
            "Rewrite the user's instructions for their personal assistant (inside Echo, a "
            "memory app that hears their day) into clear, complete ones: its role, what to "
            "keep in its notes, how to answer, what to watch for. Keep every wish the user "
            "wrote, add nothing they would not want, second person (\"You are my...\"), "
            f"in {language_name}, at most {PROPOSED_INSTRUCTIONS} characters, plain text.\n"
            'Answer in JSON: {"instructions": "..."}'
        )),
        LLMMessage(
            role="user",
            content=f"Assistant: {name or '(no name yet)'}\n\n{instructions[:MAX_INSTRUCTIONS]}",
        ),
    ]
    try:
        result = await llm.complete_json(messages, temperature=0.3)
    except Exception as exc:
        logger.warning("Could not improve instructions", exc_info=True)
        raise AssistantError("Echo could not rewrite them now: try again", 503) from exc
    better = str(result.get("instructions") or "").strip()[:MAX_INSTRUCTIONS]
    if not better:
        raise AssistantError("Echo could not rewrite them now: try again", 503)
    return better
