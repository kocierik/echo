#!/bin/bash
cd /mnt/c/Users/ekoci/echo
cat docs/schema.sql | docker exec -i echo-postgres-1 psql -U echo -d echo 2>&1 | grep -v "already exists"
docker exec echo-postgres-1 psql -U echo -d echo -c "INSERT INTO api_keys (user_id, key_hash, name) VALUES ('a0000000-0000-0000-0000-000000000001', encode(sha256('my-secret-key'::bytea), 'hex'), 'default') ON CONFLICT DO NOTHING;"
echo "=== DB Ready ==="
