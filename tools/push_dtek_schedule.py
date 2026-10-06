#!/usr/bin/env python3
"""
Lumen Schedule Fetcher & Cloudflare Worker Bridge
=================================================
Automated and interactive utility to fetch DTEK outage schedule HTML
bypassing WAF challenges, and ingest it into the Lumen Cloudflare Worker.

Usage:
  python tools/push_dtek_schedule.py [--key <ADMIN_KEY>] [--dry-run]
"""

import argparse
from datetime import datetime, timedelta, timezone
import json
import http.client
import socket
import threading
from urllib.parse import urlsplit, urlunsplit, urlencode
import os
import platform
import re
import shutil
import sys
import time
from typing import Optional
from zoneinfo import ZoneInfo

DEFAULT_WORKER_URL = "https://lumen-schedule-monitor.maksim0.workers.dev"
DTEK_URL = "https://www.dtek-krem.com.ua/ua/shutdowns"


def find_chrome_executable() -> Optional[str]:
    """Finds Google Chrome executable path dynamically based on OS."""
    system = platform.system()

    if system == "Windows":
        candidates = [
            r"C:\Program Files\Google\Chrome\Application\chrome.exe",
            r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
            os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"),
            os.path.expandvars(r"%PROGRAMFILES%\Google\Chrome\Application\chrome.exe"),
        ]
        for path in candidates:
            if os.path.isfile(path):
                return path

    elif system == "Darwin":
        candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            os.path.expanduser("~/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        ]
        for path in candidates:
            if os.path.isfile(path):
                return path

    else:
        candidates = ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"]
        for cmd in candidates:
            found = shutil.which(cmd)
            if found:
                return found

    return None


MAX_HTML_BYTES = 2 * 1024 * 1024
MAX_RESPONSE_BYTES = 64 * 1024
GROUPS = tuple(f"GPV{major}.{minor}" for major in range(1, 7) for minor in (1, 2))
STATUSES = {"yes", "no", "first", "second", "maybe", "mfirst", "msecond"}


def canonical_snapshot(value, *, now: Optional[datetime] = None) -> str:
    """Export runtime data, not a script tag that may merely assign null."""
    if isinstance(value, str):
        value = json.loads(value)
    if not isinstance(value, dict) or not isinstance(value.get("data"), dict):
        raise ValueError("Schedule is not ready")
    stamp = value.get("today")
    if isinstance(stamp, bool) or not str(stamp).isdigit() or int(stamp) <= 0:
        raise ValueError("Invalid today timestamp")
    if not isinstance(value.get("update"), str) or not value["update"].strip():
        raise ValueError("Missing update time")
    kyiv = ZoneInfo('Europe/Kyiv')
    current = (now or datetime.now(timezone.utc)).astimezone(kyiv)
    today = datetime.fromtimestamp(int(stamp), kyiv)
    if today.date() != current.date() or (today.hour, today.minute, today.second) != (0, 0, 0):
        raise ValueError("Snapshot is not for current Kyiv midnight")
    match = re.fullmatch(r'(\d{1,2})\.(\d{1,2})\.(\d{4})[\s,]+(?:[ов]\s+|at\s+)?(\d{1,2}):(\d{2})(?::(\d{2}))?', value['update'].strip())
    if match is None:
        raise ValueError("Invalid update time")
    day, month, year, hour, minute, second = match.groups()
    wall = datetime(int(year), int(month), int(day), int(hour), int(minute), int(second or 0))
    instants = {wall.replace(tzinfo=kyiv, fold=fold).timestamp() for fold in (0, 1)
                if datetime.fromtimestamp(wall.replace(tzinfo=kyiv, fold=fold).timestamp(), kyiv).replace(tzinfo=None) == wall}
    if not instants:
        raise ValueError("Invalid Kyiv update time (non-existent local time)")
    chosen_instant = max(instants)
    if chosen_instant > current.timestamp() + 4 * 3600:
        raise ValueError("Future update time exceeds 4 hours")
    day = value["data"].get(str(stamp))
    if not isinstance(day, dict):
        raise ValueError("Missing today's schedule")
    for group in GROUPS:
        hours = day.get(group)
        if not isinstance(hours, dict) or len(hours) != 24 or any(
            not isinstance(hours.get(str(hour)), str) or
            hours[str(hour)].strip().lower() not in STATUSES for hour in range(1, 25)
        ):
            raise ValueError(f"Incomplete schedule for {group}")
    tomorrow_date = (today + timedelta(days=1)).date()
    tomorrow_keys = [key for key in value['data'] if str(key).isdigit() and
                     abs(int(key) - current.timestamp()) < 3 * 86400 and
                     datetime.fromtimestamp(int(key), kyiv).date() == tomorrow_date]
    if len(tomorrow_keys) > 1:
        raise ValueError("Ambiguous tomorrow date")
    tomorrow_key = str(int((today + timedelta(days=1)).timestamp()))
    if tomorrow_keys and tomorrow_keys[0] not in {tomorrow_key, str(int(stamp) + 86400)}:
        raise ValueError("Tomorrow must be Kyiv midnight")
    tomorrow = value['data'].get(tomorrow_key)
    if tomorrow is None:
        tomorrow = value['data'].get(str(int(stamp) + 86400))
    if tomorrow is not None:
        if not isinstance(tomorrow, dict):
            raise ValueError("Invalid tomorrow schedule")
        unpublished = all(tomorrow.get(g) is None or
                          (isinstance(tomorrow.get(g), dict) and not tomorrow[g]) for g in GROUPS)
        if not unpublished:
            for group in GROUPS:
                hours = tomorrow.get(group)
                if not isinstance(hours, dict) or len(hours) != 24 or any(
                    not isinstance(hours.get(str(h)), str) or hours[str(h)].strip().lower() not in STATUSES
                    for h in range(1, 25)
                ):
                    raise ValueError(f"Incomplete tomorrow schedule for {group}")
    html = "<script>DisconSchedule.fact = " + json.dumps(value, ensure_ascii=False, separators=(",", ":")) + ";</script>"
    if len(html.encode("utf-8")) > MAX_HTML_BYTES:
        raise ValueError("Snapshot exceeds 2 MiB")
    return html


def fetch_dtek_html(chrome_path: Optional[str] = None, timeout_seconds: int = 90) -> Optional[str]:
    from playwright.sync_api import sync_playwright
    if timeout_seconds <= 0:
        raise ValueError("Timeout must be positive")
    profile_dir = os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), "LumenChromeProfile")
    deadline = time.monotonic() + timeout_seconds
    with sync_playwright() as playwright:
        kwargs = {"headless": False, "viewport": {"width": 1280, "height": 800},
                  "locale": "uk-UA", "timezone_id": "Europe/Kyiv"}
        if chrome_path:
            kwargs["executable_path"] = chrome_path
        context = None
        try:
            context = playwright.chromium.launch_persistent_context(profile_dir, **kwargs)
            page = context.pages[0] if context.pages else context.new_page()
            page.set_default_timeout(5000)
            try:
                page.goto(DTEK_URL, timeout=max(1, min(45000, int((deadline-time.monotonic())*1000))), wait_until="domcontentloaded")
            except Exception:
                print("[!] Сторінка ще завантажується; очікуємо даних графіка.")
            print("[*] Очікуємо графік. За потреби пройдіть капчу у вікні браузера.")
            while time.monotonic() < deadline and not page.is_closed():
                try:
                    value = page.evaluate("() => typeof DisconSchedule === 'undefined' ? null : DisconSchedule.fact")
                    html = canonical_snapshot(value)
                    print(f"[+] Отримано повний графік: {len(html.encode('utf-8'))} байт.")
                    return html
                except Exception:
                    # Page navigation and unfinished runtime data are retryable within the deadline.
                    if time.monotonic() >= deadline:
                        break
                    time.sleep(min(1, max(0, deadline-time.monotonic())))
            print("[-] Час очікування вичерпано; повного графіка немає.")
            return None
        except Exception as error:
            print(f"[-] Не вдалося отримати графік: {type(error).__name__}")
            return None
        finally:
            if context is not None:
                try:
                    context.close()
                except Exception:
                    pass


def worker_endpoint(worker_url: str, dry_run: bool = False) -> str:
    uri = urlsplit(worker_url)
    local = uri.hostname in {"localhost", "127.0.0.1", "::1"}
    if not uri.hostname or uri.username is not None or uri.password is not None or uri.query or uri.fragment or (
        uri.scheme != "https" and not (uri.scheme == "http" and local)
    ):
        raise ValueError("Worker URL must use HTTPS without credentials, query or fragment")
    return urlunsplit((uri.scheme, uri.netloc, uri.path.rstrip("/") + "/check-html",
                      urlencode({"source": "python_bridge", "dryRun": str(dry_run).lower()}), ""))


def send_html_to_worker(html: str, worker_url: str, admin_key: str, dry_run: bool = False,
                        *, timeout_seconds: float = 75) -> bool:
    connection = None
    timer = None
    try:
        endpoint = worker_endpoint(worker_url, dry_run)
        body = html.encode("utf-8")
        if not admin_key.strip() or not body or len(body) > MAX_HTML_BYTES or timeout_seconds <= 0:
            raise ValueError("Missing key or invalid body size")
        uri = urlsplit(endpoint)
        transport = http.client.HTTPSConnection if uri.scheme == 'https' else http.client.HTTPConnection
        connection = transport(uri.hostname, uri.port, timeout=min(10, timeout_seconds))
        deadline = time.monotonic() + timeout_seconds
        connection.connect()
        connected_socket = connection.sock
        connected_socket.settimeout(max(0.001, deadline - time.monotonic()))

        def interrupt():
            # Interrupt a slow/trickling body as well as an idle socket read.
            try:
                connected_socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        timer = threading.Timer(max(0.001, deadline - time.monotonic()), interrupt)
        timer.daemon = True
        timer.start()
        path = uri.path + ('?' + uri.query if uri.query else '')
        connection.request('POST', path, body=body, headers={
            "Content-Type": "text/html; charset=utf-8", "X-Admin-Key": admin_key.strip()})
        # http.client never follows redirects, so the secret is sent to one endpoint only.
        with connection.getresponse() as response:
            if response.status != 200:
                print(f"[-] Worker відхилив запит: HTTP {response.status}")
                return False
            chunks = bytearray()
            while True:
                chunk = response.read1(8192)
                if not chunk:
                    break
                chunks.extend(chunk)
                if len(chunks) > MAX_RESPONSE_BYTES or time.monotonic() > deadline:
                    raise ValueError("Worker response exceeds size or time limit")
            if time.monotonic() >= deadline:
                raise TimeoutError('Worker response deadline exceeded')
            report = json.loads(chunks.decode("utf-8"))
            expected = "dry_run_success" if dry_run else "success"
            success = isinstance(report, dict) and report.get("status") == expected and report.get("errors") == [] and (
                type(report.get("checkedGroups")) is int and report["checkedGroups"] > 0
            )
            print("[+] Worker обробив графік." if success else "[-] Worker не завершив обробку графіка.")
            return success
    except Exception as error:
        # Avoid leaking authorization, payloads or URLs embedded in transport exceptions.
        print(f"[-] Помилка синхронізації: {type(error).__name__}")
        return False
    finally:
        if timer is not None:
            timer.cancel()
        if connection is not None:
            connection.close()


def main():
    parser = argparse.ArgumentParser(description="Lumen DTEK Schedule Fetcher & Cloudflare Bridge")
    parser.add_argument(
        "--key",
        help="Admin key for Cloudflare Worker (or set LUMEN_ADMIN_KEY env variable)",
        default=os.environ.get("LUMEN_ADMIN_KEY", ""),
    )
    parser.add_argument(
        "--worker-url",
        help="Base URL of Cloudflare Worker",
        default=os.environ.get("LUMEN_WORKER_URL", DEFAULT_WORKER_URL),
    )
    parser.add_argument(
        "--chrome-path",
        help="Explicit path to Chrome executable",
        default=None,
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate HTML without updating monitor state or sending FCM pushes",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=90,
        help="Timeout in seconds to wait for DTEK schedule",
    )

    args = parser.parse_args()

    admin_key = args.key.strip()
    if not admin_key:
        print("[!] ПОМИЛКА: Не вказано ключ адміністратора.")
        print("    Передайте ключ через аргумент: --key <KEY>")
        print("    Або встановіть змінну середовища: set LUMEN_ADMIN_KEY=<KEY>")
        sys.exit(1)

    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    try:
        import playwright.sync_api
        worker_endpoint(args.worker_url, args.dry_run)
    except ImportError:
        parser.error("Install dependencies: pip install -r tools/requirements.txt; playwright install chromium")
    except ValueError as error:
        parser.error(str(error))
    chrome_path = args.chrome_path or find_chrome_executable()
    if not chrome_path:
        print("[!] Увага: Не вдалося знайти стандартний шлях до Chrome. Playwright спробує використати встановлений браузер.")

    html = fetch_dtek_html(chrome_path, timeout_seconds=args.timeout)
    if not html:
        print("[-] Завантаження скасовано або завершилося помилкою.")
        sys.exit(1)

    success = send_html_to_worker(
        html=html,
        worker_url=args.worker_url,
        admin_key=admin_key,
        dry_run=args.dry_run,
    )
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
