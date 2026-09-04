// PREVIEW PARITY — `vite preview` is the production surface (see Dockerfile).
//
// Vite runs only configurePreviewServer under preview. Ten data proxies
// registered nothing there, so a production build had no flights, satellites,
// roads, CCTV, fires, traffic, terrain, or bike share — while the dev server,
// the only thing anyone ran locally, had all of them. These cases pin the
// preview surface to the dev surface so the gap cannot reopen.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import createViteConfig from '../vite.config.js';

const PARITY = [
  'opensky-proxy', 'celestrak-proxy', 'tomtom-proxy', 'firms-proxy',
  'terrain-heights-proxy', 'adsbdb-proxy', 'overpass-proxy', 'cctv-proxy',
  'gbfs-proxy', 'adsblol-proxy',
];

const config = createViteConfig({ mode: 'test' });
const byName = new Map(config.plugins.map((plugin) => [plugin.name, plugin]));

test('every data proxy serves the same middleware on vite preview as on the dev server', () => {
  for (const name of PARITY) {
    const plugin = byName.get(name);
    assert.ok(plugin, `${name} is registered`);
    assert.equal(typeof plugin.configurePreviewServer, 'function', `${name} has a preview hook`);
    // Identity, not just presence: the preview hook IS the dev hook, so the
    // two middleware sets cannot drift apart by being edited separately.
    assert.equal(plugin.configurePreviewServer, plugin.configureServer, `${name} preview hook is the dev hook`);
  }
});

test('parity is applied per plugin, never blanket', () => {
  // Provider Settings restarts the dev server after a save; preview cannot,
  // and a hosted instance disables the panel anyway (loopback-only gate).
  assert.equal(byName.get('gev-key-setup').configurePreviewServer, undefined);
  // vite-plugin-cesium's configureServer is dev-only by its own design.
  const cesium = config.plugins.find((plugin) => /cesium/i.test(plugin.name) && plugin.name !== 'gev-api-host-guard');
  assert.ok(cesium, 'cesium plugin is registered');
  assert.equal(cesium.configurePreviewServer, undefined, 'cesium must not be given a preview hook');
});

test('preview mirrors the dev server bindings and document headers', () => {
  // A hosted build must not be quietly less protected than a local one.
  assert.deepEqual(config.preview.allowedHosts, config.server.allowedHosts);
  assert.deepEqual(config.preview.headers, config.server.headers);
  assert.equal(config.preview.host, config.server.host);
  assert.equal(config.preview.port, config.server.port);
});
