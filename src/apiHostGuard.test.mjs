import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { isApiHostAllowed, createApiHostGuard, apiHostGuardPlugin } from './apiHostGuard.mjs';

const LOCAL = ['localhost', '127.0.0.1', '.local'];

function callGuard({ url = '/api/realtime/token', host = 'localhost:4173', allowedHosts = LOCAL } = {}) {
  const res = {
    statusCode: 200,
    headers: {},
    body: undefined,
    setHeader(name, value) { this.headers[name.toLowerCase()] = value; },
    end(payload) { this.body = payload; this.ended = true; },
  };
  let nexted = false;
  createApiHostGuard({ allowedHosts })({ url, headers: { host } }, res, () => { nexted = true; });
  return { res, nexted };
}

test('a rebound attacker hostname cannot reach the API', () => {
  // The finding: attacker.tld with a short TTL rebound to 127.0.0.1 reaches
  // /api/realtime/token as same-origin, so CORS never applies, and reads a
  // live OpenAI ephemeral credential.
  const { res, nexted } = callGuard({ host: 'attacker.tld:4173' });
  assert.equal(nexted, false);
  assert.equal(res.statusCode, 403);
  assert.equal(res.headers['cache-control'], 'no-store');
  // The rejection must not disclose the host or the allowlist.
  assert.equal(res.body, JSON.stringify({ error: 'Request host is not allowed' }));
  assert.doesNotMatch(res.body, /attacker\.tld|localhost|127\.0\.0\.1/);
});

test('ordinary local browsing still reaches the API', () => {
  for (const host of ['localhost:4173', '127.0.0.1:4173', 'gev.local:4173', 'local', '[::1]:4173', 'app.localhost:4173']) {
    assert.equal(callGuard({ host }).nexted, true, `${host} should be admitted`);
  }
});

test('IP-literal hosts pass, matching vite — rebinding needs a name', () => {
  assert.equal(isApiHostAllowed('192.168.1.50:4173', LOCAL), true);
  assert.equal(isApiHostAllowed('[fe80::1]:4173', LOCAL), true);
});

test('a malformed or absent Host is refused rather than assumed local', () => {
  for (const host of [undefined, null, '', '   ', 42, '[::1', '[notanip]']) {
    assert.equal(isApiHostAllowed(host, LOCAL), false, `${String(host)} should be refused`);
  }
});

test('leading-dot entries match the bare name and subdomains, not lookalikes', () => {
  assert.equal(isApiHostAllowed('local', LOCAL), true);
  assert.equal(isApiHostAllowed('gev.local', LOCAL), true);
  assert.equal(isApiHostAllowed('evillocal', LOCAL), false);
  assert.equal(isApiHostAllowed('localhost.evil.tld', LOCAL), false);
  assert.equal(isApiHostAllowed('evil.tld', LOCAL), false);
});

test('opting into LAN exposure disables the gate, exactly as it disables vite’s', () => {
  // HOST=0.0.0.0 sets allowedHosts:true; the LAN warning is the operator's
  // consent, and LAN devices legitimately arrive with a LAN-IP or name Host.
  assert.equal(isApiHostAllowed('anything.example', true), true);
  assert.equal(callGuard({ host: 'anything.example', allowedHosts: true }).nexted, true);
});

test('only the /api surface is gated', () => {
  // Everything else is already behind vite's own check, which still runs after.
  for (const url of ['/', '/index.html', '/src/main.js', '/@vite/client', '/apixyz']) {
    assert.equal(callGuard({ url, host: 'attacker.tld' }).nexted, true, `${url} should pass through`);
  }
  for (const url of ['/api', '/api?x=1', '/api/setup/status', '/api/ais-live']) {
    assert.equal(callGuard({ url, host: 'attacker.tld' }).nexted, false, `${url} should be gated`);
  }
});

test('the guard is registered ahead of the proxies on dev AND preview', () => {
  // Preview has the same ordering gap (postHooks run before its host check),
  // and 10 proxies register a configurePreviewServer hook.
  const plugin = apiHostGuardPlugin({ allowedHosts: LOCAL });
  assert.equal(plugin.enforce, 'pre');
  for (const hook of ['configureServer', 'configurePreviewServer']) {
    const used = [];
    plugin[hook]({ middlewares: { use: (fn) => used.push(fn) } });
    assert.equal(used.length, 1, `${hook} must install the guard`);
  }
});

test('vite.config.js installs the guard before any proxy plugin', () => {
  // A new proxy added above the guard would silently reopen the hole.
  const source = readFileSync(fileURLToPath(new URL('../vite.config.js', import.meta.url)), 'utf8');
  const guardAt = source.indexOf('apiHostGuardPlugin({ allowedHosts })');
  const firstProxyAt = source.indexOf('Proxy()', source.indexOf('plugins: ['));
  assert.ok(guardAt > 0, 'the guard must be registered in the plugins array');
  assert.ok(guardAt < firstProxyAt, 'the guard must come before the first proxy plugin');
  // And the same allowedHosts value must feed vite's own check.
  assert.match(source, /\n {6}allowedHosts,\n/);
});
