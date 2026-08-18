#!/bin/sh
set -e

CERT_PATH="${CERT_PATH:-/certs/cert.pem}"
CADDY_ADMIN="${CADDY_ADMIN:-localhost:2019}"

# NO CADDYFILE WATCHER HERE — deliberately. caddy-docker-proxy already re-reads
# the base Caddyfile (--caddyfile-path) on every generation, and it generates
# every --polling-interval (default 30s) as well as on docker events. A base
# Caddyfile edit therefore reaches the running config on its own, merged with
# the container-label routes.
#
# This file used to carry a start_caddyfile_watcher that inotify-watched the
# Caddyfile and ran `caddy reload --config "$CADDYFILE_PATH"`. That reload
# replaces the WHOLE running config with the base file alone, so every
# label-derived route disappeared until caddy-docker-proxy's next generation
# put them back — up to 30s during which every app hostname fell through to the
# catch-all. Measured on a test PCS: the route array collapsed to 3 entries (the
# base file's own site blocks) and came back at 31.
#
# It was invisible because the deployment bind-mounts the Caddyfile as a SINGLE
# FILE: that mount is pinned to the inode it started with, and the writer
# (rsync) renames a new file into place, so the watch never fired and the
# container never saw an update either. Fixing the mount without deleting this
# watcher would have turned a dormant bug into a live one.
#
# If 30s is ever too slow, lower --polling-interval. Do not reintroduce a
# `caddy reload` of the base file: it cannot see the labels.

# Catch-all configuration for custom domains
# These are injected via Admin API because caddy-docker-proxy drops them
CATCHALL_ENABLED="${CATCHALL_ENABLED:-true}"
CATCHALL_TARGET_HOST="${DEFAULT_SERVICE_HOST:-casaos}"
CATCHALL_TARGET_PORT="${DEFAULT_SERVICE_PORT:-8080}"
CATCHALL_CHECK_INTERVAL="${CATCHALL_CHECK_INTERVAL:-5}"
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
# caddy-docker-proxy drops catch-all config during Caddyfile regeneration.
# We re-inject via Admin API every CATCHALL_CHECK_INTERVAL seconds:
#   1. TLS connection policy: set cert0 on the catch-all (no SNI match) policy
#      so unknown domains get the custom CA cert (Cloudflare Full mode)
#   2. *.sslip.io passthrough TLS policy ordered before the catch-all, so sslip
#      hosts serve their Let's Encrypt cert instead of cert0 (see
#      inject_sslip_passthrough_policy for the full rationale)
#   3. HTTP route: append a catch-all route (no host matcher) with
#      X-Mesh-Catchall marker header for reliable detection
# =============================================================================

has_catchall_tls_conn_policy() {
    # Check if the catch-all TLS connection policy (no SNI match) has cert0 selected.
    # Without this, unknown SNI values get an empty {} policy and TLS handshake fails.
    # Must check the specific catch-all policy, not just any policy in the array.
    local idx
    idx=$(find_catchall_tls_conn_policy_index) || return 1
    local policy
    policy=$(curl -sf "http://${CADDY_ADMIN}/config/apps/http/servers/srv0/tls_connection_policies/${idx}" 2>/dev/null) || return 1
    echo "$policy" | grep -q '"any_tag"' || return 1
}

has_sslip_passthrough_policy() {
    # True if a connection policy explicitly matches *.sslip.io. That policy uses
    # default (unrestricted) certificate selection so sslip hosts serve their
    # Let's Encrypt cert, instead of being captured by the cert0 catch-all (which
    # restricts selection to the gateway CA cert).
    curl -sf "http://${CADDY_ADMIN}/config/apps/http/servers/srv0/tls_connection_policies" 2>/dev/null \
        | grep -qF '*.sslip.io'
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

find_catchall_tls_conn_policy_index() {
    # Find the TLS connection policy without an SNI match (the catch-all).
    # Iterate policies; the one without "match" or with empty match is the catch-all.
    local i=0
    while true; do
        local policy
        policy=$(curl -sf "http://${CADDY_ADMIN}/config/apps/http/servers/srv0/tls_connection_policies/${i}" 2>/dev/null) || return 1
        # A catch-all policy has no "match" field (or match is absent)
        if ! echo "$policy" | grep -q '"match"'; then
            echo "$i"
            return 0
        fi
        i=$((i + 1))
    done
}

inject_catchall_tls_conn_policy() {
    # Patch the catch-all TLS connection policy to use cert0 (custom CA cert).
    # Custom domains come through Cloudflare which uses "Full" mode — it doesn't
    # verify SAN/CN, just needs a valid TLS handshake. Using cert0 avoids ACME
    # challenges which fail behind Cloudflare's proxy.
    echo "[catchall] Patching catch-all TLS connection policy with cert0..."

    local idx
    # `|| idx=""` is load-bearing: find_catchall_tls_conn_policy_index returns 1
    # whenever no match-less policy exists yet, which is a NORMAL state while
    # caddy-docker-proxy is mid-regeneration. Under `set -e` a bare failing
    # assignment aborts the shell immediately, so the guard below never runs and
    # the watcher dies for good. See start_catchall_watcher for the full history.
    idx=$(find_catchall_tls_conn_policy_index) || idx=""
    if [ -z "$idx" ]; then
        echo "[catchall] WARN: No catch-all TLS connection policy found"
        return
    fi

    # Replace the empty {} policy with one that selects cert0
    curl -sf -X PUT "http://${CADDY_ADMIN}/config/apps/http/servers/srv0/tls_connection_policies/${idx}" \
        -H "Content-Type: application/json" \
        -d '{"certificate_selection": {"any_tag": ["cert0"]}}' \
        || echo "[catchall] WARN: Failed to patch TLS connection policy"

    echo "[catchall] TLS connection policy patched (index ${idx} → cert0)"
}

inject_sslip_passthrough_policy() {
    # Insert a connection policy that matches *.sslip.io with DEFAULT certificate
    # selection, ordered immediately before the cert0 catch-all.
    #
    # Why this is needed: the cert0 catch-all uses `any_tag: cert0`, which
    # restricts the eligible cert pool to the gateway CA cert. Any *.sslip.io SNI
    # that falls through to it is served the gateway CA even when its publicly
    # trusted Let's Encrypt cert is loaded — so the sslip cert never appears to
    # external clients (and the orchestrator's TLS-validating sslip health check
    # reports UNABLE_TO_VERIFY_LEAF_SIGNATURE). A policy with no
    # certificate_selection lets Caddy pick the SNI-matching managed (LE) cert.
    #
    # `*.sslip.io` is a single-label wildcard, so one static policy covers both
    # <app>-<ip>.sslip.io and the bare <ip>.sslip.io without enumerating hosts.
    # Inserting at the catch-all's index (PUT inserts, shifting it down) keeps the
    # sslip policy ahead of the catch-all so it wins for sslip SNIs.
    if has_sslip_passthrough_policy; then
        return
    fi
    local idx
    # Same errexit trap as in inject_catchall_tls_conn_policy: without `|| idx=""`
    # a legitimate "not found" return kills the watcher instead of deferring.
    idx=$(find_catchall_tls_conn_policy_index) || idx=""
    if [ -z "$idx" ]; then
        echo "[catchall] WARN: catch-all TLS policy not present yet; deferring sslip passthrough"
        return
    fi
    echo "[catchall] Inserting *.sslip.io passthrough TLS policy at index ${idx} (before catch-all)..."
    curl -sf -X PUT "http://${CADDY_ADMIN}/config/apps/http/servers/srv0/tls_connection_policies/${idx}" \
        -H "Content-Type: application/json" \
        -d '{"match": {"sni": ["*.sslip.io"]}}' \
        || echo "[catchall] WARN: Failed to insert sslip passthrough policy"
    echo "[catchall] sslip passthrough policy inserted"
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

    if ! has_catchall_tls_conn_policy; then
        inject_catchall_tls_conn_policy
        injected=true
    fi

    # Must run after the cert0 catch-all exists: this inserts the *.sslip.io
    # passthrough policy immediately before it so sslip hosts serve their LE cert.
    if ! has_sslip_passthrough_policy; then
        inject_sslip_passthrough_policy
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

    # This watcher is the ONLY thing that restores custom-domain routing after a
    # caddy-docker-proxy regeneration, so it must not be able to exit. It runs in
    # its own subshell (see the `&` dispatch at the bottom of this file), so
    # clearing errexit is local to the watcher and leaves the startup path's
    # fail-fast behaviour untouched.
    #
    # History: with errexit active, one unguarded `idx=$(...)` returning non-zero
    # killed this loop outright. caddy-docker-proxy then dropped the catch-all on
    # the next regeneration with nothing left to re-inject it, and every custom
    # domain on the box failed its TLS handshake (alert 80 -> Cloudflare 525)
    # until someone restarted the container by hand. *.nsl.sh / *.nip.io /
    # *.sslip.io kept working throughout, so the outage was invisible on any box
    # without a custom domain. Guarding the two assignments fixes that specific
    # path; `set +e` makes the whole loop non-fatal by construction.
    set +e

    # Initial injection
    ensure_catchall_config || true

    # Polling loop to re-inject after caddy-docker-proxy reloads
    while true; do
        sleep "$CATCHALL_CHECK_INTERVAL"
        ensure_catchall_config || true
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

# Wait for Caddy, then start watchers in background
(wait_for_caddy && start_cert_watcher) &
(wait_for_caddy && start_catchall_watcher) &

# Run original caddy docker-proxy
exec caddy docker-proxy "$@"
