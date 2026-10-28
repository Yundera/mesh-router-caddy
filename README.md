# mesh-router-caddy

A custom Caddy Docker image extending [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) with automatic certificate reload, Caddyfile reload, and catch-all domain support.

## Features

- **Auto-reload certificates**: Watches certificate files and reloads Caddy when they change
- **Auto-reload Caddyfile**: handled by caddy-docker-proxy itself — it re-reads the base Caddyfile on every generation (`--polling-interval`, default 30s, plus docker events) and merges it with the label routes. This image adds no Caddyfile watcher: a `caddy reload` of the base file would drop every label-derived route until the next generation. **Bind-mount the Caddyfile's DIRECTORY, not the file** — a single-file mount is pinned to its inode, so a writer that renames a new file into place is never seen.
- **Catch-all custom domains**: Auto-injects on_demand TLS policy for unknown domains
- **Zero-downtime**: Uses Caddy admin API for graceful reloads
- **Docker label routing**: Inherits all caddy-docker-proxy features
- **DNS-01 via acme-dns**: built with [caddy-dns/acmedns](https://github.com/caddy-dns/acmedns), so a box can get `*.<user>.<zone>` from mesh-router-backend's acme-dns API (`server_url <backend>/router/api/acme-dns`, username = user id, password = the box's route signature).
- **Box zone (1.4.0)**: the entrypoint asks the backend whether the box's zone is delegated to the mesh nameservers (`dns.live` in `/resolve/v2`) and writes `/data/mesh-zone.caddy`, which the Caddyfile imports: two snippets, `(zone_root_tls)` for `<domain>` and `(zone_tls)` for the `*.<domain>` site. Not delegated: `import gateway_tls` and `tls internal` (a local wildcard, so Caddy orders nothing for `<app>.<domain>` labels). Delegated: both Let's Encrypt by DNS-01 through acme-dns, plus the root in `certificates.automate` (cert0 covers it, so automatic HTTPS would skip it) and a TLS passthrough for the names whose ACME certificate is in storage. Written before Caddy starts (backend, else last state, else an ACME wildcard in storage), then every `ZONE_CHECK_INTERVAL`; caddy-docker-proxy picks a change up at its next generation. Needs `PROVIDER_STR` and `DOMAIN`; without them the zone stays "not delegated".
- **PROXY protocol from the gateways**: the entrypoint writes `/data/mesh-proxy.caddy`, a `servers :443` block that the Caddyfile's global options import by glob (`import /data/mesh-proxy*.caddy`): the `proxy_protocol` listener wrapper with `allow` = the backend's `gatewayIps` (`/router/api/version`) + the tunnel container's address, `fallback_policy ignore`, and the same list as `trusted_proxies`. A gateway passing a connection through raw then hands over the client's address; a header from anyone else is ignored. The box reports to the backend (`PUT /router/api/hop/v1/proxy-protocol/<user>/<sig>`) whether its running config carries the wrapper, and gateways send the header only to boxes that said yes. No gateway list from the backend = no wrapper.

## Usage

```yaml
services:
  caddy:
    image: mesh-router-caddy:local
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      # A DIRECTORY, not the file itself — see "Auto-reload Caddyfile" above.
      - ./caddy:/etc/caddy:ro
      - certs:/certs:ro
    environment:
      - CADDY_DOCKER_CADDYFILE_PATH=/etc/caddy/Caddyfile
      - CADDY_INGRESS_NETWORKS=mesh
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CERT_PATH` | `/certs/cert.pem` | Path to certificate file to watch |
| `CADDY_ADMIN` | `localhost:2019` | Caddy admin API address |
| `CATCHALL_ENABLED` | `true` | Enable catch-all domain injection |
| `DEFAULT_SERVICE_HOST` | `casaos` | Target host for catch-all route |
| `DEFAULT_SERVICE_PORT` | `8080` | Target port for catch-all route |
| `CATCHALL_CHECK_INTERVAL` | `5` | Seconds between catch-all config checks |
| `PROVIDER_STR` | — | Box identity `<backend>,<userid>,<signature>`: asks the backend about the zone, and is the acme-dns credential |
| `DOMAIN` | — | The box domain (`<user>.<zone>`) |
| `ZONE_CHECK_INTERVAL` | `120` | Seconds between checks of the zone's delegation |
| `ZONE_DOWNGRADE_CHECKS` | `3` | Consecutive "not delegated" answers before a delegated box goes back to the internal wildcard (becoming delegated applies at once) |
| `TUNNEL_HOST` | `mesh-router-tunnel` | Name of the tunnel container, whose address joins the PROXY allow list |
| `PROXY_REPORT_MINUTES` | `30` | Minutes between re-reports of the PROXY capability to the backend (it forgets one after 2 h) |

Plus all [caddy-docker-proxy environment variables](https://github.com/lucaslorentz/caddy-docker-proxy#environment-variables).

## How It Works

1. Starts caddy-docker-proxy normally
2. Waits for Caddy admin API to be ready
3. Spawns two background watchers:
   - **Cert watcher**: On certificate change, removes and re-adds the TLS certificate via admin API
   - **Catch-all watcher**: Polls config and re-injects catch-all if missing

## Catch-All Custom Domains

caddy-docker-proxy drops catch-all `:443` blocks from the Caddyfile during config regeneration. This image works around this limitation by injecting the catch-all config via Caddy's admin API.

### What Gets Injected

1. **TLS automation policy**: `{"on_demand": true, "issuers": [{"module": "internal"}]}`
   - Generates self-signed certificates on-the-fly for unknown SNI values
   - Works with Cloudflare "Full" mode (non-strict)

2. **Catch-all HTTP route**: Appended last with no host matcher
   - Routes unmatched requests to `DEFAULT_SERVICE_HOST:DEFAULT_SERVICE_PORT`

### Why This Is Needed

When a custom domain is pointed at the server (e.g., via Cloudflare CNAME), Caddy needs to:
1. Complete the TLS handshake with a valid certificate
2. Route the request to a backend service

Without the injected config, Caddy has no certificate for unknown domains and no route to handle them, resulting in HTTP 525 (SSL Handshake Failed).

### Disabling Catch-All

Set `CATCHALL_ENABLED=false` to disable this feature if you don't need custom domain support.

## Building

```bash
docker build -t mesh-router-caddy:local .
```

Caddy, caddy-docker-proxy and acmedns are pinned in the `Dockerfile` (xcaddy build).

`test/dns01/run.sh` is the DNS-01 end-to-end check: this image's Caddy obtains a wildcard
and a root cert from Pebble through the backend's acme-dns API and the PowerDNS primary,
with nothing public (needs the backend's `config/serviceAccount.json` for a throwaway user).

## Integration with mesh-router-agent

The agent writes certificates to a shared volume. This image automatically detects changes and reloads Caddy - no agent modification needed.

```
mesh-router-agent              mesh-router-caddy
       │                              │
       │ writes /certs/cert.pem       │
       ├─────────────────────────────►│
       │                              │ inotifywait detects
       │                              │ reloads via admin API
       │                              ▼
       │                         New cert active
```

## Caddyfile Requirements

The Caddyfile must enable the admin API:

```caddyfile
{
    admin localhost:2019
}
```

## License

MIT
