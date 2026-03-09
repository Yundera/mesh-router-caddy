#!/bin/sh
set -e

CERT_PATH="${CERT_PATH:-/certs/cert.pem}"
CADDYFILE_PATH="${CADDYFILE_PATH:-/etc/caddy/Caddyfile}"
CADDY_ADMIN="${CADDY_ADMIN:-localhost:2019}"

# Catch-all configuration for custom domains
# These are injected via Admin API because caddy-docker-proxy drops them
CATCHALL_ENABLED="${CATCHALL_ENABLED:-true}"
CATCHALL_TARGET_HOST="${DEFAULT_SERVICE_HOST:-casaos}"
CATCHALL_TARGET_PORT="${DEFAULT_SERVICE_PORT:-8080}"
CATCHALL_CHECK_INTERVAL="${CATCHALL_CHECK_INTERVAL:-5}"

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

# =============================================================================
# CATCH-ALL INJECTION
# =============================================================================
# caddy-docker-proxy drops the :443 catch-all block from Caddyfile during
# config regeneration. We inject equivalent config via Admin API:
#   1. TLS automation policy with on_demand + internal issuer
#   2. Catch-all HTTP route (no host matcher, appended last)
# =============================================================================

has_catchall_tls_policy() {
    # Check if an on_demand TLS policy with internal issuer exists
    curl -s "http://${CADDY_ADMIN}/config/apps/tls/automation/policies" 2>/dev/null | \
        grep -q '"on_demand":true' 2>/dev/null
}

has_catchall_route() {
    # Check if the last route has no host matcher (catch-all)
    # A route without "match" or with empty match is a catch-all
    local last_route
    last_route=$(curl -s "http://${CADDY_ADMIN}/config/apps/http/servers/srv0/routes" 2>/dev/null | \
        sed 's/.*\(\[{[^]]*}\]\)$/\1/' | \
        grep -o '\[{[^]]*}\]$' 2>/dev/null || echo "")

    # If the last route doesn't have a "match" field with "host", it's a catch-all
    if echo "$last_route" | grep -q '"match"' 2>/dev/null; then
        return 1  # Has match clause, not a catch-all
    fi
    return 0  # No match clause, is a catch-all
}

inject_catchall_tls_policy() {
    echo "[catchall] Injecting on_demand TLS policy..."
    curl -s -X POST "http://${CADDY_ADMIN}/config/apps/tls/automation/policies" \
        -H "Content-Type: application/json" \
        -d '{"on_demand": true, "issuers": [{"module": "internal"}]}' || true
    echo "[catchall] TLS policy injected"
}

inject_catchall_route() {
    echo "[catchall] Injecting catch-all HTTP route to ${CATCHALL_TARGET_HOST}:${CATCHALL_TARGET_PORT}..."
    curl -s -X POST "http://${CADDY_ADMIN}/config/apps/http/servers/srv0/routes" \
        -H "Content-Type: application/json" \
        -d "{
            \"handle\": [{
                \"handler\": \"subroute\",
                \"routes\": [{
                    \"handle\": [{
                        \"handler\": \"reverse_proxy\",
                        \"upstreams\": [{\"dial\": \"${CATCHALL_TARGET_HOST}:${CATCHALL_TARGET_PORT}\"}]
                    }]
                }]
            }],
            \"terminal\": true
        }" || true
    echo "[catchall] HTTP route injected"
}

ensure_catchall_config() {
    if [ "$CATCHALL_ENABLED" != "true" ]; then
        return
    fi

    local injected=false

    if ! has_catchall_tls_policy; then
        inject_catchall_tls_policy
        injected=true
    fi

    if ! has_catchall_route; then
        inject_catchall_route
        injected=true
    fi

    if [ "$injected" = "true" ]; then
        echo "[catchall] Config injection complete"
    fi
}

start_catchall_watcher() {
    if [ "$CATCHALL_ENABLED" != "true" ]; then
        echo "[catchall] Catch-all injection disabled (CATCHALL_ENABLED=$CATCHALL_ENABLED)"
        return
    fi

    echo "[catchall] Starting catch-all config watcher (interval: ${CATCHALL_CHECK_INTERVAL}s)..."
    echo "[catchall] Target: ${CATCHALL_TARGET_HOST}:${CATCHALL_TARGET_PORT}"

    # Initial injection
    ensure_catchall_config

    # Polling loop to re-inject after caddy-docker-proxy reloads
    while true; do
        sleep "$CATCHALL_CHECK_INTERVAL"
        ensure_catchall_config
    done
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
(wait_for_caddy && start_catchall_watcher) &

# Run original caddy docker-proxy
exec caddy docker-proxy "$@"
