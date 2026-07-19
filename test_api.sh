#!/bin/bash
echo "=== Health ==="
curl -s http://localhost:8000/health
echo ""

echo "=== Query ==="
curl -s -X POST http://localhost:8000/api/query \
  -H "X-API-Key: my-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"question":"Ciao","top_k":5}'
echo ""

echo "=== Conversations ==="
curl -s http://localhost:8000/api/conversations \
  -H "X-API-Key: my-secret-key"
echo ""

echo "=== Stats ==="
curl -s http://localhost:8000/api/stats
echo ""
