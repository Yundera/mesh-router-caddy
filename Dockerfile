# Caddy with caddy-docker-proxy (labels → config) and the acme-dns DNS provider
# (DNS-01 wildcard certs through mesh-router-backend's /acme-dns API).
# Pinned: Caddy + docker-proxy are the versions the floating ci-alpine tag shipped in 1.2.7.
FROM caddy:2.11.4-builder-alpine AS build
RUN xcaddy build v2.11.4 \
      --with github.com/lucaslorentz/caddy-docker-proxy/v2@v2.13.1 \
      --with github.com/caddy-dns/acmedns@v0.7.0

# Same layout as lucaslorentz/caddy-docker-proxy: alpine, /bin/caddy, XDG dirs, no VOLUME.
FROM alpine:3.24
RUN apk add --no-cache ca-certificates inotify-tools curl jq
COPY --from=build /usr/bin/caddy /bin/caddy
ENV XDG_CONFIG_HOME=/config XDG_DATA_HOME=/data
EXPOSE 80 443 2019

COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
