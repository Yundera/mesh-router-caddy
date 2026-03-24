FROM lucaslorentz/caddy-docker-proxy:ci-alpine

RUN apk add --no-cache inotify-tools curl

COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
