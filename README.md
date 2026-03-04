# mesh-router-caddy

A custom Caddy Docker image extending [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) with automatic certificate and Caddyfile reload capabilities.

## Features

- **Auto-reload certificates**: Watches certificate files and reloads Caddy when they change
- **Auto-reload Caddyfile**: Watches Caddyfile and reloads Caddy when it changes
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

Plus all [caddy-docker-proxy environment variables](https://github.com/lucaslorentz/caddy-docker-proxy#environment-variables).

## How It Works

1. Starts caddy-docker-proxy normally
2. Waits for Caddy admin API to be ready
3. Spawns two background watchers using `inotifywait`:
   - **Cert watcher**: On certificate change, removes and re-adds the TLS certificate via admin API
   - **Caddyfile watcher**: On Caddyfile change, runs `caddy reload`

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
