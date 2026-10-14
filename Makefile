# Echo — Development Commands
.PHONY: help up down build logs logs-api logs-worker test test-all lint fmt deploy db-reset db-migrate \
	db-new-migration shell worker create-key revoke-example-key \
	eval-llm eval-stt-collect eval-stt

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- Docker ---

up: ## Start all services
	docker compose up -d

down: ## Stop all services
	docker compose down

build: ## Rebuild Docker images
	docker compose build

logs: ## Tail all logs
	docker compose logs -f

logs-api: ## Tail API logs
	docker compose logs -f api

logs-worker: ## Tail worker logs
	docker compose logs -f worker

# --- Development ---

test: ## Run the DB-free unit tests in the api container
	docker compose exec -T api python -m pytest tests/test_adpcm_decoder.py tests/test_temporal.py \
		tests/test_chunking.py tests/test_circuit_breaker.py -q -p no:cacheprovider --noconftest

# The tests delete data, so they run on their own database and Redis db, never on echo
TEST_ENV = -e DATABASE_URL=postgresql+asyncpg://echo:echo@postgres:5432/echo_test \
	-e REDIS_URL=redis://redis:6379/15

test-all: ## Run all tests in the api container on the echo_test database
	docker compose exec -T postgres psql -U echo -d postgres -tAc \
		"SELECT 1 FROM pg_database WHERE datname = 'echo_test'" | grep -q 1 || \
		docker compose exec -T postgres psql -U echo -d postgres -c "CREATE DATABASE echo_test"
	docker compose exec -T $(TEST_ENV) api python -m alembic upgrade head
	docker compose exec -T $(TEST_ENV) api python -m pytest tests/ -q -p no:cacheprovider

eval-llm: ## Evaluate an LLM (real API calls): make eval-llm MODEL=gpt-6-luna EFFORT=none SUITE=all
	docker compose exec -T api python -m evals.llm --model "$(MODEL)" --suite "$(or $(SUITE),all)" \
		--reasoning-effort "$(EFFORT)"

eval-stt-collect: ## Save recent transcribed clips for the STT comparison (git-ignored)
	docker compose exec -T api python -m evals.stt collect --limit "$(or $(LIMIT),50)"

eval-stt: ## Compare STT services: make eval-stt PROVIDERS=deepgram:nova-3,openai:gpt-transcribe
	docker compose exec -T api python -m evals.stt run --providers "$(PROVIDERS)"

lint: ## Run ruff linter in the api container
	docker compose exec -T api python -m ruff check app/ tests/ evals/

fmt: ## Auto-format code with ruff in the api container
	docker compose exec -T api python -m ruff format app/ tests/ evals/
	docker compose exec -T api python -m ruff check --fix app/ tests/ evals/

# --- Deploy ---

deploy: ## Full deploy: build, migrate, restart (idempotent, always safe)
	bash scripts/deploy.sh

# --- Database ---

db-reset: ## Drop and recreate database schema (DESTRUCTIVE)
	docker compose exec -T postgres psql -U echo -d echo -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
	docker compose exec api python -m alembic upgrade head

db-migrate: ## Run pending Alembic migrations (idempotent)
	docker compose exec api python -m alembic upgrade head

db-new-migration: ## Generate a new migration (usage: make db-new-migration MSG="add xyz")
	docker compose exec api python -m alembic revision --autogenerate -m "$(MSG)"

# --- Utilities ---

shell: ## Open a shell in the API container
	docker compose exec api bash

worker: ## Restart the worker
	docker compose restart worker

create-key: ## Create an API key and print it once (random unless KEY=... is given)
	@KEY="$${KEY:-$$(openssl rand -hex 32)}"; \
	docker compose exec -T postgres psql -U echo -d echo -q -c "INSERT INTO api_keys (user_id, key_hash, name) VALUES ('a0000000-0000-0000-0000-000000000001', encode(sha256('$$KEY'::bytea), 'hex'), 'key-$$(date +%Y%m%d-%H%M%S)') ON CONFLICT DO NOTHING;" && \
	echo "API key (shown only now): $$KEY"

revoke-example-key: ## Delete the README's example key 'my-secret-key' (publicly known)
	docker compose exec -T postgres psql -U echo -d echo -c "DELETE FROM api_keys WHERE key_hash = encode(sha256('my-secret-key'::bytea), 'hex');"
