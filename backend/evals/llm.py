"""Evaluate an LLM on what Echo asks of it.

    python -m evals.llm --model gpt-6-luna --suite all

Suites:
  compat      the calls Echo makes: complete with a temperature, JSON mode, tools, streaming
  extraction  entities from Italian sentences (evals/cases/extraction.json)
  routing     memory / app / "not connected" for chat requests (evals/cases/routing.json)
  answers     memory answers from a fixed context: facts, language, no invention, and the
              time to the first streamed piece (evals/cases/answers.json)
  tools       the action agent's first tool for a request (evals/cases/tools.json)
"""

import argparse
import asyncio
import json
import time
import uuid
from datetime import date
from pathlib import Path

from app.actions.agent import SEARCH_MEMORY_TOOL, _system_prompt
from app.actions.availability import route_request
from app.actions.routine_tools import ROUTINE_TOOLS
from app.services.about_echo import about_echo
from app.services.analysis_pipeline import extract_entities
from app.services.language import clear_language, detect_language
from app.services.llm_base import LLMMessage
from app.services.llm_openai import openai_llm
from app.services.memory_answers import rag_system_prompt
from app.services.web_search import OpenAIWebSearch
from evals.scoring import Extracted, normalize_words, score_extraction

CASES = Path(__file__).parent / "cases"

_TOOL = {
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Weather for a city",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"],
        },
    },
}


async def _timed(coro):
    start = time.perf_counter()
    result = await coro
    return result, time.perf_counter() - start


async def compat(llm) -> bool:
    """Each call Echo makes, as Echo makes it."""
    user = [LLMMessage(role="user", content="Rispondi solo: ok")]
    json_messages = [
        LLMMessage(role="system", content='Rispondi in JSON: {"ok": true}'),
        LLMMessage(role="user", content="Va bene?"),
    ]
    checks = {
        "complete(temperature=0.3)": lambda: llm.complete(user, temperature=0.3),
        "complete_json(temperature=0.0)": lambda: llm.complete_json(json_messages, temperature=0.0),
        "complete_with_tools": lambda: llm.complete_with_tools(
            [LLMMessage(role="user", content="Che tempo fa a Roma?")], [_TOOL]
        ),
        "stream(temperature=0.3)": lambda: _collect(llm.stream(user, temperature=0.3)),
    }
    ok = True
    for name, call in checks.items():
        try:
            _, seconds = await _timed(call())
            print(f"  ok    {name:34} {seconds:5.1f}s")
        except Exception as exc:  # report every incompatibility, not just the first
            ok = False
            print(f"  FAIL  {name:34} {type(exc).__name__}: {str(exc)[:140]}")
    return ok


async def _collect(stream) -> str:
    return "".join([piece async for piece in stream])


async def extraction(llm) -> bool:
    suite = json.loads((CASES / "extraction.json").read_text(encoding="utf-8"))
    reference = date.fromisoformat(suite["reference_date"])
    passed, seconds = 0, 0.0
    for case in suite["cases"]:
        entities, elapsed = await _timed(
            extract_entities(
                llm,
                case["text"],
                uuid.uuid4(),
                uuid.uuid4(),
                uuid.uuid4(),
                known_people=suite["known_people"],
                reference_date=reference,
            )
        )
        seconds += elapsed
        result = score_extraction(
            case,
            [
                Extracted(e.entity_type, e.name, e.content or "", e.metadata_ or {})
                for e in entities
            ],
        )
        passed += result.passed
        mark = "ok  " if result.passed else "FAIL"
        print(f"  {mark}  {case['id']:32} {elapsed:4.1f}s")
        if not result.passed:
            for spec in result.missing:
                print(f"          missing   {spec}")
            for entity in result.forbidden:
                print(f"          unwanted  {entity.type}: {entity.name} {entity.metadata}")
            print(
                "          got       "
                + "; ".join(f"{e.entity_type}: {e.name} {e.metadata_}" for e in entities)
            )
    total = len(suite["cases"])
    print(f"  {passed}/{total} passed, {seconds / total:.1f}s per case")
    return passed == total


async def routing(llm) -> bool:
    suite = json.loads((CASES / "routing.json").read_text(encoding="utf-8"))
    passed = 0
    for case in suite["cases"]:
        route, elapsed = await _timed(route_request(llm, case["text"], [], suite["connected"]))
        ok = route.kind == case["expect"]
        passed += ok
        mark = "ok  " if ok else "FAIL"
        print(
            f"  {mark}  {case['id']:32} {route.kind:7} " f"(want {case['expect']}) {elapsed:4.1f}s"
        )
    total = len(suite["cases"])
    print(f"  {passed}/{total} passed")
    return passed == total


async def answers(llm) -> bool:
    suite = json.loads((CASES / "answers.json").read_text(encoding="utf-8"))
    passed, first_total, total_seconds = 0, 0.0, 0.0
    for case in suite["cases"]:
        # As in production: the prompt knows what Echo is; "empty" = nothing in memory
        question = case["question"]
        content = (
            f"(Nothing found in memory.)\n\nQuestion: {question}"
            if case.get("empty")
            else f"Context from memory:\n\n{suite['context']}\n\n---\n\nQuestion: {question}"
        )
        # "search": the web search tool is offered, as in production under the cap
        search = case.get("search", False)
        messages = [
            LLMMessage(
                role="system",
                content=rag_system_prompt(
                    None, about_echo([]), clear_language(question), can_search=search
                ),
            ),
            LLMMessage(role="user", content=content),
        ]
        options: dict = {}
        cited: list[dict] = []
        if search:
            options = {"hosted_tools": [OpenAIWebSearch().hosted_tool()],
                       "on_citations": cited.extend}
        start = time.perf_counter()
        first = None
        pieces = []
        async for piece in llm.stream(messages, temperature=0.3, **options):
            first = first or time.perf_counter() - start
            pieces.append(piece)
        seconds = time.perf_counter() - start
        answer = "".join(pieces)
        words = set(normalize_words(answer))
        problems = [f"missing {w!r}" for w in case.get("must", []) if w not in words]
        problems += [f"says {w!r}" for w in case.get("forbid", []) if w in words]
        problems += [f"none of {group}" for group in case.get("any", []) if not words & set(group)]
        if case.get("cites") is True and not cited:
            problems.append("no web source cited")
        if case.get("cites") is False and cited:
            problems.append(f"searched the web: {cited[0]['url']}")
        # The heuristic detector needs a few words: short answers are not checked
        if len(words) >= 8 and detect_language(answer) != case["language"]:
            problems.append(f"answered in {detect_language(answer)}")
        passed += not problems
        first_total += first or seconds
        total_seconds += seconds
        mark = "ok  " if not problems else "FAIL"
        print(f"  {mark}  {case['id']:20} first {first or 0:4.1f}s, all {seconds:4.1f}s")
        if problems:
            print(f"          {'; '.join(problems)} · {answer[:160]!r}")
    count = len(suite["cases"])
    print(
        f"  {passed}/{count} passed, first piece {first_total / count:.1f}s, "
        f"answer {total_seconds / count:.1f}s on average"
    )
    return passed == count


async def tools(llm) -> bool:
    suite = json.loads((CASES / "tools.json").read_text(encoding="utf-8"))
    # As in production: Echo's routine tools are always offered
    offered = [SEARCH_MEMORY_TOOL, *ROUTINE_TOOLS, *suite["tools"]]
    passed = 0
    for case in suite["cases"]:
        messages = [
            LLMMessage(role="system", content=_system_prompt(routines=True)),
            LLMMessage(role="user", content=case["request"]),
        ]
        response, elapsed = await _timed(llm.complete_with_tools(messages, offered))
        called = response.tool_calls[0].name if response.tool_calls else None
        ok = called in case["first"]
        # "args": what the first call must say (a routine's schedule)
        arguments = response.tool_calls[0].arguments if response.tool_calls else {}
        ok = ok and all(arguments.get(k) == v for k, v in case.get("args", {}).items())
        passed += ok
        mark = "ok  " if ok else "FAIL"
        print(f"  {mark}  {case['id']:22} {called or '(no tool)':28} {elapsed:4.1f}s")
        if not ok:
            print(f"          want one of {case['first']}; said {response.content[:120]!r}")
    count = len(suite["cases"])
    print(f"  {passed}/{count} passed")
    return passed == count


SUITES = {
    "compat": compat,
    "extraction": extraction,
    "routing": routing,
    "answers": answers,
    "tools": tools,
}


async def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--model", required=True, help="OpenAI model id, e.g. gpt-6-luna")
    parser.add_argument("--suite", default="all", choices=[*SUITES, "all"])
    parser.add_argument(
        "--reasoning-effort", default="", help='for reasoning models, e.g. "none" or "low"'
    )
    parser.add_argument("--api", default="chat", choices=["chat", "responses"])
    args = parser.parse_args()
    llm = openai_llm(args.model, args.reasoning_effort, args.api)
    all_ok = True
    for name, suite in SUITES.items():
        if args.suite in (name, "all"):
            effort = f", reasoning {args.reasoning_effort}" if args.reasoning_effort else ""
            print(f"\n{name} · {args.model} ({args.api}{effort})")
            all_ok &= await suite(llm)
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
