#!/usr/bin/env bash
# Home Assistant add-on entrypoint for Sure.
#
# Runs PostgreSQL, Redis, the Sidekiq worker and the Puma web server in one
# container. This script runs as root only to prepare /data; every long-running
# process is started with reduced privileges (setpriv).
set -euo pipefail

CONFIG_PATH="/data/options.json"
PG_DATA="/data/postgres"
PG_SOCKET_DIR="/run/postgresql"
DB_NAME="sure"
APP_UID=1000

if [ ! -f "$CONFIG_PATH" ]; then
    echo "Config file not found: $CONFIG_PATH"
    exit 1
fi

# Options are parsed with the Ruby that ships in the upstream image.
ONBOARDING_STATE=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("onboarding_state", "open")' "$CONFIG_PATH")

# Custom environment variables: the escape hatch for anything Sure reads that
# this addon has no option of its own for (SMTP settings, alternative AI
# providers, Rails tuning). They are exported after the defaults below, so an
# entry that reuses a default's name wins.
#
# Name and value are NUL-separated because a value may legitimately contain
# newlines (a PEM key). Validated now so a bad name fails before anything starts.
custom_names=()
custom_values=()
while IFS= read -r -d '' name && IFS= read -r -d '' value; do
    # Refuse rather than skip: a setting that looks applied in the UI but is not
    # would be worse than a failed start.
    if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Invalid env_vars name '${name}': use letters, digits and underscores, not starting with a digit" >&2
        exit 1
    fi
    custom_names+=("$name")
    custom_values+=("$value")
done < <(ruby -rjson -e 'JSON.parse(File.read(ARGV[0])).fetch("env_vars", []).each { |e| print e["name"], "\0", e["value"], "\0" }' "$CONFIG_PATH")

# Names only. Any of these can hold a credential.
echo "ENV_VARS: ${custom_names[*]:-(none)} (values hidden)"

# Refuse to start PostgreSQL on a data directory from another major version.
if [ -f "$PG_DATA/PG_VERSION" ] && [ "$(cat "$PG_DATA/PG_VERSION")" != "$PG_MAJOR" ]; then
    echo "ERROR: $PG_DATA was created by PostgreSQL $(cat "$PG_DATA/PG_VERSION"), this add-on ships $PG_MAJOR." >&2
    echo "Restore a dump from /data/backups into a fresh add-on (see the README) instead of upgrading in place." >&2
    exit 1
fi

# /rails/storage is a symlink to /data/storage (see Dockerfile), so Active
# Storage uploads land on the add-on's persistent volume.
mkdir -p /data/storage /data/redis /data/backups "$PG_SOCKET_DIR"
# Recursive on every start: package-assigned system uids are not guaranteed to
# stay the same across image rebuilds.
chown -R "$APP_UID:$APP_UID" /data/storage
chown -R redis:redis /data/redis
[ ! -d "$PG_DATA" ] || chown -R postgres:postgres "$PG_DATA"
chown postgres:postgres /data/backups "$PG_SOCKET_DIR"
chmod 700 /data/backups

# SECRET_KEY_BASE is generated once and reused. It also derives the encryption
# keys for credentials stored in the database, so it must stay stable.
if [ ! -s /data/secret_key_base ]; then
    (umask 077 && ruby -rsecurerandom -e 'print SecureRandom.hex(64)' > /data/secret_key_base)
fi
chown "$APP_UID:$APP_UID" /data/secret_key_base
chmod 600 /data/secret_key_base

# exec, so a backgrounded call leaves no root subshell behind. Call it inside
# ( ) when it should run in the foreground.
drop() { # drop <user|uid> <command...>
    local who=$1
    shift
    exec setpriv --reuid="$who" --regid="$who" --clear-groups "$@"
}

prepare_pid=""
worker_pid=""
web_pid=""
redis_pid=""
pg_pid=""

stop_pid() { # stop_pid <pid> <signal>
    [ -n "$1" ] || return 0
    kill -"$2" "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

# Order matters for data safety: the app first, then Redis (flushes its append
# only file), then PostgreSQL with a fast shutdown (SIGINT) and wait for it.
stop_all() {
    stop_pid "$prepare_pid" TERM
    stop_pid "$web_pid" TERM
    stop_pid "$worker_pid" TERM
    stop_pid "$redis_pid" TERM
    stop_pid "$pg_pid" INT
}

# Installed before any long-running step. This script is PID 1, and PID 1 does
# not get the default signal handlers, so without a trap Home Assistant's stop
# request would be ignored until Docker escalates to SIGKILL.
on_signal() {
    trap '' TERM INT
    stop_all
    exit 0
}
trap on_signal TERM INT

# PostgreSQL listens on 127.0.0.1 only, so it is unreachable from outside the
# container. Trust authentication is acceptable because the only processes
# sharing this container are our own. Settings are sized for a Raspberry Pi:
# Puma and Sidekiq use 3 connections each by default (RAILS_MAX_THREADS).
if [ ! -f "$PG_DATA/PG_VERSION" ]; then
    mkdir -p "$PG_DATA"
    chown postgres:postgres "$PG_DATA"
    chmod 700 "$PG_DATA"
    (drop postgres initdb -D "$PG_DATA" -U "$DB_NAME" -E UTF8 --locale=C.UTF-8 \
        --auth-local=trust --auth-host=trust >/dev/null)
fi
drop postgres postgres -D "$PG_DATA" \
    -c listen_addresses=127.0.0.1 -c unix_socket_directories="$PG_SOCKET_DIR" \
    -c max_connections=20 -c shared_buffers=64MB -c effective_cache_size=192MB \
    -c work_mem=4MB -c maintenance_work_mem=32MB &
pg_pid=$!

# Redis is Sidekiq's queue store: noeviction so jobs are never dropped under
# memory pressure, append-only file so queued jobs survive a restart.
drop redis redis-server --bind 127.0.0.1 --port 6379 --dir /data/redis \
    --appendonly yes --save "" --maxmemory-policy noeviction &
redis_pid=$!

until pg_isready -q -h "$PG_SOCKET_DIR" -U "$DB_NAME" -d postgres; do
    kill -0 "$pg_pid" 2>/dev/null || { echo "PostgreSQL failed to start" >&2; exit 1; }
    sleep 1
done

# Safety dump before migrations. A failed dump of an existing database aborts
# startup (set -e); a missing database on first run is skipped.
if [ "$(drop postgres psql -h "$PG_SOCKET_DIR" -U "$DB_NAME" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")" = 1 ]; then
    dump="/data/backups/${DB_NAME}-$(date -u +%Y%m%d-%H%M%S).dump"
    (drop postgres pg_dump -h "$PG_SOCKET_DIR" -U "$DB_NAME" -Fc -f "$dump.tmp" "$DB_NAME")
    mv "$dump.tmp" "$dump"
    echo "Pre-migration dump written: $dump"
    # Keep the 3 newest dumps.
    # shellcheck disable=SC2012
    ls -1t /data/backups/*.dump | tail -n +4 | xargs -r rm -f
fi

# Environment for Rails only, exported after the database processes started so
# they do not inherit the secret. Names match config/database.yml upstream.
SECRET_KEY_BASE=$(cat /data/secret_key_base)
export SECRET_KEY_BASE
export SELF_HOSTED=true DB_HOST=127.0.0.1 DB_PORT=5432 POSTGRES_USER="$DB_NAME" \
    POSTGRES_PASSWORD="$DB_NAME" POSTGRES_DB="$DB_NAME" REDIS_URL=redis://127.0.0.1:6379/0 \
    RAILS_FORCE_SSL=false RAILS_ASSUME_SSL=false ONBOARDING_STATE BINDING=0.0.0.0 HOME=/home/rails
for i in "${!custom_names[@]}"; do
    export "${custom_names[$i]}=${custom_values[$i]}"
done

# Create or migrate the database once, before either process starts. Sidekiq
# boots Rails too and would fail on a database that does not exist yet. It runs
# in the background so that a stop request during a long migration is honoured.
drop "$APP_UID" /rails/bin/docker-entrypoint ./bin/rails db:prepare &
prepare_pid=$!
prepare_status=0
wait "$prepare_pid" || prepare_status=$?
prepare_pid=""
if [ "$prepare_status" -ne 0 ]; then
    echo "Database preparation failed (exit ${prepare_status})"
    stop_all
    exit "$prepare_status"
fi

# Sure runs background jobs on Sidekiq, which has no in-process mode, so the
# worker needs its own process next to the web server.
drop "$APP_UID" /rails/bin/docker-entrypoint bundle exec sidekiq &
worker_pid=$!

drop "$APP_UID" /rails/bin/docker-entrypoint "$@" &
web_pid=$!

# If any process exits, stop the rest so Home Assistant restarts the add-on
# instead of leaving it half running.
exit_code=0
wait -n || exit_code=$?
trap '' TERM INT
stop_all
[ "$exit_code" -ne 0 ] || exit_code=1
exit "$exit_code"
