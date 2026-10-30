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

# =============================================================================
# BOX ZONE: <domain> and *.<domain> by DNS-01 once the zone is delegated
# =============================================================================
# The backend says whether the box's zone is delegated to the mesh nameservers
# (`dns.live` in /resolve/v2: the parent zone really points at them). This file
# turns that into Caddy config, so nothing else on the box has to:
#
#   ZONE_FILE  imported by the Caddyfile; defines two snippets:
#     (zone_root_tls)  the root <domain>: `import gateway_tls`, or the DNS-01 issuer
#     (zone_tls)       the static *.<domain> site: `tls internal`, or the DNS-01 issuer
#              Not delegated, the wildcard is a local self-signed certificate: Caddy
#              then never orders one per <app>.<domain> label (a managed wildcard
#              covers them), at no network cost. Delegated, both names come from Let's
#              Encrypt through the backend's acme-dns API (credential: PROVIDER_STR).
#              caddy-docker-proxy re-reads it with the Caddyfile on every generation
#              (its polling interval), so a change needs no restart.
#   ZONE_STATE_DIR/passthrough, /automate  read by the catch-all tick below:
#     automate     the root, which cert0 (*.<zone>) covers, so automatic HTTPS would
#                  skip it (Caddy's `certificates.automate` makes it manage it anyway)
#     passthrough  SNIs served from Caddy's own certificates instead of cert0, one per
#                  name whose ACME certificate is in storage
#
# Written once before Caddy starts (backend asked with a short timeout, else the last
# state), then every ZONE_CHECK_INTERVAL. Backend unreachable = keep the last state.
ZONE_FILE="${ZONE_FILE:-/data/mesh-zone.caddy}"
ZONE_LAST_STATE="${ZONE_LAST_STATE:-/data/mesh-zone.state}"
ZONE_STATE_DIR="${ZONE_STATE_DIR:-/tmp/mesh-zone}"
ZONE_CHECK_INTERVAL="${ZONE_CHECK_INTERVAL:-120}"
TLS_PASSTHROUGH_FILE="$ZONE_STATE_DIR/passthrough"
TLS_AUTOMATE_FILE="$ZONE_STATE_DIR/automate"
CERTS_DIR="${CERTS_DIR:-/data/caddy/certificates}"

# read_names <file>: a JSON array of the file's non-blank lines, trimmed, sorted.
read_names() {
    if [ -s "$1" ]; then
        jq -Rnc '[inputs | gsub("^\\s+|\\s+$"; "") | select(length > 0)] | unique' < "$1" 2>/dev/null || echo '[]'
    else
        echo '[]'
    fi
}

# zone_live: prints 1 / 0 from the backend's view of the box's zone, nothing when it
# cannot tell (no identity, backend unreachable).
zone_live() {
    local backend body
    [ -n "${PROVIDER_STR:-}" ] && [ -n "${DOMAIN:-}" ] || return 0
    backend="${PROVIDER_STR%%,*}"
    body=$(curl -sf --max-time "${1:-10}" "${backend%/}/router/api/resolve/v2/${DOMAIN%%.*}" 2>/dev/null) || return 0
    case "$body" in
        *'"live":true'*) echo 1 ;;
        *) echo 0 ;;
    esac
}

# zone_file_content <live>
zone_file_content() {
    if [ "$1" = 1 ]; then
        local backend user sig dns
        backend="${PROVIDER_STR%%,*}"
        user="${PROVIDER_STR#*,}"; user="${user%%,*}"
        sig="${PROVIDER_STR##*,}"
        dns="	tls {
		dns acmedns {
			username \"$user\"
			password \"$sig\"
			subdomain \"${DOMAIN%%.*}\"
			server_url \"${backend%/}/router/api/acme-dns\"
		}
	}"
        printf '# GENERATED by mesh-router-caddy: zone delegated to the mesh nameservers.\n'
        printf '(zone_root_tls) {\n%s\n}\n(zone_tls) {\n%s\n}\n' "$dns" "$dns"
    else
        printf '# GENERATED by mesh-router-caddy: zone not delegated.\n'
        printf '(zone_root_tls) {\n\timport gateway_tls\n}\n(zone_tls) {\n\ttls internal\n}\n'
    fi
}

# have_zone_cert <name>: Caddy's storage holds an ACME certificate for <name>
# (local/ is Caddy's internal CA: no browser trusts it).
have_zone_cert() {
    local dir crt
    dir=$(printf '%s' "$1" | sed 's/^\*/wildcard_/')
    for crt in "$CERTS_DIR"/acme*/"$dir"/"$dir".crt; do
        [ -s "$crt" ] && return 0
    done
    return 1
}

# apply_zone <live>: write ZONE_FILE and the tick's lists when they change.
apply_zone() {
    local live="$1" tmp passthrough="" automate=""
    mkdir -p "$ZONE_STATE_DIR"
    tmp=$(mktemp "${ZONE_FILE}.XXXXXX") || return
    zone_file_content "$live" >"$tmp"
    chmod 600 "$tmp"
    if cmp -s "$tmp" "$ZONE_FILE" 2>/dev/null; then
        rm -f "$tmp"
    else
        mv "$tmp" "$ZONE_FILE"
        echo "[zone] ${DOMAIN:-?}: $([ "$live" = 1 ] && echo "delegated, DNS-01 issuer" || echo "not delegated, gateway CA + internal wildcard") (applied at the next generation)"
    fi
    echo "$live" >"$ZONE_LAST_STATE"
    if [ "$live" = 1 ]; then
        automate="$DOMAIN"
        have_zone_cert "$DOMAIN" && passthrough="$DOMAIN"
        have_zone_cert "*.$DOMAIN" && passthrough="${passthrough:+$passthrough
}*.$DOMAIN"
    fi
    printf '%s\n' "$automate" >"$TLS_AUTOMATE_FILE"
    printf '%s\n' "$passthrough" >"$TLS_PASSTHROUGH_FILE"
}

# Before Caddy starts: the zone file must exist (the Caddyfile imports it, and
# caddy-docker-proxy DROPS a block whose import is missing) and be right from the first
# generation, so a restart never drops a delegated box to the internal certificate.
# The backend is asked a few times (the network may still be coming up); without an
# answer: the last state, else what the storage shows (an ACME wildcard for the zone
# = it was delegated), else not delegated.
init_zone() {
    local live="" i
    for i in 1 2 3 4 5 6; do
        live=$(zone_live 5)
        [ -n "$live" ] && break
        [ -n "${PROVIDER_STR:-}" ] || break
        sleep 2
    done
    [ -n "$live" ] || live=$(cat "$ZONE_LAST_STATE" 2>/dev/null)
    if [ -z "$live" ] && [ -n "${DOMAIN:-}" ] && have_zone_cert "*.$DOMAIN"; then
        live=1
    fi
    [ -n "$live" ] || live=0
    apply_zone "$live"
}

# =============================================================================
# CAA: only this box's ACME accounts may obtain certificates for its zone
# =============================================================================
# While the zone is delegated, the Let's Encrypt account URIs in Caddy's storage (one per
# email the box ever used) are reported to the backend, which publishes them as the zone's
# CAA (issue + issuewild "letsencrypt.org; accounturi=..."). Reported when the list
# changes, and once a day in case the backend lost it; never an empty list (removing the
# CAA is deliberate: PUT /dns/v1/caa with []). A rebuilt box creates a new account
# at its first order, which the old CAA refuses: the next watcher tick reports the new
# account and Caddy's retry goes through.
ACME_STORAGE="${ACME_STORAGE:-/data/caddy/acme}"
CAA_LAST_REPORT="${CAA_LAST_REPORT:-/data/mesh-caa.state}"

# acme_accounts: a JSON array of the valid Let's Encrypt account URIs in storage.
acme_accounts() {
    local f
    for f in "$ACME_STORAGE"/acme-v02.api.letsencrypt.org-directory/users/*/*.json \
             "$ACME_STORAGE"/acme-staging-v02.api.letsencrypt.org-directory/users/*/*.json; do
        [ -s "$f" ] && jq -r 'select(.status == "valid") | .location // empty' "$f" 2>/dev/null
    done | jq -Rnc '[inputs | select(length > 0)] | unique'
}

report_caa() {
    local backend user sig accounts status
    [ -n "${PROVIDER_STR:-}" ] || return 0
    accounts=$(acme_accounts) || return 0
    # No account yet (fresh storage, rebuilt box): keep the published CAA. Reporting []
    # would remove it, and with it the restriction, until the first order.
    [ "$accounts" = "[]" ] && return 0
    if [ "$accounts" = "$(cat "$CAA_LAST_REPORT" 2>/dev/null)" ] \
        && [ -n "$(find "$CAA_LAST_REPORT" -mmin -1440 2>/dev/null)" ]; then
        return 0
    fi
    backend="${PROVIDER_STR%%,*}"
    user="${PROVIDER_STR#*,}"; user="${user%%,*}"
    sig="${PROVIDER_STR##*,}"
    status=$(printf '{"accounts":%s}' "$accounts" | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X PUT \
        "${backend%/}/router/api/dns/v1/caa/${user}/${sig}" -H "Content-Type: application/json" --data-binary @-)
    if [ "$status" = 200 ]; then
        echo "$accounts" >"$CAA_LAST_REPORT"
        echo "[caa] ${DOMAIN:-?}: reported ACME accounts $(printf '%s' "$accounts" | jq -r 'join(" ")')"
    else
        echo "[caa] WARN: reporting ACME accounts failed (HTTP ${status:-?}), retrying next tick"
    fi
}

# =============================================================================
# PROXY PROTOCOL: the client's address from the gateways
# =============================================================================
# A gateway that passes a dot name through raw (phase-1.1-gateway-tls.md §3) can only
# hand over the client's address as a PROXY v2 header before the TLS bytes. This file
# lets :443 accept that header from the gateways and from the tunnel's relay (the
# gateway's tunnel path arrives from the tunnel container on `pcs`), and trusts their
# X-Forwarded-For on terminated (dash-form) requests:
#
#   PROXY_FILE  imported (glob) by the Caddyfile's global options: a `servers :443` block
#               with the proxy_protocol listener wrapper (allow = gateways + tunnel,
#               fallback_policy ignore) and trusted_proxies. No gateway known = a comment
#               only, no wrapper. The header is optional from allowed sources, and from any
#               other source it is ignored (the real socket address is kept): a wrong list
#               costs the client address, never the connection.
#               trusted_proxies_strict: X-Forwarded-For is read right to left, so the
#               address the gateway appends wins over anything the client put in front.
#
# The box then reports to the backend whether its RUNNING config carries the wrapper
# (read back from the admin API, so a Caddyfile without the import reports false); the
# gateway sends the header only to boxes whose report is fresh. Re-reported every
# PROXY_REPORT_MINUTES; the backend forgets a report after 2 h.
PROXY_FILE="${PROXY_FILE:-/data/mesh-proxy.caddy}"
PROXY_REPORT_STATE="${PROXY_REPORT_STATE:-/data/mesh-proxy.state}"
PROXY_REPORT_MINUTES="${PROXY_REPORT_MINUTES:-30}"
TUNNEL_HOST="${TUNNEL_HOST:-mesh-router-tunnel}"

# gateway_ips: the backend's gateway IPv4s, one per line; fails when the backend can't tell.
gateway_ips() {
    local backend body
    [ -n "${PROVIDER_STR:-}" ] || return 1
    backend="${PROVIDER_STR%%,*}"
    body=$(curl -sf --max-time "${1:-10}" "${backend%/}/router/api/version" 2>/dev/null) || return 1
    printf '%s' "$body" | jq -r '.gatewayIps // [] | .[]' 2>/dev/null
}

# proxy_sources: gateways + the tunnel relay's address, as sorted /32s; fails when the
# backend can't tell (keep the file as it is).
proxy_sources() {
    local gw tunnel
    gw=$(gateway_ips "$@") || return 1
    [ -n "$gw" ] || return 0
    tunnel=$(getent hosts "$TUNNEL_HOST" 2>/dev/null | awk '$1 ~ /^[0-9.]+$/ {print $1}')
    printf '%s\n%s\n' "$gw" "$tunnel" | awk 'NF {print $1 "/32"}' | sort -u
}

# proxy_file_content <sources>
proxy_file_content() {
    local list
    list=$(printf '%s' "$1" | tr '\n' ' ' | sed 's/ *$//')
    if [ -z "$list" ]; then
        printf '# GENERATED by mesh-router-caddy: no gateway known, PROXY protocol off.\n'
        return
    fi
    printf '# GENERATED by mesh-router-caddy: PROXY v2 from the gateways and the tunnel relay.\n'
    printf 'servers :443 {\n\tlistener_wrappers {\n\t\tproxy_protocol {\n\t\t\ttimeout 5s\n\t\t\tallow %s\n\t\t\tfallback_policy ignore\n\t\t}\n\t\ttls\n\t}\n\ttrusted_proxies static %s\n\ttrusted_proxies_strict\n}\n' "$list" "$list"
}

# apply_proxy [timeout]: rewrite PROXY_FILE when the sources changed; applied by
# caddy-docker-proxy at its next generation.
apply_proxy() {
    local sources tmp
    sources=$(proxy_sources "$@") || return 0
    tmp=$(mktemp "${PROXY_FILE}.XXXXXX") || return 0
    proxy_file_content "$sources" >"$tmp"
    if cmp -s "$tmp" "$PROXY_FILE" 2>/dev/null; then
        rm -f "$tmp"
    else
        mv "$tmp" "$PROXY_FILE"
        echo "[proxy] PROXY protocol from: $(printf '%s' "$sources" | tr '\n' ' ')(applied at the next generation)"
    fi
}

# report_proxy: tell the backend whether the running :443 server takes the header.
report_proxy() {
    local backend user sig enabled status
    [ -n "${PROVIDER_STR:-}" ] || return 0
    curl -sf "http://${CADDY_ADMIN}/config/apps/http/servers/srv0/listener_wrappers" 2>/dev/null \
        | grep -q '"proxy_protocol"' && enabled=true || enabled=false
    if [ "$enabled" = "$(cat "$PROXY_REPORT_STATE" 2>/dev/null)" ] \
        && [ -n "$(find "$PROXY_REPORT_STATE" -mmin -"$PROXY_REPORT_MINUTES" 2>/dev/null)" ]; then
        return 0
    fi
    backend="${PROVIDER_STR%%,*}"
    user="${PROVIDER_STR#*,}"; user="${user%%,*}"
    sig="${PROVIDER_STR##*,}"
    status=$(printf '{"enabled":%s}' "$enabled" | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X PUT \
        "${backend%/}/router/api/hop/v1/proxy-protocol/${user}/${sig}" -H "Content-Type: application/json" --data-binary @-)
    if [ "$status" = 200 ]; then
        [ "$enabled" = "$(cat "$PROXY_REPORT_STATE" 2>/dev/null)" ] || echo "[proxy] reported PROXY protocol $enabled"
        echo "$enabled" >"$PROXY_REPORT_STATE"
    else
        echo "[proxy] WARN: reporting PROXY protocol failed (HTTP ${status:-?}), retrying next tick"
    fi
}

# =============================================================================
# USAGE: the access log, streamed to mesh-router-agent for the DAU report
# =============================================================================
# MESH_USAGE_REPORT=on (the default) turns Caddy's access log on and sends it to the
# agent, which keeps "someone opened app X today" and reports that to the backend
# (mesh-router-agent README, "Usage reporting"). Two pieces, both needed:
#
#   USAGE_FILE  imported (glob) by the Caddyfile's global options: a `usage` logger that
#               takes the access log and writes it to USAGE_TARGET, over UDP. Never TCP:
#               Caddy's net writer dumps every entry it cannot deliver to stderr (the
#               container log) and a stalled reader would block its logging; a datagram
#               to a stopped agent is simply lost. The filter drops what the agent does
#               not read (path, cookies, user agent...): it never leaves the box anyway.
#               The Caddyfile's default logger excludes http.log.access, so turning the
#               access log on adds nothing to the container log.
#   srv0.logs   the access log itself. Sites come from container labels, so there is no
#               Caddyfile place to turn it on for all of them: the catch-all tick sets it,
#               and puts it back after every caddy-docker-proxy regeneration.
#
# Off = no file, no srv0.logs: Caddy has no access log at all.
USAGE_REPORT="${MESH_USAGE_REPORT:-on}"
[ "$USAGE_REPORT" = off ] || USAGE_REPORT=on
USAGE_FILE="${USAGE_FILE:-/data/mesh-usage.caddy}"
USAGE_TARGET="${USAGE_TARGET:-udp/mesh-router-agent:5140}"

usage_file_content() {
    printf '# GENERATED by mesh-router-caddy: access log to mesh-router-agent (MESH_USAGE_REPORT=on).\n'
    printf 'log usage {\n\tinclude http.log.access\n\toutput net %s {\n\t\tsoft_start\n\t}\n' "$USAGE_TARGET"
    printf '\tformat filter {\n\t\twrap json\n'
    for field in 'request>uri' 'request>tls' 'request>headers>Cookie' 'request>headers>Authorization' \
        'request>headers>User-Agent' 'request>headers>Referer' 'resp_headers'; do
        printf '\t\t%s delete\n' "$field"
    done
    printf '\t}\n}\n'
}

# apply_usage: write USAGE_FILE when reporting is on, remove it when off. Read by
# caddy-docker-proxy with the Caddyfile at its first (and every) generation.
apply_usage() {
    local tmp
    if [ "$USAGE_REPORT" != on ]; then
        [ -e "$USAGE_FILE" ] && rm -f "$USAGE_FILE" && echo "[usage] Access log off (MESH_USAGE_REPORT=off)"
        return 0
    fi
    mkdir -p "$(dirname "$USAGE_FILE")"
    tmp=$(mktemp "${USAGE_FILE}.XXXXXX") || return 1
    usage_file_content >"$tmp"
    if cmp -s "$tmp" "$USAGE_FILE" 2>/dev/null; then
        rm -f "$tmp"
    else
        mv "$tmp" "$USAGE_FILE"
        echo "[usage] Access log to ${USAGE_TARGET} (MESH_USAGE_REPORT=on)"
    fi
}

# A delegated box goes back to the internal wildcard only after ZONE_DOWNGRADE_CHECKS
# readings in a row say "not delegated": one odd answer (backend restarting, a gap in
# its cache) must not swap the box's certificates. Becoming delegated applies at once.
ZONE_DOWNGRADE_CHECKS="${ZONE_DOWNGRADE_CHECKS:-3}"

start_zone_watcher() {
    set +e
    local live last misses=0
    echo "[zone] Watching the backend's view of ${DOMAIN:-?} every ${ZONE_CHECK_INTERVAL}s"
    [ "$(cat "$ZONE_LAST_STATE" 2>/dev/null)" = 1 ] && report_caa
    while true; do
        sleep "$ZONE_CHECK_INTERVAL"
        last=$(cat "$ZONE_LAST_STATE" 2>/dev/null)
        live=$(zone_live 10)
        [ -n "$live" ] || live="$last"
        if [ "$live" = 0 ] && [ "$last" = 1 ]; then
            misses=$((misses + 1))
            if [ "$misses" -lt "$ZONE_DOWNGRADE_CHECKS" ]; then
                echo "[zone] ${DOMAIN:-?}: not delegated per the backend ($misses/$ZONE_DOWNGRADE_CHECKS), keeping the DNS-01 issuer"
                live=1
            fi
        else
            misses=0
        fi
        apply_zone "${live:-0}"
        [ "$live" = 1 ] && report_caa
        apply_proxy 10
        report_proxy
    done
}

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
#      hosts serve their Let's Encrypt cert instead of cert0
#   3. HTTP route: append a catch-all route (no host matcher) with
#      X-Mesh-Catchall marker header for reliable detection
# See CATCHALL_JQ for the details of each.
# =============================================================================

# jq program: srv0 as read -> srv0 with the catch-all config applied. Each step
# is a no-op when its piece is already present, so an unchanged output means
# there is nothing to write.
#   - catch-all policy: the FIRST policy without a "match" (caddy-docker-proxy
#     leaves an empty {} there). It gets cert0 so unknown SNIs (custom domains
#     through Cloudflare "Full" mode, which checks no SAN/CN) still handshake,
#     without ACME challenges that fail behind Cloudflare's proxy.
#   - *.sslip.io passthrough, inserted right BEFORE that catch-all. The cert0
#     catch-all uses `any_tag: cert0`, which restricts the eligible pool to the
#     gateway CA cert, so an sslip SNI falling through to it is served the
#     gateway CA even when its Let's Encrypt cert is loaded (and the
#     orchestrator's TLS-validating sslip health check reports
#     UNABLE_TO_VERIFY_LEAF_SIGNATURE). A policy with no certificate_selection
#     lets Caddy pick the SNI-matching LE cert; `*.sslip.io` is single-label, so
#     it covers <app>-<ip>.sslip.io and the bare <ip>.sslip.io alike.
#   - the box's own zone (TLS_PASSTHROUGH_FILE, $zone): the same kind of policy for
#     <domain> / *.<domain> once Caddy holds its DNS-01 wildcard, so dot-form names and
#     the root get that certificate instead of cert0. Empty list = no policy.
#   - catch-all HTTP route (no host matcher), appended last and tagged with the
#     X-Mesh-Catchall response header so it can be recognised.
# No match-less policy at all is a NORMAL state mid-regeneration: the program
# then leaves the policies alone and the next tick picks it up.
CATCHALL_JQ='
  (.tls_connection_policies // []) as $p
  | ([$p | to_entries[] | select(.value.match == null) | .key] | first) as $i
  | if $i == null then . else
      .tls_connection_policies = (
        ($p | .[$i] = (if (.[$i].certificate_selection.any_tag // []) | index("cert0")
                        then .[$i] else {"certificate_selection": {"any_tag": ["cert0"]}} end))
        | if any(.[]; (.match.sni // []) | index("*.sslip.io"))
          then . else .[:$i] + [{"match": {"sni": ["*.sslip.io"]}}] + .[$i:] end
        | if ($zone | length) == 0 or any(.[]; (.match.sni // []) == $zone)
          then . else
            ([to_entries[] | select(.value.match == null) | .key] | first) as $j
            | .[:$j] + [{"match": {"sni": $zone}}] + .[$j:]
          end)
    end
  | if (.routes // []) | tostring | contains("X-Mesh-Catchall") then . else
      .routes = (.routes // []) + [{
        "handle": [{"handler": "subroute", "routes": [{"handle": [
          {"handler": "headers", "response": {"set": {"X-Mesh-Catchall": ["true"]}}},
          {"handler": "reverse_proxy", "upstreams": [{"dial": $dial}]}
        ]}]}],
        "terminal": true
      }]
    end'

# USAGE_JQ: srv0's access log on (USAGE section above). skip_hosts / skip_unmapped_hosts
# come from the Caddyfile adapter when some sites have a `log` of their own; they would
# leave every other host out of the usage log.
USAGE_JQ='.logs = ((.logs // {}) | del(.skip_hosts, .skip_unmapped_hosts))'

ensure_catchall_config() {
    if [ "$CATCHALL_ENABLED" != "true" ] && [ "$USAGE_REPORT" != on ]; then
        return
    fi

    # ONE read per tick, ONE write only when something is missing.
    #
    # This used to probe each piece with its own GETs and inject each with its
    # own PUT/POST: 6+ admin requests every tick, each logged by Caddy at INFO
    # (~50 MB/day of "received request" in the container log, with no rotation),
    # and three writes — three full config reloads — after every caddy-docker-
    # proxy regeneration.
    #
    # The write is a PATCH of srv0 guarded by If-Match on the ETag of the read.
    # caddy-docker-proxy replaces the whole config whenever it regenerates; if
    # that lands between our read and our write, Caddy answers 412 instead of
    # letting a stale srv0 (old routes, old upstream IPs) overwrite the new one,
    # and the next tick starts again from the fresh config.
    local hdrs body etag desired status
    hdrs=$(mktemp) || return
    body=$(curl -sf -D "$hdrs" "http://${CADDY_ADMIN}/config/apps/http/servers/srv0" 2>/dev/null)
    # srv0 does not exist until caddy-docker-proxy has generated it.
    if [ -z "$body" ] || [ "$body" = "null" ]; then
        rm -f "$hdrs"
        return
    fi
    etag=$(sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' "$hdrs" | tr -d '\r')
    rm -f "$hdrs"

    # The box's own zone: one SNI pattern per line, blank lines ignored.
    local zone
    zone=$(read_names "$TLS_PASSTHROUGH_FILE")

    local program='.'
    [ "$CATCHALL_ENABLED" = "true" ] && program="$CATCHALL_JQ"
    [ "$USAGE_REPORT" = on ] && program="($program) | $USAGE_JQ"
    desired=$(printf '%s' "$body" | jq -c --arg dial "${CATCHALL_TARGET_HOST}:${CATCHALL_TARGET_PORT}" --argjson zone "$zone" "$program") || {
        echo "[catchall] WARN: could not compute catch-all config"
        return
    }
    if [ "$(printf '%s' "$body" | jq -c .)" = "$desired" ]; then
        return
    fi

    if [ "$CATCHALL_ENABLED" = "true" ]; then
        echo "[catchall] Injecting catch-all config (cert0 policy, *.sslip.io passthrough, route to ${CATCHALL_TARGET_HOST}:${CATCHALL_TARGET_PORT}$([ "$USAGE_REPORT" = on ] && echo ', access log'))..."
    else
        echo "[catchall] Turning the access log on (usage reporting)..."
    fi
    status=$(printf '%s' "$desired" | curl -s -o /dev/null -w '%{http_code}' -X PATCH \
        "http://${CADDY_ADMIN}/config/apps/http/servers/srv0" \
        -H "Content-Type: application/json" -H "If-Match: ${etag}" --data-binary @-)
    case "$status" in
        200) echo "[catchall] Config injection complete" ;;
        412) echo "[catchall] Config changed underneath (regeneration); retrying next tick" ;;
        *)   echo "[catchall] WARN: PATCH srv0 failed (HTTP ${status})" ;;
    esac
}

# Keep TLS_AUTOMATE_FILE's names in apps.tls.certificates.automate. Like the catch-all,
# caddy-docker-proxy drops it on every regeneration: one read per tick, one guarded
# write when a name is missing. A removed name goes with the next generation, which
# the zone file change that removed it triggers.
ensure_tls_automate() {
    local want hdrs body etag desired status
    want=$(read_names "$TLS_AUTOMATE_FILE")
    [ "$want" = "[]" ] && return
    hdrs=$(mktemp) || return
    body=$(curl -sf -D "$hdrs" "http://${CADDY_ADMIN}/config/apps/tls/certificates" 2>/dev/null)
    etag=$(sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' "$hdrs" | tr -d '\r')
    rm -f "$hdrs"
    # no tls app yet (mid-regeneration): next tick
    if [ -z "$body" ] || [ "$body" = "null" ]; then
        return
    fi
    desired=$(printf '%s' "$body" | jq -c --argjson want "$want" '.automate = ((.automate // []) + $want | unique)') || return
    if [ "$(printf '%s' "$body" | jq -c .)" = "$desired" ]; then
        return
    fi
    echo "[catchall] Automating own certificates for $(printf '%s' "$want" | jq -r 'join(" ")')..."
    status=$(printf '%s' "$desired" | curl -s -o /dev/null -w '%{http_code}' -X PATCH \
        "http://${CADDY_ADMIN}/config/apps/tls/certificates" \
        -H "Content-Type: application/json" -H "If-Match: ${etag}" --data-binary @-)
    case "$status" in
        200) ;;
        412) echo "[catchall] Config changed underneath (regeneration); retrying next tick" ;;
        *)   echo "[catchall] WARN: PATCH tls certificates failed (HTTP ${status})" ;;
    esac
}

start_catchall_watcher() {
    if [ "$CATCHALL_ENABLED" != "true" ] && [ "$USAGE_REPORT" != on ]; then
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
    # (no match-less policy mid-regeneration) killed this loop outright. caddy-docker-proxy then dropped the catch-all on
    # the next regeneration with nothing left to re-inject it, and every custom
    # domain on the box failed its TLS handshake (alert 80 -> Cloudflare 525)
    # until someone restarted the container by hand. *.nsl.sh / *.nip.io /
    # *.sslip.io kept working throughout, so the outage was invisible on any box
    # without a custom domain. `set +e` makes the whole loop non-fatal by
    # construction.
    set +e

    # Initial injection
    ensure_catchall_config || true
    [ "$CATCHALL_ENABLED" = "true" ] && ensure_tls_automate || true

    # Polling loop to re-inject after caddy-docker-proxy reloads
    while true; do
        sleep "$CATCHALL_CHECK_INTERVAL"
        ensure_catchall_config || true
        [ "$CATCHALL_ENABLED" = "true" ] && ensure_tls_automate || true
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

# The zone file before Caddy reads the Caddyfile that imports it.
init_zone || echo "[zone] WARN: could not prepare $ZONE_FILE"
# The PROXY file too, so the first generation already takes the header (the tunnel relay
# may not resolve yet: the next tick adds it). Backend unreachable = the last file.
apply_proxy 5 || echo "[proxy] WARN: could not prepare $PROXY_FILE"
# The usage logger, read with the Caddyfile at the first generation.
apply_usage || echo "[usage] WARN: could not prepare $USAGE_FILE"

# Wait for Caddy, then start watchers in background
(wait_for_caddy && start_cert_watcher) &
(wait_for_caddy && start_catchall_watcher) &
start_zone_watcher &

# Run original caddy docker-proxy
exec caddy docker-proxy "$@"
