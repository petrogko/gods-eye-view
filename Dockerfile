# God's Eye View — production container.
#
# Two stages: build the static bundle, then run `vite preview` (which carries
# the full /api proxy layer — see vite.config.js) behind Caddy. Caddy owns the
# public port, enforces HTTP basic auth, and exposes an unauthenticated
# /healthz for the platform health check. The Node process only ever listens
# on loopback inside the container.
#
# The two public-by-design keys (Google Maps, Cesium ion) are BUILD args: Vite
# inlines them into the bundle via `define`. Restrict both at the provider to
# the deployed hostname. Every other key is a RUNTIME secret and never enters
# the image.

# ---------- build ----------
FROM node:24-slim AS build
WORKDIR /app
ENV PUPPETEER_SKIP_DOWNLOAD=1 \
    CI=1
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
ARG GOOGLE_MAPS_API_KEY=""
ARG CESIUM_ION_TOKEN=""
ENV GOOGLE_MAPS_API_KEY=${GOOGLE_MAPS_API_KEY} \
    CESIUM_ION_TOKEN=${CESIUM_ION_TOKEN}
RUN npm run build \
 # Dev-only tooling the preview server never loads; keeps the runtime image small.
 && rm -rf node_modules/puppeteer node_modules/puppeteer-core node_modules/@puppeteer \
           node_modules/sharp node_modules/@img node_modules/.cache

# ---------- runtime ----------
FROM node:24-slim AS runtime
COPY --from=caddy:2 /usr/bin/caddy /usr/bin/caddy
WORKDIR /app
COPY --from=build --chown=node:node /app /app
COPY --chown=node:node deploy/container/Caddyfile /etc/caddy/Caddyfile
COPY --chown=node:node deploy/container/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
 && mkdir -p /app/.gev-cache /app/.gev-logs /var/lib/caddy /var/lib/caddy/config \
 && chown -R node:node /app/.gev-cache /app/.gev-logs /var/lib/caddy
USER node
ENV NODE_ENV=production \
    # Node listens on loopback ONLY; Caddy is the sole listener on the container
    # interface and rewrites the upstream Host to `localhost`. That keeps vite's
    # restricted allowedHosts and the /api host guard active inside the
    # container instead of disabling both the way HOST=0.0.0.0 would.
    HOST=127.0.0.1 \
    PORT=4173 \
    PUBLIC_PORT=8080 \
    XDG_DATA_HOME=/var/lib/caddy \
    XDG_CONFIG_HOME=/var/lib/caddy/config
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8080/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
