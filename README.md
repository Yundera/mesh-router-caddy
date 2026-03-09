# mesh-router-caddy

A custom Caddy Docker image extending [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) with automatic certificate reload, Caddyfile reload, and catch-all domain support.

## Features

- **Auto-reload certificates**: Watches certificate files and reloads Caddy when they change
- **Auto-reload Caddyfile**: Watches Caddyfile and reloads Caddy when it changes
- **Catch-all custom domains**: Auto-injects on_demand TLS policy for unknown domains
- **Zero-downtime**: Uses Caddy admin API for graceful reloads
- **Docker label routing**: Inherits all caddy-docker-proxy features

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
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - certs:/certs:ro
    environment:
      - CADDY_DOCKER_CADDYFILE_PATH=/etc/caddy/Caddyfile
      - CADDY_INGRESS_NETWORKS=mesh
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CERT_PATH` | `/certs/cert.pem` | Path to certificate file to watch |
| `CADDYFILE_PATH` | `/etc/caddy/Caddyfile` | Path to Caddyfile to watch |
| `CADDY_ADMIN` | `localhost:2019` | Caddy admin API address |
| `CATCHALL_ENABLED` | `true` | Enable catch-all domain injection |
| `DEFAULT_SERVICE_HOST` | `casaos` | Target host for catch-all route |
| `DEFAULT_SERVICE_PORT` | `8080` | Target port for catch-all route |
| `CATCHALL_CHECK_INTERVAL` | `5` | Seconds between catch-all config checks |

Plus all [caddy-docker-proxy environment variables](https://github.com/lucaslorentz/caddy-docker-proxy#environment-variables).

## How It Works

1. Starts caddy-docker-proxy normally
2. Waits for Caddy admin API to be ready
3. Spawns three background watchers:
   - **Cert watcher**: On certificate change, removes and re-adds the TLS certificate via admin API
   - **Caddyfile watcher**: On Caddyfile change, runs `caddy reload`
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
