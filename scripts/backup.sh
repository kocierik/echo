#!/bin/sh
# Echo's database, dumped once a day into /backups, each dump proved by restoring it.
# Runs in the `backup` service (docker-compose.yml), which has Postgres's own tools.
#   backup.sh        every hour: a dump when the newest one is older than a day
#   backup.sh once   one dump now (make backup)
# With BACKUP_PASSPHRASE the dumps are encrypted (gpg, AES-256): the folder can then be
# copied anywhere. To read one back: docs/DEVELOPMENT.md, "Backups".
set -eu
umask 077  # the dumps hold everything the user said

KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
SCRATCH=echo_backup_check
ROWS="select (select count(*) from segments) + (select count(*) from conversations)"

once() {
    stamp=$(date -u +%Y%m%d-%H%M%S)
    tmp="/backups/.echo-$stamp.tmp"
    before=$(psql -Atc "$ROWS")
    pg_dump -Fc -f "$tmp"

    # A dump that does not restore is not a backup: restored whole, its rows counted
    dropdb --if-exists "$SCRATCH"
    createdb "$SCRATCH"
    pg_restore --no-owner --exit-on-error -d "$SCRATCH" "$tmp"
    restored=$(psql -d "$SCRATCH" -Atc "$ROWS")
    dropdb "$SCRATCH"
    if [ "$restored" -lt "$before" ]; then
        echo "[backup] FAILED: $restored rows restored, $before expected" >&2
        rm -f "$tmp"
        exit 1
    fi

    if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
        out="/backups/echo-$stamp.dump.gpg"
        export GNUPGHOME=/tmp/gnupg
        mkdir -p -m 700 "$GNUPGHOME"
        printf %s "$BACKUP_PASSPHRASE" | gpg --batch --yes --quiet --passphrase-fd 0 \
            --pinentry-mode loopback --symmetric --cipher-algo AES256 -o "$out" "$tmp"
        rm -f "$tmp"
    else
        out="/backups/echo-$stamp.dump"
        mv "$tmp" "$out"
    fi
    find /backups -name 'echo-*.dump*' -mtime "+$KEEP_DAYS" -delete
    echo "[backup] $out ($restored rows restored and counted)"
}

if [ "${1:-}" = "once" ]; then
    once
    exit 0
fi

while true; do
    # Its own process: a failing step stops that dump, never this loop
    if [ -z "$(find /backups -name 'echo-*.dump*' -mmin -1440 | head -1)" ]; then
        sh "$0" once || echo "[backup] FAILED: trying again in an hour" >&2
    fi
    sleep 3600
done
