"""Charts in Ask's answers: the model writes a small JSON block the app draws (bars, a
line, a pie, a progress bar), as ChatGPT draws charts in its replies. Only in typed chat:
a spoken answer or a notification has no screen for it. The app's side is
mobile/lib/widgets/echo_chart.dart; a block it cannot read is left out.
"""

CHART_FENCE = "echo-chart"

VISUALS_RULES = f"""- Charts: when the answer compares or follows at least 3 numbers that come \
from the context or a tool result (spending by category, hours slept per night, km per week, \
messages per person), add ONE chart after the sentence that says the main number. Never \
invent or estimate a number for a chart; no chart for one or two numbers. Write it as a \
fenced block, exactly:
```{CHART_FENCE}
{{"type": "bar", "title": "Spese di ottobre", "unit": "€", "labels": ["Spesa", "Casa"], \
"values": [280, 160]}}
```
types: "bar" (categories, at most 12), "line" (over time, at most 31 points; several \
lines as "series": [{{"name": "...", "values": [...]}}] instead of "values"), "pie" (parts \
of a whole, at most 8), "progress" (one value against a target: {{"type": "progress", \
"title": "Budget", "unit": "€", "value": 640, "max": 700}}). Labels short, in the user's \
language; numbers plain (no thousands separators). For a list of items with several \
details use a Markdown table instead.
"""
