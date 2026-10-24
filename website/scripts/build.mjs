import { cp, mkdir, readdir, rm } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = join(root, 'dist');
// Only the fixed generated directory is replaced; source files stay in place.
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
const entries = ['index.html', '404.html', 'privacy', 'assets', 'robots.txt', 'sitemap.xml', 'llms.txt', 'site.webmanifest', '.nojekyll'];
for (const entry of entries) await cp(join(root, entry), join(output, entry), { recursive: true });
// Verification files from Search Console / Bing survive future builds.
for (const entry of await readdir(root)) {
  if (/^google[a-f0-9]+\.html$/i.test(entry) || entry === 'BingSiteAuth.xml' || /^[a-f0-9]{32}\.txt$/i.test(entry)) {
    await cp(join(root, entry), join(output, entry));
  }
}
console.log(`Built ${entries.length} site entries into ${output}`);
