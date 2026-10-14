"""Model evaluations against real providers (run by hand: they cost money).

make eval-llm MODEL=gpt-4o-mini SUITE=all
make eval-stt-collect   # then correct evals/data/stt/*.ref.txt by hand
make eval-stt PROVIDERS=deepgram:nova-3,openai:gpt-transcribe
"""
