import { readFile, readdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { contentPaths, siteUrl } from './site-config.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const keyFiles = (await readdir(root)).filter(name => /^[a-f0-9]{32}\.txt$/.test(name));
if (keyFiles.length !== 1) throw new Error('Expected exactly one public IndexNow ownership key file.');
const key = (await readFile(resolve(root, keyFiles[0]), 'utf8')).trim();
if (keyFiles[0] !== `${key}.txt`) throw new Error('IndexNow ownership filename does not match its content.');
const host = siteUrl.host;
const keyLocation = new URL(keyFiles[0], siteUrl).href;
const publicKey = await fetch(keyLocation, { signal: AbortSignal.timeout(15000) });
if (!publicKey.ok || (await publicKey.text()).trim() !== key) throw new Error('The deployed ownership key is not available yet.');
const response = await fetch('https://api.indexnow.org/indexnow', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json; charset=utf-8' },
  body: JSON.stringify({ host, key, keyLocation, urlList: contentPaths.map(path => new URL(path, siteUrl).href) }),
  signal: AbortSignal.timeout(20000),
});
if (![200, 202].includes(response.status)) throw new Error(`IndexNow rejected the notification: HTTP ${response.status}: ${(await response.text()).slice(0,500)}`);
console.log(`IndexNow received 2 URL notifications: HTTP ${response.status}. This is not a confirmation of indexing.`);
