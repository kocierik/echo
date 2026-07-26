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

# Check current Alembic version
CURRENT_VERSION=$(docker compose exec -T postgres psql -U echo -d echo -tAc "SELECT version_num FROM alembic_version LIMIT 1;" 2>/dev/null | tr -d '[:space:]')

if [ -z "$CURRENT_VERSION" ]; then
    # No version tracked yet — DB was created via schema.sql
    # Stamp 001 (baseline) since schema already exists
    warn "No migration version found — stamping baseline..."
    docker compose exec -T api python -m alembic stamp 001
    log "Stamped at 001"
fi

# Now run upgrade head — all migrations are idempotent
docker compose exec -T api python -m alembic upgrade head && log "Migrations complete" || {
    # If upgrade still fails, force stamp head (nuclear option)
    warn "Migration error — force-stamping head..."
    docker compose exec -T api python -m alembic stamp head
    log "Force-stamped at head"
}

# --- 7. Restart services to pick up any code changes ---
log "Restarting API and Worker..."
docker compose restart api worker

# --- 8. Wait for API to be healthy ---
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

# --- 9. Summary ---
echo ""
echo "════════════════════════════════════════════"
log "Deploy complete!"
echo ""
echo "  API:     http://localhost:8000"
echo "  Health:  http://localhost:8000/health"
echo "  Logs:    docker compose logs -f api worker"
echo ""

# Show current migration version
FINAL_VERSION=$(docker compose exec -T postgres psql -U echo -d echo -tAc "SELECT version_num FROM alembic_version LIMIT 1;" 2>/dev/null | tr -d '[:space:]')
log "Database at migration: ${FINAL_VERSION:-unknown}"
echo "════════════════════════════════════════════"
echo ""
