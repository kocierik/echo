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

# --- 5. Create or migrate the database with Alembic (idempotent) ---
# A fresh database is created by the migrations alone: 001 creates the extensions and the
# baseline tables, 002+ the rest. A database created earlier from docs/schema.sql (stamped
# or not) goes through the same command: every migration skips what already exists.
log "Running database migrations..."

# Never stamp over a failed migration: that would silently skip schema changes.
if docker compose exec -T api python -m alembic upgrade head; then
    log "Migrations complete"
else
    error "Migration failed — fix it and run the deploy again (nothing was stamped)"
    exit 1
fi

# --- 6. Check the API keys (never seed a well-known one) ---
# The README's example key is public: a server reachable from the internet (Cloudflare
# Tunnel) must not accept it, so the deploy only warns and never creates it.
KEY_STATE=$(docker compose exec -T postgres psql -U echo -d echo -tAc "
    SELECT count(*) || ' ' || count(*) FILTER (
        WHERE key_hash = encode(sha256('my-secret-key'::bytea), 'hex'))
    FROM api_keys;" 2>/dev/null | tr -d '\r')
read -r KEY_COUNT DEFAULT_KEY_COUNT <<< "${KEY_STATE:-0 0}"
if [ "${KEY_COUNT:-0}" = "0" ]; then
    warn "No API key yet: run 'make create-key' and put the printed key in the app"
elif [ "${DEFAULT_KEY_COUNT:-0}" != "0" ]; then
    warn "The example API key 'my-secret-key' is active and publicly known:"
    warn "run 'make create-key', update the app, then 'make revoke-example-key'"
fi

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
echo "  Key:     my-secret-key"
echo ""

# Show current migration version
FINAL_VERSION=$(docker compose exec -T postgres psql -U echo -d echo -tAc "SELECT version_num FROM alembic_version LIMIT 1;" 2>/dev/null | tr -d '[:space:]')
log "Database at migration: ${FINAL_VERSION:-unknown}"
echo "════════════════════════════════════════════"
echo ""
