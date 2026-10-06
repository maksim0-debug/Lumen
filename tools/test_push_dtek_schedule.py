import contextlib
from datetime import datetime, timezone
import http.server
import io
import json
import threading
import time
import unittest

from push_dtek_schedule import GROUPS, canonical_snapshot, send_html_to_worker, worker_endpoint


class BridgeTests(unittest.TestCase):
    def fixture(self):
        return {"today": 1791234000, "update": "06.10.2026 10:00", "data": {
            "1791234000": {g: {str(h): "yes" for h in range(1, 25)} for g in GROUPS}}}

    def test_complete_runtime_data_and_double_encoded_json(self):
        for value in (self.fixture(), json.dumps(self.fixture())):
            html = canonical_snapshot(value, now=datetime(2026, 10, 6, 12, tzinfo=timezone.utc))
            self.assertIn('DisconSchedule.fact = {', html)
            self.assertIn('GPV6.2', html)

    def test_null_and_partial_snapshots_rejected(self):
        for value in (None, 'null', {}, {"today": True, "data": {}}):
            with self.assertRaises(ValueError):
                canonical_snapshot(value)
        value = self.fixture()
        del value['data'][str(value['today'])]['GPV6.2']['24']
        with self.assertRaises(ValueError):
            canonical_snapshot(value)

    def test_stale_and_ambiguous_versions_rejected(self):
        for change in ({'today': 1791147600}, {'update': '31.02.2026 10:00'}, {'update': '06.10.2026 23:00'}):
            value = self.fixture()
            value.update(change)
            with self.assertRaises(ValueError):
                canonical_snapshot(value, now=datetime(2026, 10, 6, 12, tzinfo=timezone.utc))

        # Update within 60 minutes in the future is accepted
        valid_future = self.fixture()
        valid_future['update'] = '06.10.2026 15:30'
        html = canonical_snapshot(valid_future, now=datetime(2026, 10, 6, 12, 0, tzinfo=timezone.utc))
        self.assertIn('DisconSchedule.fact', html)

        # Non-existent spring local gap time is rejected
        spring_gap = self.fixture()
        spring_gap['today'] = 1774735200  # 29.03.2026
        spring_gap['data'] = {str(spring_gap['today']): self.fixture()['data']['1791234000']}
        spring_gap['update'] = '29.03.2026 03:30'
        with self.assertRaises(ValueError):
            canonical_snapshot(spring_gap, now=datetime(2026, 3, 29, 12, tzinfo=timezone.utc))

        # Tomorrow fallback key (timestamp + 86400) is accepted
        fallback_val = self.fixture()
        fallback_val['data'][str(fallback_val['today'] + 86400)] = self.fixture()['data']['1791234000']
        html_fb = canonical_snapshot(fallback_val, now=datetime(2026, 10, 6, 12, tzinfo=timezone.utc))
        self.assertIn('DisconSchedule.fact', html_fb)

    def test_tomorrow_keys_must_be_midnight_and_unambiguous(self):
        value = self.fixture()
        day = value['data'][str(value['today'])]
        value['data'][str(value['today'] + 90000)] = day
        with self.assertRaises(ValueError):
            canonical_snapshot(value, now=datetime(2026, 10, 6, 12, tzinfo=timezone.utc))
        value['data'][str(value['today'] + 86400)] = day
        with self.assertRaises(ValueError):
            canonical_snapshot(value, now=datetime(2026, 10, 6, 12, tzinfo=timezone.utc))

    def test_autumn_dst_accepted_and_invalid_placeholders_are_rejected(self):
        value = self.fixture()
        value['today'] = int(datetime(2026, 10, 24, 21, tzinfo=timezone.utc).timestamp())
        value['data'] = {str(value['today']): self.fixture()['data']['1791234000']}
        value['update'] = '25.10.2026 03:30'
        html = canonical_snapshot(value, now=datetime(2026, 10, 25, 12, tzinfo=timezone.utc))
        self.assertIn('DisconSchedule.fact', html)

        # Preposition 'о' is also accepted
        value['update'] = '25.10.2026 о 03:30'
        html_prep = canonical_snapshot(value, now=datetime(2026, 10, 25, 12, tzinfo=timezone.utc))
        self.assertIn('DisconSchedule.fact', html_prep)

        value = self.fixture()
        value['data'][str(value['today'] + 86400)] = {g: 0 for g in GROUPS}
        with self.assertRaises(ValueError):
            canonical_snapshot(value, now=datetime(2026, 10, 6, 12, tzinfo=timezone.utc))

    def test_unsafe_urls_rejected(self):
        for url in ('http://example.com', 'https://user:pass@example.com', 'https://example.com?a=1', 'https://example.com#x'):
            with self.assertRaises(ValueError):
                worker_endpoint(url)
        self.assertIn('/check-html?', worker_endpoint('http://127.0.0.1:8000/'))

    def test_http_status_report_redirect_and_total_timeout(self):
        visits = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                visits.append(self.path)
                self.rfile.read(int(self.headers['Content-Length']))
                path = self.path.split('?')[0]
                if path.startswith('/redirect'):
                    self.send_response(302)
                    self.send_header('Location', '/destination')
                    self.end_headers()
                    return
                self.send_response(503 if path.startswith('/unavailable') else 200)
                self.end_headers()
                if path.startswith('/slow'):
                    try:
                        for _ in range(20):
                            self.wfile.write(b' ')
                            self.wfile.flush()
                            time.sleep(0.02)
                    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                        pass
                    return
                if path.startswith('/html'):
                    self.wfile.write(b'<html>login</html>')
                    return
                report = {'status': 'dry_run_success' if path.startswith('/dry') else 'success',
                          'checkedGroups': 12, 'errors': ['failed'] if path.startswith('/error') else []}
                self.wfile.write(json.dumps(report).encode())

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f'http://127.0.0.1:{server.server_port}'
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertTrue(send_html_to_worker('schedule', base+'/ok', 'secret'))
                self.assertTrue(send_html_to_worker('schedule', base+'/dry', 'secret', dry_run=True))
                for path in ('redirect', 'html', 'error', 'unavailable'):
                    self.assertFalse(send_html_to_worker('schedule', base+'/'+path, 'secret'))
                start = time.monotonic()
                self.assertFalse(send_html_to_worker('schedule', base+'/slow', 'secret', timeout_seconds=0.08))
                self.assertLess(time.monotonic()-start, 0.5)
            self.assertFalse(any('/destination' in path for path in visits))
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == '__main__':
    unittest.main()
