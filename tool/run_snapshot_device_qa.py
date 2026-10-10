"""Exercise isolated FCM -> production Dart -> SQLite -> Android widget effects.

Requires the QA APK built with the random topic in --topic-file, and adb device
authorization. No credentials or device registration tokens are printed.
"""
import argparse
import atexit
from datetime import datetime, timedelta
import json
import math
from pathlib import Path
import subprocess
import time
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "ua.maksim0.lumenqa.lumen_snapshot_qa"
GROUPS = [f"GPV{i}.{j}" for i in range(1, 7) for j in (1, 2)]
STATUSES = ["yes", "no", "first", "second", "maybe"]


def positive_seconds(value):
    try:
        seconds = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("Timeout must be a positive finite number") from None
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("Timeout must be a positive finite number")
    return seconds


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--topic-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--api-recovery-only", action="store_true")
    parser.add_argument("--cold-background-only", action="store_true")
    parser.add_argument("--reminder-failure-only", action="store_true")
    parser.add_argument("--delivery-timeout", type=positive_seconds, default=120,
                        help="Seconds to wait for actual Android FCM receipt (default: 120)")
    parser.add_argument("--local-timeout", type=positive_seconds, default=60,
                        help="Seconds to wait for startup, API recovery or local retry (default: 60)")
    args = parser.parse_args()
    config = json.loads((ROOT / "lumen_admin.json").read_text(encoding="utf-8-sig"))
    topic = args.topic_file.read_text(encoding="utf-8-sig").strip()

    def adb(*command, check=True):
        result = subprocess.run([args.adb, "-s", args.serial, *command],
                                capture_output=True, text=True, encoding="utf-8")
        if check and result.returncode:
            raise RuntimeError(f"ADB {command[0]} failed: {result.stderr[:300]}")
        return result.stdout

    def events():
        names = adb("shell", "run-as", PACKAGE, "ls", "app_flutter").splitlines()
        result = []
        for name in names:
            if name.startswith("snapshot_qa_") and name != "snapshot_qa_ready.json":
                raw = adb("shell", "run-as", PACKAGE, "cat", "app_flutter/" + name)
                value = json.loads(raw)
                if "receivedAt" in value:
                    result.append(value)
        return result

    # A persisted READY file can belong to an earlier process. Require a fresh
    # Dart callback before sending: topic subscription may finish after launch.
    seen = {value["receivedAt"] for value in events()}
    ready_deadline = time.monotonic() + args.local_timeout
    confirmed = False
    while time.monotonic() < ready_deadline:
        adb("shell", "am", "start", "-n", PACKAGE + "/ua.maksim0.lumen.SnapshotQaActivity",
            "--es", "qa_command", "retry_local")
        time.sleep(1)
        if any(value["mode"] == "local_retry" and value["receivedAt"] not in seen
               for value in events()):
            confirmed = True
            break
    assert confirmed, "QA Dart handler has not finished startup; no FCM test was sent"
    ready = json.loads(adb("shell", "run-as", PACKAGE, "cat",
                          "app_flutter/snapshot_qa_ready.json"))
    assert ready["topic"] == topic, "APK subscribed to a different QA run"
    if args.api_recovery_only:
        before = len(events())
        adb("shell", "am", "start", "-n", PACKAGE + "/ua.maksim0.lumen.SnapshotQaActivity",
            "--es", "qa_command", "recover_api")
        deadline = time.monotonic() + args.local_timeout
        received = None
        while time.monotonic() < deadline:
            values = events()
            if len(values) > before:
                received = sorted(values, key=lambda v: v["receivedAt"])[-1]
                break
            time.sleep(1)
        assert received and received["mode"] == "api_recovery", "No successful real API callback"
        request = Request(config["worker_url"].rstrip("/") + "/api/v1/snapshot",
                          headers={"User-Agent": "Mozilla/5.0"})
        with urlopen(request, timeout=12) as response:
            source = json.load(response)["snapshot"]
        assert len(received["current"]) == 12
        for group, pair in source["groups"].items():
            assert received["current"][group] == [pair[0], pair[1] or "9" * 24]
        widget = json.loads(received["widget"])
        assert widget["sourceVersion"] == source["sourceVersion"]
        args.output.write_text(json.dumps(received, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"PASS real Worker API -> Android: 12 groups, source {source['sourceUpdatedAt']}, "
              f"{received['historyRows']} archive rows, {received['scheduledReminders']} reminders")
        return
    now = datetime.now(ZoneInfo("Europe/Kyiv"))
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    tomorrow = midnight + timedelta(days=1)
    a = "0" * 12 + "1" * 4 + "0" * 8
    b = "0" * 13 + "1" * 4 + "0" * 7
    different = "012340123401234012340123"
    scenarios = [
        ("baseline_A_foreground", 1, 1, a, True, 0, 24),
        ("time_shift_B_background", 2, 2, b, True, 16, 48),
        ("duplicate_B", 2, 2, b, True, 16, 48),
        ("stale_A", 1, 1, a, True, 0, 48),
        ("newer_A_after_B", 3, 3, a, True, 16, 72),
        ("withdraw_tomorrow", 4, 4, a, False, 0, 96),
        ("republish_tomorrow", 5, 5, a, True, 32, 120),
        ("same_version_conflict", 6, 5, b, True, 16, 120),
    ]
    cold = None
    if args.cold_background_only or args.reminder_failure_only:
        cold = sorted(events(), key=lambda v: v["receivedAt"])[-1]
        a = cold["current"]["GPV2.1"][0]
        scenarios = [("reminder_failure" if args.reminder_failure_only else "cold_background_metadata",
                      8 if args.reminder_failure_only else 7,
                      21 if args.reminder_failure_only else 19, a,
                      cold["current"]["GPV2.1"][1] != "9" * 24,
                      0, cold["historyRows"] + 24)]
        adb("shell", "input", "keyevent", "3")
        if args.cold_background_only:
            adb("shell", "am", "kill", PACKAGE)
            pid = adb("shell", "pidof", PACKAGE, check=False).strip()
            if pid:
                assert pid.isdecimal(), "Unexpected QA process identifier"
                # am kill may finish between pidof and the fallback signal.
                adb("shell", "run-as", PACKAGE, "kill", "-9", pid, check=False)
            for _ in range(10):
                if not adb("shell", "pidof", PACKAGE, check=False).strip():
                    break
                time.sleep(0.2)
            assert not adb("shell", "pidof", PACKAGE, check=False).strip(), "QA process still running"
            print("QA process terminated without force-stopping the package", flush=True)
        if args.reminder_failure_only:
            adb("shell", "appops", "set", PACKAGE, "SCHEDULE_EXACT_ALARM", "deny")
            atexit.register(lambda: adb("shell", "appops", "set", PACKAGE,
                                       "SCHEDULE_EXACT_ALARM", "allow", check=False))
    report = []
    for name, sequence, version, code, published, alerts, rows in scenarios:
        if name == "time_shift_B_background":
            adb("shell", "input", "keyevent", "3")
            adb("shell", "input", "keyevent", "223")
        source = now.replace(second=0, microsecond=0) - timedelta(minutes=20-version)
        group_codes = {group: code for group in GROUPS}
        group_codes["GPV6.2"] = different[::-1] if code == b else different
        if cold:
            group_codes = {group: pair[0] for group, pair in cold["current"].items()}
        day = {group: {str(hour+1): STATUSES[int(c)] for hour, c in enumerate(encoded)}
               for group, encoded in group_codes.items()}
        fact = {"today": int(midnight.timestamp()),
                "update": source.strftime("%d.%m.%Y %H:%M"),
                "data": {str(int(midnight.timestamp())): day}}
        if published:
            fact["data"][str(int(tomorrow.timestamp()))] = {
                group: {str(hour+1): STATUSES[int(cold["current"][group][1][hour])] if cold else "yes"
                        for hour in range(24)} for group in GROUPS}
        html = "<script>DisconSchedule.fact=" + json.dumps(fact) + ";</script>"
        url = config["worker_url"].rstrip("/") + "/test-snapshot?" + urlencode({
            "topic": topic, "sequence": sequence, "alerts": alerts})
        before = len(events())
        request = Request(url, data=html.encode(), method="POST", headers={
            "User-Agent": "Mozilla/5.0", "Content-Type": "text/html",
            "X-Admin-Key": config["admin_key"]})
        try:
            with urlopen(request, timeout=25) as response:
                outcome = json.load(response)
        except HTTPError as error:
            raise RuntimeError(f"QA Worker HTTP {error.code}") from None
        assert outcome["outcome"]["success"] is True, "FCM rejected test"
        delivery_started = time.monotonic()
        deadline = delivery_started + args.delivery_timeout
        slow_delivery_reported = False
        received = None
        while time.monotonic() < deadline:
            values = events()
            if len(values) > before:
                matching = [value for value in values if
                    value.get("sequence") == sequence and
                    value.get("sourceVersion") == int(source.timestamp() * 1000)]
                if matching:
                    received = sorted(matching, key=lambda v: v["receivedAt"])[-1]
                    break
            if not slow_delivery_reported and time.monotonic() - delivery_started >= 45:
                print(f"Still waiting for Android receipt of {name}; FCM accepted the message, "
                      "but device delivery has not been confirmed", flush=True)
                slow_delivery_reported = True
            time.sleep(1)
        assert received is not None, (f"No actual Android callback for {name} within "
                                      f"{args.delivery_timeout:g}s after FCM acceptance")
        assert received["historyRows"] == rows, (name, received["historyRows"], rows)
        assert len(received["current"]) == 12, "Missing subgroup"
        expected_code = b if name == "stale_A" else a if name == "same_version_conflict" else code
        assert received["current"]["GPV2.1"][0] == expected_code, name
        widget = json.loads(received["widget"])
        assert len(widget["groups"]) == 12, "Incomplete widget payload"
        assert widget["groups"]["GPV2.1"][0] == expected_code, "Stale widget"
        if name == "withdraw_tomorrow":
            assert all(pair[1] == "9" * 24 for pair in received["current"].values())
        work = received["localWork"][0]
        if args.reminder_failure_only:
            assert work["processed"] < work["revision"], "Native failure consumed retry state"
            assert received["scheduledReminders"] == 0, "Exact alarm permission was not denied"
        else:
            assert work["processed"] == work["revision"], "Unfinished local effects"
        assert "error" not in received, received.get("error")
        report.append({"scenario": name, "fcmAccepted": True,
                       "deliveryWaitSeconds": round(time.monotonic() - delivery_started, 3),
                       "evidence": received})
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"PASS {name}: Android {received['mode']}, {rows} history rows, 12 widget groups, "
              f"{received['scheduledReminders']} reminders", flush=True)
    if cold:
        if args.cold_background_only:
            assert report[0]["evidence"]["mode"] == "background", "Cold push did not start a background engine"
        assert report[0]["evidence"]["current"] == cold["current"], "Metadata push altered source content"
        if args.reminder_failure_only:
            adb("shell", "appops", "set", PACKAGE, "SCHEDULE_EXACT_ALARM", "allow")
            before = len(events())
            adb("shell", "am", "start", "-n", PACKAGE + "/ua.maksim0.lumen.SnapshotQaActivity",
                "--es", "qa_command", "retry_local")
            deadline = time.monotonic() + args.local_timeout
            next_probe = time.monotonic() + 2
            recovered = None
            while time.monotonic() < deadline:
                values = events()
                if len(values) > before:
                    candidate = sorted(values, key=lambda v: v["receivedAt"])[-1]
                    row = candidate["localWork"][0]
                    if row["processed"] == row["revision"]:
                        recovered = candidate
                        break
                if time.monotonic() >= next_probe:
                    adb("shell", "am", "start", "-n", PACKAGE + "/ua.maksim0.lumen.SnapshotQaActivity",
                        "--es", "qa_command", "retry_local")
                    next_probe = time.monotonic() + 2
                time.sleep(1)
            assert recovered, "Local retry did not complete after restoring exact alarms"
            assert recovered["scheduledReminders"] > 0, "Native reminders were not restored"
            assert recovered["historyRows"] == received["historyRows"], "Local retry changed source history"
            report.append({"scenario": "reminder_local_retry", "evidence": recovered})
            args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
            print(f"PASS local retry after restoring exact alarms: {recovered['scheduledReminders']} reminders, "
                  "unchanged history and no network recovery", flush=True)
        return
    renders = json.loads(adb("shell", "run-as", PACKAGE, "cat",
                             "files/snapshot_qa_widget_renders.json"))
    assert len(renders) == 2, "Actual widget providers did not update their Android host"
    for provider, code in (("ua.maksim0.lumen.LightScheduleWidgetProvider3", a),
                           ("ua.maksim0.lumen.LightScheduleWidgetProvider12", different)):
        assert renders[provider]["renderedCode"] == code, "Wrong actual RemoteViews cell colors"
        assert renders[provider]["updateLabel"] == source.strftime("%H:%M"), "Wrong actual update label"
    print("PASS actual Android widget hosts: GPV2.1 and GPV6.2", flush=True)
    adb("shell", "input", "keyevent", "224")
    args.output.with_suffix(".widgets.json").write_text(json.dumps(renders, indent=2))


if __name__ == "__main__":
    main()
