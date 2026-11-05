"""Charts in Ask's answers: the model writes a small JSON block the app draws (columns,
bars, a line, a pie, a progress bar), as ChatGPT draws charts in its replies. Only in typed
chat: a spoken answer or a notification has no screen for it. The app's side is
mobile/lib/widgets/echo_chart.dart; a block it cannot read is left out.
"""

CHART_FENCE = "echo-chart"

VISUALS_RULES = f"""- Charts: add one on your own, without being asked, whenever the answer is \
about numbers across days, weeks or months, or across categories, and at least 4 of them \
come from the context or a tool result (sleep this week, spending by category, km per \
week, a price over the year, messages per person). Put it after the sentence that says \
the main number. Never invent, estimate or fill in a number; never chart 2 or 3 points: \
for a value over a period (a stock, a price), first get enough points from the tool or \
the web (one per month for a year, one per day for a week), else answer without a chart. \
Write it as a fenced block, exactly:
```{CHART_FENCE}
{{"type": "column", "title": "Sonno della settimana", "unit": "h", "labels": ["lun", \
"mar", "mer", "gio"], "values": [6.9, 6.4, 7.5, 5.7], "target": 8, "note": "Giovedì la \
notte più corta, sotto l'obiettivo di 8 ore"}}
```
types: "column" (days, weeks, months: at most 14 columns), "bar" (categories, at most 12, \
the largest first), "line" (a trend over many points, at most 31; several lines as \
"series": [{{"name": "...", "values": [...]}}] instead of "values"), "pie" (parts of a \
whole, at most 8), "progress" (one value against a target: {{"type": "progress", \
"title": "Budget di novembre", "unit": "€", "value": 640, "max": 700}}). Optional: \
"target" (a goal, a budget, a limit: drawn as a dashed line) and "note" (one short \
sentence saying what the chart shows: the highest, the trend, against the target). \
Labels short, in the user's language; numbers plain (no thousands separators). For a list \
of items with several details use a Markdown table instead.
"""
