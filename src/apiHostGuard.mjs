import net from 'node:net';

/**
 * Re-apply Vite's `server.allowedHosts` policy in front of the `/api` surface.
 *
 * Vite collects every `configureServer` hook BEFORE installing its own guards.
 * In vite 6.4.3 `postHooks.push(await hook(server))` runs at
 * `dist/node/chunks/dep-*.js:38814`, while `middlewares.use(hostCheckMiddleware(...))`
 * only runs at `:38827` (preview: `:48434` vs `:48438`). Every data proxy in
 * vite.config.js calls `server.middlewares.use()` synchronously inside its hook,
 * so all of them sit AHEAD of the host check in the connect stack and answer
 * before the Host header is ever validated.
 *
 * That left the whole key-brokering `/api` surface reachable under any Host —
 * the exact DNS-rebinding path `allowedHosts` exists to close. A page on
 * attacker.tld served with a short-TTL record, rebound to 127.0.0.1, reaches
 * `/api/realtime/token` as SAME-ORIGIN (so CORS never applies) and reads a live
 * OpenAI ephemeral credential; every other proxy becomes drivable the same way.
 *
 * `/api/setup/*` was never exposed: it runs its own loopback + Host + Origin
 * gate (`admitKeySetupRequest`). This module generalizes that idea to the
 * proxies, as one gate registered ahead of all of them — so a proxy added later
 * is covered the moment it is added, rather than needing to remember the check.
 *
 * Moving the proxies behind Vite's own check (returning a post-hook from
 * `configureServer`) would also close it, but that lands them after
 * `htmlFallbackMiddleware` and `serveStaticMiddleware`, changing routing for
 * ~25 endpoints. Re-stating the policy here changes routing for none.
 */

/**
 * Mirror of vite's `isHostAllowedWithoutCache`, so a Host the app document
 * accepts is a Host the API accepts and the two cannot drift apart.
 *
 * IP literals pass — a browser cannot be rebound onto one, because rebinding
 * works by changing what a NAME resolves to. `localhost` and any `.localhost`
 * subdomain pass. Configured entries match exactly, or as a leading-dot suffix
 * (`.local` matches `local` and `gev.local`). `allowedHosts === true` — what
 * vite.config.js sets when the operator opts into LAN exposure with
 * HOST=0.0.0.0 — disables the gate, exactly as it disables vite's own.
 *
 * @param {unknown} hostHeader Raw `Host` request header.
 * @param {string[]|true} allowedHosts Resolved `server.allowedHosts`.
 * @returns {boolean} True when the request may reach an /api handler.
 */
export function isApiHostAllowed(hostHeader, allowedHosts) {
  if (allowedHosts === true) return true;
  if (typeof hostHeader !== 'string') return false;
  const host = hostHeader.trim();
  if (!host) return false;
  // Bracketed IPv6 authority: `[::1]:4173`. An unclosed bracket is malformed.
  if (host[0] === '[') {
    const end = host.indexOf(']');
    if (end < 0) return false;
    return net.isIP(host.slice(1, end)) === 6;
  }
  const colon = host.indexOf(':');
  const hostname = colon === -1 ? host : host.slice(0, colon);
  if (net.isIP(hostname) === 4) return true;
  if (hostname === 'localhost' || hostname.endsWith('.localhost')) return true;
  const list = Array.isArray(allowedHosts) ? allowedHosts : [];
  for (const allowed of list) {
    if (typeof allowed !== 'string') continue;
    if (allowed === hostname) return true;
    if (allowed[0] === '.' && (allowed.slice(1) === hostname || hostname.endsWith(allowed))) return true;
  }
  return false;
}

/**
 * Build the Connect middleware that refuses a disallowed Host on `/api`.
 *
 * Only `/api` is gated: everything else is already covered by vite's own check,
 * which still runs behind this one.
 *
 * @param {{allowedHosts: string[]|true}} options
 * @returns {(req: any, res: any, next: () => void) => void}
 */
export function createApiHostGuard({ allowedHosts } = {}) {
  return function gevApiHostGuard(req, res, next) {
    const url = String(req?.url || '');
    // Match `/api`, `/api/...`, `/api?...` — but never `/apixyz`.
    const isApi = url === '/api'
      || url.startsWith('/api/')
      || url.startsWith('/api?')
      || url.startsWith('/api#');
    if (!isApi) return next();
    if (isApiHostAllowed(req?.headers?.host, allowedHosts)) return next();
    res.statusCode = 403;
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Cache-Control', 'no-store');
    // Never echo the rejected host or the allowlist back to the caller.
    res.end(JSON.stringify({ error: 'Request host is not allowed' }));
  };
}

/**
 * Vite plugin registering the guard ahead of every proxy, on both the dev and
 * preview servers. `enforce: 'pre'` plus first position in the plugins array
 * makes "ahead of" a property of the plugin order rather than a coincidence.
 *
 * @param {{allowedHosts: string[]|true}} options
 */
export function apiHostGuardPlugin({ allowedHosts } = {}) {
  const install = (server) => {
    server.middlewares.use(createApiHostGuard({ allowedHosts }));
  };
  return {
    name: 'gev-api-host-guard',
    enforce: 'pre',
    configureServer: install,
    configurePreviewServer: install,
  };
}
