#!/bin/sh
# Start the app behind Caddy. Caddy runs as PID 1 so platform signals reach
# it; Node is a child that is torn down with the container.
set -eu

: "${BASIC_AUTH_USER:?BASIC_AUTH_USER is required}"
: "${BASIC_AUTH_HASH:?BASIC_AUTH_HASH is required (bcrypt, from 'caddy hash-password')}"

# The preview server is the production surface: it serves dist/ and carries
# the full /api proxy layer. It binds to loopback only; Caddy is the sole
# listener on the container interface.
node ./node_modules/vite/bin/vite.js preview \
  --host "${HOST:-127.0.0.1}" \
  --port "${PORT:-4173}" \
  --strictPort &
NODE_PID=$!

# If Node dies, take the container down with it rather than serving 502s
# behind a green health check.
( while kill -0 "$NODE_PID" 2>/dev/null; do sleep 5; done; echo "node exited; stopping caddy"; kill -TERM 1 ) &

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
