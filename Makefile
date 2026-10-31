# Echo — Development Commands
.PHONY: help up down build logs logs-api logs-worker test test-all lint fmt deploy db-reset db-migrate \
	db-new-migration shell worker create-key create-user set-password set-plan revoke-example-key \
	eval-llm eval-stt-collect eval-stt usage runs coverage-new

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

# The new code of each unit, held to 80% line coverage: each unit adds its files here
NEW_CODE = app/core/runs.py,app/core/request_budget.py,app/core/redaction.py,$\
	app/models/agent_run.py,app/cli/runs.py
# Coverage data stays in the container, never in the working tree
COVERAGE_ENV = -e COVERAGE_FILE=/tmp/.coverage-echo

coverage-new: ## Line coverage of the new code (NEW_CODE), at least 80%; runs the whole suite
	docker compose exec -T postgres psql -U echo -d postgres -tAc \
		"SELECT 1 FROM pg_database WHERE datname = 'echo_test'" | grep -q 1 || \
		docker compose exec -T postgres psql -U echo -d postgres -c "CREATE DATABASE echo_test"
	docker compose exec -T $(TEST_ENV) api python -m alembic upgrade head
	docker compose exec -T $(TEST_ENV) $(COVERAGE_ENV) api python -m pytest tests/ -q \
		-p no:cacheprovider --cov=app --cov-report=; tests=$$?; \
	docker compose exec -T $(COVERAGE_ENV) api python -m coverage report -m \
		--include="$(NEW_CODE)" --fail-under=80 && exit $$tests

usage: ## What a day of Echo costs, per user and kind of work: make usage [DAYS=7]
	docker compose exec -T api python -m app.cli.usage --days "$(or $(DAYS),7)"

# USER is also the shell's login name: only a USER=... given to make selects a user
runs: ## Tracked runs: make runs CID=<correlation id>, or make runs USER=<email or id> [LAST=10]
	docker compose exec -T api python -m app.cli.runs \
		$(if $(CID),--cid "$(CID)") \
		$(if $(filter command line,$(origin USER)),--user "$(USER)") \
		--last "$(or $(LAST),10)"

eval-llm: ## Evaluate an LLM (real API calls): make eval-llm MODEL=gpt-6-luna EFFORT=none SUITE=all
	docker compose exec -T api python -m evals.llm --model "$(MODEL)" --suite "$(or $(SUITE),all)" \
		--reasoning-effort "$(EFFORT)" --api "$(or $(API),chat)"

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

firmware-release: ## Build the wearable firmware and publish it for the app: make firmware-release NOTES="..."
	bash scripts/firmware-release.sh "$(NOTES)"

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

create-user: ## Create an account (asks the password): make create-user EMAIL=you@example.com [NEW=1 for another person]
	@if [ -n "$(NEW)" ]; then \
		docker compose exec api python -m app.cli.users create --email "$(EMAIL)"; \
	else \
		docker compose exec api python -m app.cli.users create --email "$(EMAIL)" --user-id "$${USER_ID:-a0000000-0000-0000-0000-000000000001}"; \
	fi

set-password: ## Set an account's password (asks it, and whether to sign out every device): make set-password EMAIL=you@example.com
	docker compose exec api python -m app.cli.users set-password --email "$(EMAIL)"

set-plan: ## Set an account's plan (free, plus, unlimited); a raised plan transcribes waiting speech: make set-plan EMAIL=you@example.com PLAN=plus
	docker compose exec -T api python -m app.cli.users set-plan --email "$(EMAIL)" --plan "$(PLAN)"

revoke-example-key: ## Delete the README's example key 'my-secret-key' (publicly known)
	docker compose exec -T postgres psql -U echo -d echo -c "DELETE FROM api_keys WHERE key_hash = encode(sha256('my-secret-key'::bytea), 'hex');"
