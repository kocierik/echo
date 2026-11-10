import unicodedata


def _normalized_label(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", value).casefold().split())


def normalize_topics(raw: object, people: list[str]) -> list[str]:
    if not isinstance(raw, list):
        return []

    person_names = {_normalized_label(person) for person in people if isinstance(person, str)}
    topics: list[str] = []
    seen: set[str] = set()
    for candidate in raw:
        if not isinstance(candidate, str):
            continue
        topic = _normalized_label(candidate)
        if (
            not topic
            or len(topic) > 40
            or not 1 <= len(topic.split()) <= 3
            or topic in person_names
            or topic in seen
        ):
            continue
        seen.add(topic)
        topics.append(topic)
        if len(topics) == 3:
            break
    return topics
