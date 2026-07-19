#!/bin/bash
# Kill old process
pkill -f "uvicorn app.main" 2>/dev/null
sleep 1

cd /mnt/c/Users/ekoci/echo/backend

export DATABASE_URL="postgresql+asyncpg://echo:echo@localhost:5432/echo"
export REDIS_URL="redis://localhost:6379/0"
export AUDIO_STORAGE_PATH="/tmp/echo_audio"
export OPENAI_API_KEY=$(grep OPENAI_API_KEY /mnt/c/Users/ekoci/echo/.env | cut -d= -f2 | tr -d '\r')

mkdir -p /tmp/echo_audio

echo "OPENAI_API_KEY set: ${OPENAI_API_KEY:0:10}..."
echo "Starting uvicorn..."

nohup python3 -m uvicorn app.main:app --host 127.0.0.1 --port 8000 > /tmp/echo_api.log 2>&1 &
sleep 3

echo "=== Log ==="
cat /tmp/echo_api.log

echo "=== Test ==="
curl -s --connect-timeout 5 http://127.0.0.1:8000/health || echo "FAILED to connect"
