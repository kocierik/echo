"""Prices of the models Echo uses, for `make usage` (services/usage_report.py).

Token prices are USD per 1M tokens; "cached" is the price of input tokens served from the
provider's cache (part of the input count). Audio is USD per minute; web search, USD per
search (the pages it reads are billed as input tokens of the model that searched). A model
missing here costs "?" in the report. Change a price by editing this file.

Read on PRICES_READ_ON from public aggregators: OpenAI's pricing page refused automated
reads. NOT VERIFIED: check https://openai.com/api/pricing and https://deepgram.com/pricing
before setting customer prices.
"""

PRICES_READ_ON = "2026-10-16"

PRICES: dict[str, dict] = {
    # Most sources; one lists $0.20 / $0.02 / $1.00 as OpenAI's own rate
    "gpt-6-luna": {"unit": "token", "input": 0.10, "cached": 0.01, "output": 0.50},
    "text-embedding-3-small": {"unit": "token", "input": 0.02, "cached": 0.02, "output": 0.0},
    "gpt-4o-transcribe": {"unit": "second", "per_minute": 0.006},
    # Pre-recorded audio, pay as you go; sources give $0.0043 to $0.0077
    "nova-3": {"unit": "second", "per_minute": 0.0043},
    # Read on 2026-10-21; Brave and Perplexity Search are listed at ~$0.005
    "openai-web-search": {"unit": "search", "per_search": 0.010},
    # Local (voice fingerprints): no money cost, counted for the load
    "sherpa-onnx": {"unit": "second", "per_minute": 0.0},
}
