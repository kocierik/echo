"""What Echo is and can do, for the memory prompt: "cosa sai fare?" gets a real answer.

The apps listed are those Echo works with, not those the user has connected: finding out
which are connected would cost a Composio call on every question.
"""

import logging

from app.actions.availability import APP_NAMES
from app.actions.phone_provider import PHONE_APP_NAMES, phone_apps

logger = logging.getLogger(__name__)


def about_echo(phone_apps_on: list[str]) -> str:
    """English text for the prompt; `phone_apps_on` are the phone's apps the app turned on."""
    apps = ", ".join(APP_NAMES.values())
    phone = [PHONE_APP_NAMES[slug] for slug in phone_apps_on if slug in PHONE_APP_NAMES]
    lines = [
        "Echo is a wearable the user wears and an app on their phone. Echo:",
        "- remembers the user's conversations: it transcribes them, knows who spoke and "
        "keeps the people, tasks, promises, ideas and events that came up;",
        "- answers questions about them, by chat (Ask) or by voice;",
        "- writes a summary of every day and of every week;",
        f"- acts in the user's apps when asked ({apps}): they are connected in Settings → "
        "Apps; sending to others, changing and deleting wait for the user's Confirm;",
    ]
    if phone:
        lines.append(f"- uses these apps on the phone: {', '.join(phone)};")
    lines += [
        "- takes a photo with the wearable's camera when asked (or the button) and says "
        "what it shows;",
        "- hears requests spoken to the wearable that start with \"Echo, …\";",
        "- learns the user's voice (Settings → Voices) to tell who is speaking.",
        "What Echo can do (Settings) has examples to try. Examples of questions: "
        "\"What did Marco say about the offer?\", \"What did I promise this week?\", "
        "\"Echo, remind me to call Ada at 6\", \"Echo, what is this?\".",
    ]
    return "\n".join(lines)


async def about_echo_for(redis_client, user_id) -> str:
    """`about_echo` with the phone apps this user turned on; none if Redis fails."""
    try:
        on = await phone_apps(redis_client, user_id) if redis_client is not None else []
    except Exception:
        logger.warning("Could not read the phone's apps for the memory prompt", exc_info=True)
        on = []
    return about_echo(on)
