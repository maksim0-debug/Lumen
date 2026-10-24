import assert from 'node:assert/strict';
import { readFile, readdir, stat } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { basePath, contentPaths, siteUrl } from './site-config.mjs';

const source = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = join(source, 'dist');
const pages = contentPaths.map(path => new URL(path, siteUrl).pathname);
let checks = 0;
const verify = (condition, message) => { assert.ok(condition, message); checks++; };
const read = path => readFile(join(root, path), 'utf8');
const fileFor = pathname => pathname.slice(basePath.length) + (pathname.endsWith('/') ? 'index.html' : '');
const idsByPage = new Map();

for (const page of pages) {
  const html = await read(fileFor(page));
  verify(/<html lang="uk">/.test(html), page + ': Ukrainian language missing');
  verify((html.match(/<h1[ >]/g) || []).length === 1, page + ': expected one h1');
  verify(/<title>[^<]+<\/title>/.test(html), page + ': title missing');
  verify(/name="description" content="[^"]+"/.test(html), page + ': description missing');
  verify(html.includes('rel="canonical" href="' + siteUrl.origin + page + '"'), page + ': wrong canonical');
  verify(!/<meta[^>]+content="[^"]*noindex/i.test(html), page + ': unexpected noindex');
  verify(!/https:\/\/(?:fonts\.googleapis|www\.googletagmanager|www\.google-analytics)/.test(html), page + ': unexpected third-party runtime request');
  const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
  verify(new Set(ids).size === ids.length, page + ': duplicate IDs');
  idsByPage.set(page, new Set(ids));
}

for (const page of [...pages, basePath + '404.html']) {
  const html = await read(fileFor(page));
  for (const [, attribute, target] of html.matchAll(/\b(href|src)="([^"]+)"/g)) {
    const url = new URL(target, siteUrl.origin + page);
    if (url.origin !== siteUrl.origin) continue;
    verify(url.pathname.startsWith(basePath), page + ': ' + attribute + ' escapes project path: ' + target);
    if (url.hash && idsByPage.has(url.pathname)) verify(idsByPage.get(url.pathname).has(url.hash.slice(1)), page + ': missing anchor ' + target);
    verify((await stat(join(root, fileFor(url.pathname)))).isFile(), page + ': missing ' + attribute + ' ' + target);
  }
}

const home = await read('index.html');
const json = JSON.parse(home.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
const app = json['@graph'].find(entry => entry['@type'] === 'SoftwareApplication');
verify(app.url === siteUrl.href, 'Application URL must match canonical');
verify(app.operatingSystem.includes('Android') && app.operatingSystem.includes('Windows'), 'Application platforms missing');
verify(!app.aggregateRating && !app.review, 'Unverified rating/review found');
verify(home.includes('приклад даних') && home.includes('Дані на екранах наведено для прикладу'), 'Historical screenshot disclosure missing');
verify(home.includes('власний датчик') && home.includes('не є офіційним'), 'Product limitations missing');
verify((home.match(/data-download="/g) || []).length === 5, 'Expected Android, Windows and portable download links');
for (const [, href] of home.matchAll(/href="([^"]+)" data-download=/g)) verify(href.startsWith('https://github.com/maksim0-debug/Lumen/releases/latest/download/'), 'Download must track latest release');

const sitemap = await read('sitemap.xml');
verify((sitemap.match(/<loc>/g) || []).length === pages.length, 'Sitemap should list only the two public content pages');
for (const page of pages) verify(sitemap.includes('<loc>' + siteUrl.origin + page + '</loc>'), 'Missing sitemap URL ' + page);
const robots = await read('robots.txt');
verify(robots.includes('User-agent: *') && robots.includes('Allow: /') && !robots.includes('Disallow: /'), 'Public crawling unexpectedly blocked');
verify(robots.includes('Sitemap: ' + new URL('sitemap.xml', siteUrl).href), 'Sitemap URL is outdated');
verify(robots.includes('not a host-wide robots.txt'), 'Project-local robots scope must be documented');
verify((await read('404.html')).includes('noindex, follow'), '404 should not be indexed');
verify((await stat(join(root, 'assets/social.png'))).size > 1000, 'Social preview image missing');
const manifest = JSON.parse(await read('site.webmanifest'));
verify(manifest.start_url === basePath && manifest.scope === basePath, 'Manifest must remain inside the project path');
for (const icon of manifest.icons) {
  verify(icon.src.startsWith(basePath), 'Manifest icon escapes project path');
  verify((await stat(join(root, fileFor(icon.src)))).isFile(), 'Manifest icon missing');
}
JSON.parse(await read('assets/screenshots/sources.json'));

// Catch stale host-root URLs even inside JSON-LD, social tags and llms.txt.
for (const path of ['index.html', 'privacy/index.html', 'llms.txt', 'sitemap.xml', 'site.webmanifest', 'robots.txt']) {
  for (const [target] of (await read(path)).matchAll(/https:\/\/maksim0-debug\.github\.io\/[^\s"<>)]*/g)) {
    verify(new URL(target).pathname.startsWith(basePath), path + ': stale first-party URL ' + target);
  }
}
const verificationFiles = (await readdir(source)).filter(name => /^google[a-f0-9]+\.html$/i.test(name) || name === 'BingSiteAuth.xml' || /^[a-f0-9]{32}\.txt$/i.test(name));
verify(verificationFiles.includes('googlecb163c8d2d73a784.html'), 'Supplied Google ownership file missing');
for (const name of verificationFiles) verify((await readFile(join(source, name))).equals(await readFile(join(root, name))), name + ': ownership proof changed during build');
for (const path of ['README.md', 'package.json', 'scripts', 'qa', '.agents', '.github']) {
  await assert.rejects(stat(join(root, path)), { code: 'ENOENT' }, path + ': private source must not be published');
  checks++;
}
verify(!/fetch\(|localStorage|document\.cookie|sendBeacon/.test(await read('assets/site.js')), 'Site privacy assumptions changed');
console.log('Site checks passed: ' + checks + '. Project paths, metadata, assets, anchors, downloads, sitemap, ownership files and artifact boundaries verified.');
