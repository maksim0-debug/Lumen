# Lumen Schedule Monitor

Worker перевіряє графіки ДТЕК кожні п'ять хвилин. `/check-html` також приймає повний графік із desktop або Python bridge, коли прямий HTTP-запит отримує антибот-перевірку. Усі джерела мають однакову валідацію: повний сьогоднішній графік для 12 груп, коректна київська дата, 24 відомі статуси на групу та час оновлення ДТЕК. Порожній завтрашній графік означає «не опубліковано»; частково опубліковані дані відхиляються.

## Стан і доставка

Один Durable Object `ScheduleMonitor` послідовно обробляє всі оновлення. Стан і черга сповіщень записуються транзакційно до зовнішніх запитів. KV використовується лише для одноразового імпорту попереднього стану; нових записів у KV немає. Нижча версія ДТЕК відхиляється незалежно від джерела. Однаковий час із різними графіками означає конфлікт і відхиляється цілком. Новіша реальна зміна A→B→A приймається.

Перше завантаження створює базовий стан без масових сповіщень. Перша наступна публікація на завтра надсилає сповіщення. Помилка FCM залишає повідомлення у сховищі; alarm повторює доставку з паузою від 30 секунд до 15 хвилин. Прострочені повідомлення видаляються, якщо їхня цільова дата більше не відповідає сьогодні/завтра. Коли новіша версія замінює недоставлену, повідомлення містить поточну загальну тривалість відключень замість потенційно хибної різниці.

Це доставка з повторними спробами, а не гарантія exactly-once: якщо FCM прийняв повідомлення, але відповідь загубилась, можливий повтор. `eventId` дозволяє клієнту відсіяти foreground-дублі; Android `tag` замінює ту саму системну картку. TTL сповіщення — 15 хвилин. Прийняття FCM не гарантує показ на кожному телефоні.

## Налаштування та оновлення

1. Виконайте `npm ci` у цій папці та налаштуйте Cloudflare CLI.
2. Для існуючого встановлення збережіть поточний `SCHEDULE_KV` binding. Для нового створіть KV namespace і задайте його ID у `wrangler.toml`.
3. Задайте секрети через `npx wrangler secret put ADMIN_KEY` і `npx wrangler secret put FIREBASE_SERVICE_ACCOUNT`. Другий секрет — JSON Firebase service account із project_id, client_email і private_key. Не комітьте секрети.
4. Нове розгортання **обов'язково** має містити Durable Object binding `SCHEDULE_MONITOR` і міграцію `schedule-monitor-v1` із `new_sqlite_classes = ["ScheduleMonitor"]`, уже внесені у `wrangler.toml`. Не змінюйте застосовані migration tags. Не деплойте лише файл index.ts поверх старої конфігурації.
5. Перед розгортанням виконайте `npm test`, `npm run typecheck` та `npx wrangler deploy --dry-run`. Потім окремо виконайте `npm run deploy`.

Після першого реального запиту перевірте звіт і логи. Без Durable Object binding endpoint повертає помилку. Після переходу KV більше не оновлюється: простий rollback на старий KV-worker використовуватиме застарілий стан і може повторити сповіщення. Для rollback потрібне окреме відновлення актуального базового стану; не видаляйте Durable Object storage навмання.

## HTTP API

Передавайте ключ через `X-Admin-Key` або `Authorization: Bearer ...`. Старий query-параметр key лишено для сумісності; він може потрапляти в історію браузера й логи, тому нові клієнти його не використовують.

- `GET /` — публічний опис сервісу.
- `GET|POST /check` — отримати й обробити сторінку ДТЕК.
- `POST /check-html?source=desktop_bridge` — обробити HTML/канонічний JSON-script; максимум 2 MiB UTF-8, включно з chunked upload. Загальний строк читання тіла — 30 секунд.
- `POST /check-html?dryRun=true` — валідація та план змін без запису стану, alarm чи FCM.
- `GET|POST /test-push?group=GPV2.1&dayType=today` — тестова доставка; невідомі групи й типи дня відхиляються.

Звіт містить status, checkedGroups, changesDetected, notificationsPlanned, notificationsSent та errors. `success`, `dry_run_success` і `emergency_only` без errors повертають HTTP 200; застарілий snapshot або конфлікт — 409; невдала доставка чи storage — 503; некоректний графік — 422; перевищення розміру — 413; тайм-аут завантаження — 408. Клієнт має перевіряти і HTTP, і JSON-звіт.

## Desktop і Python bridge

Скопіюйте `lumen_admin.example.json` у локальний `lumen_admin.json` і внесіть ключ. Desktop спочатку пробує файл біля executable, потім у working directory. Пошкоджений файл не блокує другий варіант. Для віддаленого Worker дозволено лише HTTPS; HTTP дозволено для localhost-тестів. Редиректи з admin key не виконуються.

Для інтерактивного Python bridge: `pip install -r tools/requirements.txt`, `playwright install chromium`, задайте `LUMEN_ADMIN_KEY` і виконайте `python tools/push_dtek_schedule.py --dry-run` із кореня проєкту. У разі капчі пройдіть її у відкритому браузері. Bridge читає runtime `DisconSchedule.fact`, а не лише шукає текст змінної у HTML. Локальні тести: `python -m unittest discover -s tools -p test_push_dtek_schedule.py`.


## Правила актуальності snapshot

Версія перевіряється для повного snapshot до змін будь-якої групи. Відсутність графіка на завтра також є версіонованим станом: вона скасовує його недоставлені сповіщення. При переході через опівніч сьогодні порівнюється з уже відомою публікацією цієї дати на завтра. Рівна версія з іншим вмістом відхиляється атомарно.

Dart, Worker and Python accept the exact next Kyiv midnight or the explicit DST fallback `today + 86400`. Multiple keys for the same tomorrow date are rejected. For the repeated autumn hour, all three validators consistently choose the later instant. Since DTEK supplies no UTC offset, changes within that repeated hour cannot be unambiguously ordered by the source timestamp alone.

Застосунок зберігає watermark ДТЕК окремо від ручної та імпортованої історії. Для знятої публікації в історії зберігається порожня остання версія; попередні публікації залишаються в архіві. Дати, countdown і віджети використовують київський часовий пояс незалежно від налаштувань пристрою.

## Emergency status protocol

Emergency observations are independent of schedule versions and history writes. Only an operational notice in `#modal-attention`, `.m-attention` or `.modal-attention` is interpreted. FAQ text, executable scripts, templates, ambiguous notices, incomplete pages and bot challenges are not cancellation evidence. A complete recognizable schedule page without a notice is an inactive observation. A cancellation requires two newer observations at least 30 seconds apart and no more than 20 minutes apart; a fresh active notice clears the candidate immediately.

Bridges export validated runtime schedule JSON plus optional metadata, never the original HTML page:

```html
<script id="lumen-emergency" type="application/json">{"schemaVersion":1,"active":true,"observedAt":1791450000000}</script>
```

`observedAt` is the capture time in Unix milliseconds, not the schedule update time. Observations older than 15 minutes or more than one minute in the future are rejected. HTTP fetchers also consider `Date`/`Age` headers. Legacy script-only uploads leave emergency state unchanged. A valid status can be accepted when the schedule is missing, stale or invalid: `emergency_only`, `emergencyProcessed: true`, `scheduleStatus` and `warnings` identify this partial result. An initial active notice sends one alert; an initial inactive baseline stays quiet.

Emergency FCM messages use `type=emergency_alert`, `isEmergency`, `observedAt`, `expiresAt` and `eventId`. They are data-only so the client can validate ordering, expiry and the local notification preference before showing them. Android uses high priority, a shared collapse key and a separate local notification ID. Expiry remains 15 minutes from the original observation across retries, including midnight. Permanent FCM errors stop retries; transient errors use the durable outbox. SQLite on the client stores status and notification claims across isolates; a short delivery lease avoids holding database transactions across OS calls. The banner labels active data older than 30 minutes as requiring an update. Schedule forecasts and reminders remain enabled during emergencies.

DTEK does not provide an independent signed version for its notice. Capture ordering and cancellation confirmation reduce stale-source risk but cannot prove that arbitrary upstream HTML reflects the latest real-world status. FCM acceptance also does not prove device delivery; validate foreground/background delivery on a real Android device after deploying the matching client and Worker.

Parser regression cases are small synthetic strings in `test/fixtures/emergency_status_cases.json`, shared by Dart, Worker and Python. The local `.agents/shutdowns2.txt` capture is ignored by Git and is not a test dependency.
