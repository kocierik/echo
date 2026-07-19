#!/bin/bash
echo "=== Fixing DNS in containers ==="
docker exec echo-api-1 bash -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'
docker exec echo-worker-1 bash -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'

echo "=== Testing DNS ==="
docker exec echo-api-1 python -c "import socket; print('DNS OK:', socket.getaddrinfo('api.openai.com', 443)[0][4])"

echo "=== Testing API ==="
bash /mnt/c/Users/ekoci/echo/test_api.sh
