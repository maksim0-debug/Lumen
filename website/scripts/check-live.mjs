import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { contentPaths, siteUrl } from './site-config.mjs';

const root = resolve(import.meta.dirname, '..', 'dist');
const ownershipFiles = (await readdir(root)).filter(name => /^google[a-f0-9]+\.html$/i.test(name) || name === 'BingSiteAuth.xml' || /^[a-f0-9]{32}\.txt$/i.test(name));
const paths = [...contentPaths, '404.html', 'robots.txt', 'sitemap.xml', 'llms.txt', 'site.webmanifest', 'assets/favicon.svg', 'assets/icon.png', 'assets/styles.css', 'assets/site.js', 'assets/social.png', 'assets/screenshots/home.png', 'assets/screenshots/analytics.png', 'assets/screenshots/history.png', 'assets/screenshots/notifications.png', 'assets/screenshots/sources.json', ...ownershipFiles];
const results = await Promise.all(paths.map(async path => {
  const response = await fetch(new URL(path, siteUrl), { signal: AbortSignal.timeout(20000) });
  assert.equal(response.status, 200, `${path}: expected HTTP 200`);
  const bytes = Buffer.from(await response.arrayBuffer());
  const source = await readFile(resolve(root, path.endsWith('/') || path === '' ? path + 'index.html' : path));
  const hash = content => createHash('sha256').update(content).digest('hex');
  assert.equal(hash(bytes), hash(source), `${path}: deployed file differs from verified build`);
  return { path, status: response.status, bytes: bytes.length, matchesBuild: true };
}));
for (const userAgent of ['Googlebot', 'bingbot', 'OAI-SearchBot', 'Claude-SearchBot', 'PerplexityBot']) {
  const response = await fetch(siteUrl, { headers: { 'User-Agent': userAgent }, signal: AbortSignal.timeout(20000) });
  assert.equal(response.status, 200, `${userAgent}: main page unavailable`);
  assert.match(await response.text(), /Відключення світла/);
  results.push({ userAgent, status: response.status });
}
for (const path of ['this-page-does-not-exist/', 'README.md', 'package.json', 'qa/publish-state.json', 'scripts/build.mjs', '.agents/']) {
  const response = await fetch(new URL(path, siteUrl), { signal: AbortSignal.timeout(20000) });
  assert.equal(response.status, 404, `${path}: expected real 404`);
  assert.match(await response.text(), /noindex, follow/, `${path}: missing custom 404`);
  results.push({ path, status: response.status });
}
console.log(JSON.stringify({ site: siteUrl.href, checkedAt: new Date().toISOString(), results }, null, 2));
