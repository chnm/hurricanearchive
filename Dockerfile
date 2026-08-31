# syntax=docker/dockerfile:1.7

FROM stagex/pallet-nodejs AS build-stage

# stagex/user-hugo-extended ships the binary inside a directory at
# /usr/bin/hugo/, named "hugo_exended" (sic — the missing 'x' is upstream's).
# Copying the dir itself would make /usr/local/bin/hugo a directory, which
# then fails `RUN hugo` with "Permission denied". Copy the actual file.
COPY --from=stagex/user-hugo-extended /usr/bin/hugo/hugo_exended /usr/local/bin/hugo

ARG hugobuildargs
ENV HUGO_BUILD_ARGS=$hugobuildargs

WORKDIR /app
COPY . .

RUN npm ci
RUN hugo ${HUGO_BUILD_ARGS}
# Build the pagefind search index. Restrict the walk to real item pages
# (items/<id>/index.html — the single-segment glob skips the ~46k two-segment
# /items/show/<id> alias redirect stubs that previously OOM-ed the indexer),
# and the item template marks only its content with data-pagefind-body.
RUN npx --no-install pagefind --site public --glob "items/*/index.html"

FROM stagex/user-caddy

COPY --from=stagex/core-musl / /
COPY --from=build-stage /app/public /srv
# Legacy-URL 301s (map {path} fragment). On the CHNM deploy path this container's
# Caddyfile is discarded — the pipeline extracts /srv and the target host's Caddy
# imports redirects.caddy from the deployed content root. So it MUST live inside
# /srv; anywhere else and it's absent from the release artifact and every legacy
# URL 404s. Landing it at /srv/redirects.caddy also gives `docker run` local-dev
# parity below.
COPY --from=build-stage /app/redirects.caddy /srv/redirects.caddy

COPY <<'EOF' /etc/caddy/Caddyfile
{
	auto_https off
	admin off
}

:80 {
	root * /srv
	encode gzip zstd

	# Legacy Omeka URL redirects (301s). Kept first so they win before
	# file_server. /files/* is intentionally absent — the fronting web server
	# serves media from the file store.
	import /srv/redirects.caddy

	# Backward compatibility: /img/* serves from /assets/img/*
	rewrite /img/* /assets{uri}

	file_server
}
EOF

ENV XDG_CONFIG_HOME=/tmp/caddy-config \
    XDG_DATA_HOME=/tmp/caddy-data

EXPOSE 80
ENTRYPOINT ["/usr/bin/caddy"]
CMD ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
