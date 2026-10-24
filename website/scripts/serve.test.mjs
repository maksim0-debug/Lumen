import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { createPreviewServer } from './serve.mjs';
import { basePath } from './site-config.mjs';

const server = createPreviewServer();
let origin;
before(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
});
after(() => new Promise(resolve => server.close(resolve)));
const request = (path, options) => fetch(origin + path, { redirect: 'manual', signal: AbortSignal.timeout(5000), ...options });

test('home, nested privacy page and assets are available under the project path', async () => {
  for (const path of ['', 'privacy/', 'assets/styles.css', 'assets/screenshots/home.png', 'llms.txt', 'sitemap.xml', 'site.webmanifest']) {
    const response = await request(basePath + path);
    assert.equal(response.status, 200, path);
    assert.ok((await response.arrayBuffer()).byteLength > 0, path);
  }
});

test('directory redirects preserve the project path and query', async () => {
  for (const [from, to] of [['/', basePath], [basePath.slice(0, -1) + '?source=test', basePath + '?source=test'], [basePath + 'privacy?source=test', basePath + 'privacy/?source=test']]) {
    const response = await request(from);
    assert.equal(response.status, 301, from);
    assert.equal(response.headers.get('location'), to, from);
  }
});

test('old host-root assets, lookalike prefixes, source files and missing pages return real 404s', async () => {
  for (const path of ['/assets/styles.css', basePath.slice(0, -1) + '-other/', basePath + 'missing/', basePath + 'README.md', basePath + 'qa/publish-state.json', basePath + '.agents/', basePath + 'scripts/build.mjs', basePath + 'package.json']) {
    const response = await request(path);
    assert.equal(response.status, 404, path);
    assert.match(await response.text(), /noindex, follow/);
  }
});

test('HEAD responses have no body and preserve successful and missing status codes', async () => {
  for (const [path, status] of [[basePath, 200], [basePath + 'missing/', 404]]) {
    const response = await request(path, { method: 'HEAD' });
    assert.equal(response.status, status);
    assert.equal(await response.text(), '');
  }
});

test('malformed encoding and encoded Windows path traversal cannot expose source files', async () => {
  assert.equal((await request(basePath + '%E0%A4')).status, 400);
  assert.equal((await request(basePath + '..%5cpackage.json')).status, 403);
});
