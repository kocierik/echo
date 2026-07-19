#!/bin/bash
set -e

cd /mnt/c/Users/ekoci/echo

echo "=== Installing Python dependencies ==="
pip install fastapi uvicorn sqlalchemy asyncpg pgvector redis pydantic-settings openai python-multipart httpx 2>&1 | tail -5

echo "=== Setting environment variables ==="
export DATABASE_URL="postgresql+asyncpg://echo:echo@localhost:5432/echo"
export REDIS_URL="redis://localhost:6379/0"
export AUDIO_STORAGE_PATH="/tmp/echo_audio"
export OPENAI_API_KEY=$(grep OPENAI_API_KEY /mnt/c/Users/ekoci/echo/.env | cut -d= -f2)

mkdir -p $AUDIO_STORAGE_PATH

echo "=== Applying schema ==="
docker exec echo-postgres-1 psql -U echo -d echo -c "SELECT 1 FROM api_keys LIMIT 1" > /dev/null 2>&1 || {
    cat docs/schema.sql | docker exec -i echo-postgres-1 psql -U echo -d echo
    docker exec echo-postgres-1 psql -U echo -d echo -c "INSERT INTO api_keys (user_id, key_hash, name) VALUES ('a0000000-0000-0000-0000-000000000001', encode(sha256('my-secret-key'::bytea), 'hex'), 'default');"
}

echo "=== Starting API server ==="
cd backend
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
