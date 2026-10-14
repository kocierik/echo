"""Evaluate an LLM on what Echo asks of it.

    python -m evals.llm --model gpt-6-luna --suite all

Suites:
  compat      the calls Echo makes: complete with a temperature, JSON mode, tools, streaming
  extraction  entities from Italian sentences (evals/cases/extraction.json)
  routing     memory / app / "not connected" for chat requests (evals/cases/routing.json)
"""

import argparse
import asyncio
import json
import time
import uuid
from datetime import date
from pathlib import Path

from app.actions.availability import route_request
from app.services.analysis_pipeline import extract_entities
from app.services.llm_base import LLMMessage
from app.services.llm_openai import OpenAILLMService
from evals.scoring import Extracted, score_extraction

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
            f"  {mark}  {case['id']:32} {route.kind:7} "
            f"(want {case['expect']}) {elapsed:4.1f}s"
        )
    total = len(suite["cases"])
    print(f"  {passed}/{total} passed")
    return passed == total


SUITES = {"compat": compat, "extraction": extraction, "routing": routing}


async def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--model", required=True, help="OpenAI model id, e.g. gpt-6-luna")
    parser.add_argument("--suite", default="all", choices=[*SUITES, "all"])
    parser.add_argument(
        "--reasoning-effort", default="", help='for reasoning models, e.g. "none" or "low"'
    )
    args = parser.parse_args()
    llm = OpenAILLMService(model=args.model, reasoning_effort=args.reasoning_effort)
    all_ok = True
    for name, suite in SUITES.items():
        if args.suite in (name, "all"):
            effort = f" (reasoning {args.reasoning_effort})" if args.reasoning_effort else ""
            print(f"\n{name} · {args.model}{effort}")
            all_ok &= await suite(llm)
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
