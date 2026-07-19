#!/bin/bash
cd /mnt/c/Users/ekoci/echo

echo "=== Applying schema ==="
cat docs/schema.sql | docker exec -i echo-postgres-1 psql -U echo -d echo

echo "=== Creating API key ==="
docker exec echo-postgres-1 psql -U echo -d echo -c "INSERT INTO api_keys (user_id, key_hash, name) VALUES ('a0000000-0000-0000-0000-000000000001', encode(sha256('my-secret-key'::bytea), 'hex'), 'default');"

echo "=== Waiting for API ==="
sleep 2

echo "=== Running tests ==="
bash /mnt/c/Users/ekoci/echo/test_api.sh
