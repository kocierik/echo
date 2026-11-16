"""Scoring for the evaluations: pure functions, unit-tested without any provider."""

import re
import unicodedata
from dataclasses import dataclass, field


def normalize_words(text: str) -> list[str]:
    """Lowercase words without punctuation or accents ("Perché, sì!" -> ["perche", "si"])."""
    text = unicodedata.normalize("NFKD", text.lower())
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.findall(r"[a-z0-9]+", text)


def word_error_rate(reference: str, hypothesis: str) -> float:
    """Word-level edit distance over the reference length (0.0 = identical).

    An empty reference scores 0.0 for an empty hypothesis and 1.0 otherwise.
    """
    ref, hyp = normalize_words(reference), normalize_words(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0
    previous = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, start=1):
        current = [i]
        for j, h in enumerate(hyp, start=1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r != h)))
        previous = current
    return previous[-1] / len(ref)


@dataclass(frozen=True)
class Extracted:
    """An extracted entity, as the scorer sees it."""

    type: str
    name: str
    content: str = ""
    metadata: dict = field(default_factory=dict)
    # The conversation line it cites (1-based), for a case given as numbered lines
    line: int | None = None


# Expectation keys checked against the entity's metadata. "date" accepts a task's
# due_date or an event's event_date (some sentences are fairly either).
_METADATA_KEYS = ("due_date", "event_date", "event_time")


def _matches(entity: Extracted, spec: dict) -> bool:
    if entity.type not in spec["types"]:
        return False
    words = set(normalize_words(f"{entity.name} {entity.content}"))
    if not all(set(normalize_words(k)) <= words for k in spec.get("keywords", [])):
        return False
    for key in _METADATA_KEYS:
        if key in spec and str(entity.metadata.get(key, "")) != spec[key]:
            return False
    if "line" in spec and entity.line != spec["line"]:
        return False
    if "promise" in spec and bool(entity.metadata.get("promise")) != spec["promise"]:
        return False
    if "expected" in spec and bool(entity.metadata.get("expected")) != spec["expected"]:
        return False
    if "expected_from" in spec and spec["expected_from"] not in normalize_words(
        str(entity.metadata.get("expected_from", ""))
    ):
        return False
    if "promise_to" in spec and spec["promise_to"] not in normalize_words(
        str(entity.metadata.get("promise_to", ""))
    ):
        return False
    if "date" in spec and spec["date"] not in (
        entity.metadata.get("due_date"),
        entity.metadata.get("event_date"),
    ):
        return False
    return True


@dataclass(frozen=True)
class CaseResult:
    case_id: str
    missing: list[dict]
    forbidden: list[Extracted]

    @property
    def passed(self) -> bool:
        return not self.missing and not self.forbidden


def score_extraction(case: dict, extracted: list[Extracted]) -> CaseResult:
    """Every `expect` spec must match an entity; no entity may match a `forbid` spec."""
    missing = [
        spec for spec in case.get("expect", []) if not any(_matches(e, spec) for e in extracted)
    ]
    forbidden = [e for e in extracted for spec in case.get("forbid", []) if _matches(e, spec)]
    return CaseResult(case["id"], missing, forbidden)
