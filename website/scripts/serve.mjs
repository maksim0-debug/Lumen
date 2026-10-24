import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { dirname, extname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { basePath } from './site-config.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'dist');
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.xml': 'application/xml; charset=utf-8', '.txt': 'text/plain; charset=utf-8' };

export function createPreviewServer() {
  return createServer(async (request, response) => {
    const send = (status, body, type = types['.html']) => {
      response.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' });
      response.end(request.method === 'HEAD' ? undefined : body);
    };
    try {
      if (!['GET', 'HEAD'].includes(request.method)) {
        response.writeHead(405, { Allow: 'GET, HEAD' }).end();
        return;
      }
      const url = new URL(request.url, 'http://localhost');
      let pathname;
      try { pathname = decodeURIComponent(url.pathname); } catch (error) {
        if (!(error instanceof URIError)) throw error;
        send(400, 'Malformed URL', types['.txt']);
        return;
      }
      // The local preview uses the same mount point as GitHub Pages.
      if (pathname === '/' || pathname === basePath.slice(0, -1)) {
        response.writeHead(301, { Location: basePath + url.search }).end();
        return;
      }
      if (!pathname.startsWith(basePath)) {
        send(404, await readFile(resolve(root, '404.html')));
        return;
      }
      const relativePath = pathname.slice(basePath.length);
      let path = resolve(root, relativePath);
      if (relativePath.split(/[\\/]/).includes('..') || (path !== root && !path.startsWith(root + sep))) {
        send(403, 'Forbidden', types['.txt']);
        return;
      }
      let status;
      try { status = await stat(path); } catch (error) {
        if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
      }
      if (!status) {
        send(404, await readFile(resolve(root, '404.html')));
        return;
      }
      if (status.isDirectory()) {
        if (!pathname.endsWith('/')) {
          response.writeHead(301, { Location: url.pathname + '/' + url.search }).end();
          return;
        }
        path = resolve(path, 'index.html');
      }
      send(200, await readFile(path), types[extname(path)] || 'application/octet-stream');
    } catch (error) {
      console.error('Local preview request failed:', error.message);
      send(500, 'Preview server error', types['.txt']);
    }
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const server = createPreviewServer();
  server.listen(Number(process.env.PORT || 4173), '127.0.0.1', () => console.log('Local: http://127.0.0.1:' + server.address().port + basePath));
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
}
