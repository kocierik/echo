#!/bin/bash
# =============================================================================
# Echo Deploy Script — Idempotent, safe, run as many times as you want
# Usage: ./scripts/deploy.sh
# =============================================================================
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

echo ""
echo "════════════════════════════════════════════"
echo "  Echo — Deploy & Migrate"
echo "════════════════════════════════════════════"
echo ""

# --- 1. Pull latest code (skip if not a git repo or uncommitted changes) ---
if git rev-parse --git-dir > /dev/null 2>&1; then
    log "Git repo detected"
    if git diff --quiet 2>/dev/null; then
        git pull --rebase 2>/dev/null && log "Pulled latest code" || warn "Git pull skipped (no remote or conflict)"
    else
        warn "Uncommitted changes — skipping git pull"
    fi
fi

# --- 2. Build containers (only if Dockerfile changed or first run) ---
log "Building containers..."
docker compose build --quiet 2>/dev/null || docker compose build

# --- 3. Start services ---
log "Starting services..."
docker compose up -d

# --- 4. Wait for PostgreSQL ---
echo -n "  Waiting for PostgreSQL..."
for i in $(seq 1 30); do
    if docker compose exec -T postgres pg_isready -U echo > /dev/null 2>&1; then
        echo " ready"
        break
    fi
    echo -n "."
    sleep 1
    if [ "$i" -eq 30 ]; then
        echo ""
        error "PostgreSQL did not start in 30s"
        exit 1
    fi
done

# --- 5. Ensure base schema exists (for fresh databases) ---
log "Ensuring base schema..."
docker compose exec -T postgres psql -U echo -d echo -c "
    -- Enable extensions if not present
    CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
    CREATE EXTENSION IF NOT EXISTS \"vector\";
" > /dev/null 2>&1 || warn "Extensions may already exist"

# Check if segments table exists (indicates schema.sql was applied)
TABLE_EXISTS=$(docker compose exec -T postgres psql -U echo -d echo -tAc "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'segments');")

if [ "$TABLE_EXISTS" = "f" ]; then
    warn "Base schema not found — applying docs/schema.sql..."
    if [ -f "docs/schema.sql" ]; then
        docker compose exec -T postgres psql -U echo -d echo < docs/schema.sql
        log "Base schema applied"
    else
        error "docs/schema.sql not found! Cannot initialize database."
        exit 1
    fi
fi

# --- 6. Run Alembic migrations (idempotent) ---
log "Running database migrations..."

# Ensure alembic_version table exists
docker compose exec -T postgres psql -U echo -d echo -c "
    CREATE TABLE IF NOT EXISTS alembic_version (
        version_num VARCHAR(32) NOT NULL,
        CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num)
    );
" > /dev/null 2>&1

# Ensure compatibility with the current schema, even when the DB was created from docs/schema.sql
# and then later expanded by Alembic migrations.
docker compose exec -T postgres psql -U echo -d echo -c "
    ALTER TABLE segments ADD COLUMN IF NOT EXISTS audio_hash VARCHAR(64);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_segments_audio_hash ON segments (audio_hash);

    ALTER TABLE segments ADD COLUMN IF NOT EXISTS audio_energy INTEGER;
    ALTER TABLE segments ADD COLUMN IF NOT EXISTS speaker VARCHAR(10) DEFAULT 'unknown';

    ALTER TABLE transcriptions ADD COLUMN IF NOT EXISTS speaker_label VARCHAR(10);

    CREATE TABLE IF NOT EXISTS query_feedback (
        id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
        user_id UUID NOT NULL,
        session_id UUID NOT NULL,
        message_index INTEGER NOT NULL,
        rating VARCHAR(10) NOT NULL,
        comment TEXT,
        source_chunk_ids JSONB NOT NULL DEFAULT '[]',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_feedback_user ON query_feedback (user_id, created_at);
    CREATE TABLE IF NOT EXISTS integrations (
        id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
        user_id UUID NOT NULL,
        provider VARCHAR(50) NOT NULL,
        enabled BOOLEAN NOT NULL DEFAULT false,
        config JSONB NOT NULL DEFAULT '{}',
        entity_types TEXT[] NOT NULL DEFAULT '{}',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_integrations_user ON integrations (user_id);
" > /dev/null 2>&1 || warn "Schema compatibility checks encountered non-fatal issues"

# Check current Alembic version
CURRENT_VERSION=$(docker compose exec -T postgres psql -U echo -d echo -tAc "SELECT version_num FROM alembic_version LIMIT 1;" 2>/dev/null | tr -d '[:space:]')

# docs/schema.sql is the 001 baseline plus later tables, not the full head schema
# (it lacks e.g. transcription_edits from 006). Stamp the baseline and let the
# idempotent migrations 002+ add only what is missing.
if [ -z "$CURRENT_VERSION" ]; then
    warn "No migration version found — stamping the schema.sql baseline (001)..."
    docker compose exec -T api python -m alembic stamp 001
    log "Stamped at 001"
fi

# Never stamp over a failed migration: that would silently skip schema changes.
if docker compose exec -T api python -m alembic upgrade head; then
    log "Migrations complete"
else
    error "Migration failed — fix it and run the deploy again (nothing was stamped)"
    exit 1
fi

# --- 7. Ensure the default API key exists for local development ---
log "Ensuring default API key exists..."
docker compose exec -T postgres psql -U echo -d echo -c "
    INSERT INTO api_keys (user_id, key_hash, name)
    VALUES (
        'a0000000-0000-0000-0000-000000000001',
        encode(sha256('my-secret-key'::bytea), 'hex'),
        'default'
    )
    ON CONFLICT DO NOTHING;
" > /dev/null 2>&1 || warn "Could not seed default API key - create it manually later"

# --- 8. Restart services to pick up any code changes ---
log "Restarting API and Worker..."
docker compose restart api worker

# --- 9. Wait for API to be healthy ---
echo -n "  Waiting for API..."
for i in $(seq 1 20); do
    if curl -s http://localhost:8000/health > /dev/null 2>&1; then
        echo " healthy"
        break
    fi
    echo -n "."
    sleep 1
    if [ "$i" -eq 20 ]; then
        echo ""
        warn "API not healthy yet — check logs with: docker compose logs api"
    fi
done

# --- 10. Summary ---
echo ""
echo "════════════════════════════════════════════"
log "Deploy complete!"
echo ""
echo "  API:     http://localhost:8000"
echo "  Health:  http://localhost:8000/health"
echo "  Logs:    docker compose logs -f api worker"
echo "  Key:     my-secret-key"
echo ""

# Show current migration version
FINAL_VERSION=$(docker compose exec -T postgres psql -U echo -d echo -tAc "SELECT version_num FROM alembic_version LIMIT 1;" 2>/dev/null | tr -d '[:space:]')
log "Database at migration: ${FINAL_VERSION:-unknown}"
echo "════════════════════════════════════════════"
echo ""
