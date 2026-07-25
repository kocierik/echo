#!/bin/sh
# Fix permissions on mounted volumes (needed when volume was created by root)
# Runs as root at container start, then drops to 'echo' user for the app

chown -R echo:echo /data/audio 2>/dev/null || true
exec gosu echo "$@"
