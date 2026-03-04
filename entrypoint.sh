#!/bin/sh
set -e

CERT_PATH="${CERT_PATH:-/certs/cert.pem}"
CADDYFILE_PATH="${CADDYFILE_PATH:-/etc/caddy/Caddyfile}"
CADDY_ADMIN="${CADDY_ADMIN:-localhost:2019}"

reload_certs() {
    echo "[watcher] Certificate change detected, reloading..."

    # Delete existing cert entry
    curl -s -X DELETE "http://${CADDY_ADMIN}/config/apps/tls/certificates/load_files/0" || true

    # Re-add cert (loads fresh from disk)
    curl -s -X POST "http://${CADDY_ADMIN}/config/apps/tls/certificates/load_files" \
        -H "Content-Type: application/json" \
        -d '{"certificate":"/certs/cert.pem","key":"/certs/key.pem","tags":["cert0"]}' || true

    echo "[watcher] Certificate reloaded"
}

reload_caddyfile() {
    echo "[watcher] Caddyfile change detected, reloading..."

    # Use caddy reload command to re-parse Caddyfile
    caddy reload --config "$CADDYFILE_PATH" --adapter caddyfile --address "$CADDY_ADMIN" 2>&1 || true

    echo "[watcher] Caddyfile reloaded"
}

wait_for_caddy() {
    echo "[watcher] Waiting for Caddy admin API..."
    while ! curl -s "http://${CADDY_ADMIN}/config/" > /dev/null 2>&1; do
        sleep 1
    done
    echo "[watcher] Caddy admin API ready"
}

start_cert_watcher() {
    if [ -f "$CERT_PATH" ]; then
        echo "[watcher] Watching $CERT_PATH for changes..."
        while true; do
            inotifywait -e modify -e create -e moved_to "$(dirname "$CERT_PATH")" 2>/dev/null || true
            sleep 1
            if [ -f "$CERT_PATH" ]; then
                reload_certs
            fi
        done
    else
        echo "[watcher] Certificate not found at $CERT_PATH, cert watcher disabled"
    fi
}

start_caddyfile_watcher() {
    if [ -f "$CADDYFILE_PATH" ]; then
        echo "[watcher] Watching $CADDYFILE_PATH for changes..."
        while true; do
            inotifywait -e modify -e create -e moved_to "$CADDYFILE_PATH" 2>/dev/null || true
            sleep 1
            if [ -f "$CADDYFILE_PATH" ]; then
                reload_caddyfile
            fi
        done
    else
        echo "[watcher] Caddyfile not found at $CADDYFILE_PATH, caddyfile watcher disabled"
    fi
}

# Wait for Caddy, then start watchers in background
(wait_for_caddy && start_cert_watcher) &
(wait_for_caddy && start_caddyfile_watcher) &

# Run original caddy docker-proxy
exec caddy docker-proxy "$@"
