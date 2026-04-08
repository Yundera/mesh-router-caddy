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
CATCHALL_ASK_ENDPOINT="${CATCHALL_ASK_ENDPOINT:-http://localhost:5555/ask}"
CADDY_STARTUP_TIMEOUT="${CADDY_STARTUP_TIMEOUT:-60}"

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
    local elapsed=0
    while ! curl -sf "http://${CADDY_ADMIN}/config/" > /dev/null 2>&1; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge "$CADDY_STARTUP_TIMEOUT" ]; then
            echo "[watcher] ERROR: Caddy admin API not ready after ${CADDY_STARTUP_TIMEOUT}s, giving up"
            return 1
        fi
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
    # Check both: per-policy on_demand flag AND global on_demand permission config
    curl -sf "http://${CADDY_ADMIN}/config/apps/tls/automation/policies" 2>/dev/null | \
        grep -q '"on_demand"' || return 1
    curl -sf "http://${CADDY_ADMIN}/config/apps/tls/automation/on_demand" 2>/dev/null | \
        grep -q '"permission"' || return 1
}

has_catchall_route() {
    # Check for our tagged catch-all route via the X-Mesh-Catchall marker
    curl -sf "http://${CADDY_ADMIN}/config/apps/http/servers/srv0/routes" 2>/dev/null | \
        grep -q 'X-Mesh-Catchall'
}

find_catchall_route_index() {
    # Iterate routes by index to find the one tagged with our marker
    local i=0
    while true; do
        local route
        route=$(curl -sf "http://${CADDY_ADMIN}/config/apps/http/servers/srv0/routes/${i}" 2>/dev/null) || return 1
        if echo "$route" | grep -q 'X-Mesh-Catchall'; then
            echo "$i"
            return 0
        fi
        i=$((i + 1))
    done
}

remove_catchall_route() {
    # Remove existing tagged catch-all route (safety net against duplicates)
    local idx
    idx=$(find_catchall_route_index) || return 0
    echo "[catchall] Removing stale catch-all route at index ${idx}..."
    curl -sf -X DELETE "http://${CADDY_ADMIN}/config/apps/http/servers/srv0/routes/${idx}" 2>/dev/null || true
}

inject_catchall_tls_policy() {
    echo "[catchall] Enabling on_demand TLS..."

    # Step 1: Set global on_demand permission config (required by Caddy v2.10+)
    # This goes at tls.automation.on_demand, separate from per-policy config.
    # Use DELETE+PUT to handle both fresh and existing state (PUT fails with 409 if key exists).
    curl -sf -X DELETE "http://${CADDY_ADMIN}/config/apps/tls/automation/on_demand" 2>/dev/null || true
    curl -sf -X PUT "http://${CADDY_ADMIN}/config/apps/tls/automation/on_demand" \
        -H "Content-Type: application/json" \
        -d "{
            \"permission\": {
                \"module\": \"http\",
                \"endpoint\": \"${CATCHALL_ASK_ENDPOINT}\"
            }
        }" || echo "[catchall] WARN: Failed to set on_demand permission"

    # Step 2: Enable on_demand flag on the existing catch-all policy (index 0)
    curl -sf -X DELETE "http://${CADDY_ADMIN}/config/apps/tls/automation/policies/0/on_demand" 2>/dev/null || true
    curl -sf -X PUT "http://${CADDY_ADMIN}/config/apps/tls/automation/policies/0/on_demand" \
        -H "Content-Type: application/json" \
        -d 'true' \
        || echo "[catchall] WARN: Failed to enable on_demand on policy"

    echo "[catchall] TLS on_demand enabled"
}

inject_catchall_route() {
    echo "[catchall] Injecting catch-all HTTP route to ${CATCHALL_TARGET_HOST}:${CATCHALL_TARGET_PORT}..."
    curl -sf -X POST "http://${CADDY_ADMIN}/config/apps/http/servers/srv0/routes" \
        -H "Content-Type: application/json" \
        -d "{
            \"handle\": [{
                \"handler\": \"subroute\",
                \"routes\": [{
                    \"handle\": [
                        {
                            \"handler\": \"headers\",
                            \"response\": {
                                \"set\": {
                                    \"X-Mesh-Catchall\": [\"true\"]
                                }
                            }
                        },
                        {
                            \"handler\": \"reverse_proxy\",
                            \"upstreams\": [{\"dial\": \"${CATCHALL_TARGET_HOST}:${CATCHALL_TARGET_PORT}\"}]
                        }
                    ]
                }]
            }],
            \"terminal\": true
        }" || echo "[catchall] WARN: Failed to inject catch-all route"
    echo "[catchall] HTTP route injected"
}

ensure_catchall_config() {
    if [ "$CATCHALL_ENABLED" != "true" ]; then
        return
    fi

    # Wait for srv0 to exist (caddy-docker-proxy creates it)
    if ! curl -sf "http://${CADDY_ADMIN}/config/apps/http/servers/srv0" > /dev/null 2>&1; then
        return
    fi

    local injected=false

    if ! has_catchall_tls_policy; then
        inject_catchall_tls_policy
        injected=true
    fi

    if ! has_catchall_route; then
        remove_catchall_route
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
