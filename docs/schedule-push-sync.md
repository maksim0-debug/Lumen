# Full schedule synchronization through FCM

The Worker publishes one immutable source snapshot covering all twelve DTEK
subgroups. Android saves it directly; receiving a valid snapshot does not fetch
DTEK or the Worker API. Notification preferences select alerts, not stored data.

## Publication contract

`snapshot` is a JSON string inside the FCM data envelope. Schema `v: 1` contains:

- `journalId`, `sequence`: server journal identity and strictly increasing cursor;
- `todayDate`, `tomorrowDate`: explicit consecutive Kyiv calendar dates;
- `sourceVersion`: UTC epoch milliseconds parsed from DTEK's publication time;
- `sourceUpdatedAt`: the original DTEK publication text, used in UI/history;
- `groups`: all `GPV1.1` through `GPV6.2`, each `[todayCode, tomorrowCode]`;
- `alerts`: subgroup/day bit mask. Bit `groupIndex * 2` is today; the next is tomorrow.

Codes have 24 characters: `0` on, `1` off, `2` first-half outage, `3` second-half
outage, `4` possible outage. A `null` tomorrow means unpublished for every group.
Partial graphs, invalid dates/codes and conflicting source timestamps are rejected.

The source timestamp and complete content govern acceptance. Journal sequence is
used for history pagination; it cannot authorize rolling back a newer source.
Identical publications are idempotent. Newer A -> B -> A publications are distinct.
Same-time/different-content publications cannot replace accepted data. Withdrawal
is stored as unknown tomorrow and cannot be undone by a delayed older push.

## Delivery and recovery

Every updated client subscribes to `lumen_schedules_v1`, even with alerts disabled.
Its data-only messages use Android NORMAL priority and collapse to the latest
snapshot. Selected group v2 topics retain HIGH priority and non-collapsed delivery,
and carry the same full snapshot. Existing legacy group notifications remain
compatible. The client deduplicates either arrival order using SQLite state.

FCM topic data is checked against a conservative 2048-byte UTF-8 JSON budget.
Oversized optional snapshots become journal references and use API recovery.
Group events can still display without waiting for a network parser.

The Durable Object commits source state, immutable journal entry and delivery
outbox in one storage transaction. Transient delivery failures retain retry state.
API reads use consistent storage transactions without waiting for FCM delivery.
The journal retains the latest 2048 accepted publications, including changes to
unselected groups, metadata-only publications and withdrawals.

Public, read-only endpoints contain schedules and no admin credentials:

- `GET /api/v1/snapshot`: `{snapshot, lastCheckedAt}`; 503 before the first publication.
- `GET /api/v1/publications?after=0&limit=32&journalId=...`: publications and
  `gap`, `reset`, `oldestSequence`, `latestSequence`, `nextAfter`, `hasMore`.
  Server page limits are 1..64. Retention gaps are reported explicitly.

Android periodic/manual recovery first uses the Worker API. A source check older
than 15 minutes, stale calendar anchor or network failure permits the existing
DTEK parser fallback. Backfill imports at most four 32-publication pages per run,
with bounded HTTP requests. Each archive page and cursor commit is atomic and
compares the previous cursor to protect concurrent recoveries. Archive rows never
advance current pointers or send historical change notifications.

## Android effects

The source snapshot, notification observations and pending local revision are
committed in one SQLite transaction. Local effects use a bounded writer lease;
an exception leaves the revision pending for a local Workmanager retry without
a network constraint. A newer revision cannot be consumed by an older worker.
Widget refresh, notification delivery and reminder scheduling are independent;
a failed operation does not prevent the others from being attempted.
Background reminder scheduling propagates native initialization/cancellation/
scheduling failures after attempting independent reminders. Such failures do
not consume the pending revision; foreground SDK error handling stays compatible.

`packages/lumen_schedule_widgets` is a small Android Flutter plugin registered in
foreground and background engines. A shared executor commits the complete widget
blob and legacy keys together, off the main thread, then broadcasts updates to
installed providers. A source watermark prevents delayed older widget writers
from replacing newer data, including after a manual edit. Providers select graphs
by explicit calendar date and stop reusing yesterday's tomorrow after it expires.
Foreground FCM and Android resume reload the authoritative cache for the UI.

SQLite's existing version remains 5: additive internal tables are created lazily,
and older app versions can ignore them. Deploy the Worker before distributing the
new app. An older Worker/app remains usable through legacy events/parser fallback.
Rolling back Worker code leaves journal entries intact; preserve the monitor state
and its journal together if restoring server storage.

## Verification

```powershell
flutter test
flutter analyze --no-pub
flutter build apk --debug
cd cloudflare-worker
npm run typecheck
npm test
```

For real device QA, `python tool/prepare_snapshot_device_qa.py` creates an ignored
separate project and APK, preserving the main app's dependency lock versions. The
QA package is `ua.maksim0.lumenqa.lumen_snapshot_qa`; it subscribes only to a fresh
random QA topic, not production topics. Install through adb and approve the phone's
USB installation prompt. Grant notification permission on Android 13+ only.
The builder saves the matching topic in
`artifacts/snapshot-device-qa/snapshot-qa-topic.txt`. This generated project,
topic file and device reports remain ignored by Git.

```powershell
adb -s <serial> install -r artifacts/snapshot-device-qa/build/app/outputs/flutter-apk/app-debug.apk
adb -s <serial> shell appwidget grantbind --package ua.maksim0.lumenqa.lumen_snapshot_qa --user 0
adb -s <serial> shell am start -n ua.maksim0.lumenqa.lumen_snapshot_qa/ua.maksim0.lumen.SnapshotQaActivity
python tool/run_snapshot_device_qa.py --adb <adb-path> --serial <serial> --topic-file artifacts/snapshot-device-qa/snapshot-qa-topic.txt --output artifacts/snapshot-device-qa/snapshot-device-evidence.json
```

The authenticated `POST /test-snapshot` accepts synthetic DTEK HTML and sends only
to `lumen_snapshot_qa_<32 lowercase hex characters>`. It never writes production
monitor state or fans out to production groups. QA uses HIGH priority to exercise
immediate background callbacks; this is not evidence of NORMAL delivery in Doze.
The harness disables network recovery for deliberately stale/conflicting fixtures,
so production API graphs cannot contaminate its isolated database.

The runner verifies actual Android callbacks, all subgroup graphs, exact history
row counts, completed local revisions, widget payloads and reminder counts across
baseline, equal-duration time shift, duplicate, stale, A -> B -> A, withdrawal,
republication and equal-source-version conflict. Its Android widget host binds the
actual selected/unselected providers; it is separate from the user's launcher.
Check notification records and rendered widget evidence, not just FCM acceptance.
The runner waits up to 120 seconds for an actual FCM callback and 60 seconds for
startup, API recovery and local retries. Use `--delivery-timeout` and
`--local-timeout` to override these positive finite limits. It reports unconfirmed
delivery after 45 seconds and records observed `deliveryWaitSeconds` after FCM
acceptance without resending the message. A longer observation window does not
change application network budgets or guarantee delivery within that window.
After clearing only the QA package's data and relaunching, the runner's
`--api-recovery-only` flag verifies recovery from real production graphs and journal.
`--cold-background-only` verifies FCM starts a new background engine after process
termination without force-stopping the package. On Android 12+, the optional
`--reminder-failure-only` probe temporarily denies exact alarms for the QA package,
checks durable pending work and already-updated widgets, restores permission, and
retries locally. Do not use the production package for these probes.
Uninstalling the QA package removes its isolated data and widget bindings.

FCM and Android do not guarantee immediate delivery on every device. A disconnected,
force-stopped or restricted app may receive data later. NORMAL messages can wait
in Doze; periodic recovery fills missed history only within server retention.
Publications that no parser ever observed cannot be reconstructed by this system.
