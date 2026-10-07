# Lumen Local REST & SSE API Reference

> **High-Performance Embedded REST & Real-Time Server-Sent Events (SSE) API**  
> Built for zero-overhead local integration with Home Assistant, smart home automations, desktop widgets, AI agents, and CLI tools.

---

## 1. Architectural Overview & System Boundaries

Lumen runs a native, zero-dependency HTTP server directly within the desktop Flutter application (`dart:io` `HttpServer`). It provides instant local access to electricity presence monitoring, DTEK outage schedules, countdown timers, outage history, and analytics.

| Parameter | Specification | Notes |
| :--- | :--- | :--- |
| **Default Host** | `127.0.0.1` | Strictly binds to IPv4 loopback (`InternetAddress.loopbackIPv4`) |
| **Default Port** | `18080` | Configurable in Settings (`1024` – `65535`) |
| **Base URL** | `http://127.0.0.1:18080/api/v1` | Automatic trailing slash normalization (`/status/` → `/status`) |
| **Interactive Docs** | `http://127.0.0.1:18080/docs` or `/api/v1/docs` | Embedded Swagger UI with offline blackout fallback |
| **OpenAPI Spec** | `http://127.0.0.1:18080/openapi.json` | OpenAPI 3.0.3 machine-readable JSON |
| **Supported Platforms** | Windows, Linux, macOS | Desktop only; disabled on mobile/web |
| **CPU Footprint** | ~0% idle | Event-driven non-blocking I/O |

---

## 2. Security, CORS & Network Rules

### 2.1 DNS Rebinding Attack Protection
The server enforces strict `Host` header inspection. Any request whose `Host` header does not match one of the following allowed hostnames will be rejected immediately with HTTP `400 Bad Request` (`INVALID_HOST`):
- `localhost` (including any port, e.g. `localhost:18080`)
- `127.0.0.1` (including any port, e.g. `127.0.0.1:18080`)
- `::1` or `[::1]` (IPv6 loopback)

### 2.2 Cross-Origin Resource Sharing (CORS) & Private Network Access
Every response includes permissive CORS and Chrome Private Network Access headers:
```http
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, POST, OPTIONS
Access-Control-Allow-Headers: Origin, X-Requested-With, Content-Type, Accept, Authorization
Access-Control-Allow-Private-Network: true
```
All pre-flight `OPTIONS` requests receive an immediate `204 No Content` response with `Access-Control-Max-Age: 86400`.

### 2.3 Request Payload Limits
- Requests with a body (e.g. `POST /api/v1/power/events`) are capped at **64 KB** (`65,536 bytes`). Exceeding this triggers HTTP `400 Bad Request` (`BODY_TOO_LARGE`).
- `Content-Type` for request bodies must be `application/json; charset=utf-8`.

---

## 3. Standard Response Formats

All standard API endpoints return a unified JSON response envelope.

### 3.1 Success Envelope
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "...": "Payload specific to endpoint"
  },
  "meta": {
    "...": "Optional pagination or contextual metadata"
  }
}
```

### 3.2 Error Envelope
```json
{
  "success": false,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "error": {
    "code": "INVALID_GROUP",
    "message": "Невідома група \"GPV9.9\". Доступні групи: GPV1.1, GPV1.2, GPV2.1...",
    "details": {
      "field": "group"
    }
  }
}
```

### 3.3 Raw Responses
- `GET /api/v1/openapi.json` and `GET /openapi.json` return the un-enveloped raw OpenAPI 3.0.3 specification JSON.
- `GET /docs` and `GET /api/v1/docs` return rendered HTML.
- `GET /api/v1/stream` returns `text/event-stream`.

---

## 4. Domain Models & Enums

### 4.1 GPV Groups (DTEK Kyiv Outage Groups)
There are exactly 12 standard GPV groups:
`GPV1.1`, `GPV1.2`, `GPV2.1`, `GPV2.2`, `GPV3.1`, `GPV3.2`, `GPV4.1`, `GPV4.2`, `GPV5.1`, `GPV5.2`, `GPV6.1`, `GPV6.2`.
- If the `group` query parameter is omitted, the API defaults to the user's selected group from application preferences, or `GPV2.1` as a global default.
- If an invalid group key is explicitly supplied (e.g. `?group=invalid`), the server rejects the request with HTTP `400` (`INVALID_GROUP`).

### 4.2 Power States (`effectiveState`)
- `online`: Electricity is currently active (sensor heartbeat verified or manual online event active).
- `offline`: Electricity is cut off (sensor down or manual offline event active).
- `unknown`: State cannot be reliably determined (sensor disabled, not configured, or staleness expired without recent event).

### 4.3 Slot Status & Intervals
A day is divided into **48 half-hour slots** (00:00 to 24:00):
- `on` (`ON`): Electricity is guaranteed / scheduled to be on.
- `off` (`OFF`): Definite scheduled power outage.
- `maybe` (`MAYBE`): Gray zone / possible outage depending on grid balance.
- `unknown` (`?`): Unspecified or missing schedule data.

Interval objects group consecutive slots of identical status:
```json
{
  "start": "14:00",
  "end": "18:00",
  "status": "off",
  "status_label": "OFF",
  "duration_minutes": 240,
  "duration_formatted": "4 год",
  "time_range": "14:00 - 18:00"
}
```

### 4.4 Data Source Modes
- `real`: Calculations based strictly on actual physical sensor events recorded in the database.
- `predicted`: Calculations based on theoretical DTEK scheduled outage intervals.

---

## 5. Endpoints Reference

### 5.1 System & Dashboard

#### `GET /api/v1/status`
Combined dashboard snapshot. Preloads and returns the current power state, today's schedule, and the countdown timer in a single unified call.

- **Query Parameters**:
  - `group` *(optional, string)*: GPV group key (e.g. `GPV2.1`). Defaults to user's saved group.
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "group": "GPV2.1",
    "power": {
      "state": "online",
      "state_label": "Світло є",
      "is_online": true,
      "is_offline": false,
      "is_unknown": false,
      "duration_minutes": 145,
      "last_event_time": "2026-10-04T00:45:00.000Z",
      "sensor": {
        "is_enabled": true,
        "reason": "active",
        "reason_message": "Сенсор активний",
        "is_stale": false,
        "last_seen": "2026-10-04T03:09:45.000Z",
        "ttl_minutes": 5,
        "consecutive_errors": 0
      }
    },
    "schedule_today": {
      "date": "2026-10-04",
      "group": "GPV2.1",
      "is_available": true,
      "status": "available",
      "total_outage_minutes": 480,
      "total_outage_hours": "8.0",
      "outage_percentage": 33,
      "last_updated_source": "04.10 02:15",
      "intervals": [ ... ],
      "slots": [ "on", "on", "off", ... ],
      "hours_code": "++--++..."
    },
    "countdown": {
      "group": "GPV2.1",
      "has_countdown": true,
      "current_status": "on",
      "target_status": "off",
      "minutes_remaining": 50,
      "target_time": "2026-10-04T04:00:00.000Z",
      "formatted_remaining": "50 хв",
      "message": "Відключення через 50 хв"
    }
  }
}
```

---

#### `GET /api/v1/health`
Healthcheck and runtime module diagnostic status.

- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "status": "healthy",
    "uptime_seconds": 3600,
    "started_at": "2026-10-04T02:10:00.000Z",
    "app_version": "1.1.0",
    "platform": "windows",
    "port": 18080,
    "host": "127.0.0.1"
  }
}
```

---

### 5.2 Power Monitoring Domain

#### `GET /api/v1/power/current`
Inspects real electricity presence, sensor staleness, and diagnostics.

- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "state": "online",
    "state_label": "Світло є",
    "is_online": true,
    "is_offline": false,
    "is_unknown": false,
    "duration_minutes": 180,
    "last_event_time": "2026-10-04T00:10:00.000Z",
    "last_transition_at": "2026-10-04T00:10:00.000Z",
    "sensor": {
      "is_enabled": true,
      "reason": "active",
      "reason_message": "Сенсор активний",
      "is_stale": false,
      "last_seen": "2026-10-04T03:09:00.000Z",
      "last_seen_at": "2026-10-04T03:09:00.000Z",
      "last_sync": "2026-10-04T03:09:10.000Z",
      "last_sync_at": "2026-10-04T03:09:10.000Z",
      "ttl_minutes": 5,
      "consecutive_errors": 0,
      "error_message": null
    }
  }
}
```

---

#### `GET /api/v1/power/events`
Query power event logs stored in SQLite with date filtering, limit, and sorting.

- **Query Parameters**:
  - `date` *(optional, string)*: Specific day in `YYYY-MM-DD` format (returns events from 00:00:00 to 23:59:59).
  - `from` *(optional, string)*: Start date in `YYYY-MM-DD` format.
  - `to` *(optional, string)*: End date in `YYYY-MM-DD` format.
  - `limit` *(optional, integer, default: 100)*: Limit results between `1` and `1000`.
  - `sort` *(optional, string, default: "desc")*: Sort order, either `"desc"` or `"asc"`.
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "count": 2,
    "limit": 100,
    "sort": "desc",
    "filters": {
      "date": "2026-10-04",
      "from": null,
      "to": null
    },
    "events": [
      {
        "id": 102,
        "firebase_key": "-Olp1QPOaPl9gAmer2Cc",
        "status": "online",
        "timestamp": "2026-10-04T02:00:00.000Z",
        "device": "PingSensor_ESP32",
        "is_manual": false
      },
      {
        "id": 101,
        "firebase_key": "manual_1790904171783_992526",
        "status": "offline",
        "timestamp": "2026-10-04T00:15:00.000Z",
        "device": "HomeAssistant",
        "is_manual": true
      }
    ]
  }
}
```

---

#### `POST /api/v1/power/events`
Atomically records a manual power transition (`online` or `offline`) directly into the local SQLite database, immediately recalculates in-memory power status, and broadcasts the event to all active SSE subscribers.

- **Headers**: `Content-Type: application/json`
- **Request Body (Max 64KB)**:
```json
{
  "status": "online",
  "timestamp": "2026-10-04T03:10:00.000Z",
  "device": "HomeAssistant Script"
}
```
  - `status` *(required, string)*: Strictly `"online"` or `"offline"`.
  - `timestamp` *(optional, string)*: ISO-8601 or `YYYY-MM-DD HH:mm:ss`. Defaults to current local time.
  - `device` *(optional, string)*: Device/client label. Defaults to `"API Client"`.
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "created": true,
    "event_id": 103,
    "firebase_key": "manual_1790904600000_123456",
    "status": "online",
    "timestamp": "2026-10-04T03:10:00.000Z",
    "device": "HomeAssistant Script",
    "is_manual": true
  }
}
```

---

#### `GET /api/v1/power/intervals`
Returns calculated historical or ongoing outage intervals for a given date.

- **Query Parameters**:
  - `date` *(optional, string)*: Target date `YYYY-MM-DD`. Defaults to current date.
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "date": "2026-10-04",
    "total_outage_minutes": 240,
    "total_outage_hours": "4.0",
    "intervals_count": 1,
    "intervals": [
      {
        "start": "2026-10-04T00:00:00.000Z",
        "end": "2026-10-04T04:00:00.000Z",
        "duration_minutes": 240,
        "formatted_duration": "4 год",
        "is_ongoing": false
      }
    ]
  }
}
```

---

#### `POST /api/v1/power/refresh`
Triggers immediate non-blocking background polling of the configured remote sensor (e.g. Firebase RTDB).

- **Response (202 Accepted)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "triggered": true,
    "message": "Опитування сенсора запущено у фоновому режимі"
  }
}
```
*(If the sensor is disabled in preferences, returns `200 OK` with `triggered: false`).*

---

### 5.3 Outage Schedule Domain (DTEK)

#### `GET /api/v1/schedule/today`
Returns today's 48-slot outage schedule and calculated intervals for the specified GPV group.

- **Query Parameters**:
  - `group` *(optional, string)*: GPV group key (e.g. `GPV2.1`).
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "date": "2026-10-04",
    "group": "GPV2.1",
    "is_available": true,
    "status": "available",
    "total_outage_minutes": 480,
    "total_outage_hours": "8.0",
    "outage_percentage": 33,
    "last_updated_source": "04.10 02:15",
    "intervals": [
      {
        "start": "00:00",
        "end": "04:00",
        "status": "off",
        "status_label": "OFF",
        "duration_minutes": 240,
        "duration_formatted": "4 год",
        "time_range": "00:00 - 04:00"
      },
      {
        "start": "04:00",
        "end": "12:00",
        "status": "on",
        "status_label": "ON",
        "duration_minutes": 480,
        "duration_formatted": "8 год",
        "time_range": "04:00 - 12:00"
      }
    ],
    "slots": ["off", "off", "on", ...],
    "hours_code": "--++..."
  }
}
```

---

#### `GET /api/v1/schedule/tomorrow`
Returns tomorrow's schedule if published by DTEK.

- **Query Parameters**:
  - `group` *(optional, string)*: GPV group key.
- **Response when published (200 OK)**:
  Returns identical schema to `GET /schedule/today` with `"status": "published"`.
- **Response when not yet published (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "date": "2026-10-05",
    "group": "GPV2.1",
    "is_available": false,
    "status": "not_published",
    "message": "Графік на завтра ще не оприлюднено на сайті ДТЕК",
    "last_checked_source": "04.10 03:00",
    "schedule": null
  }
}
```

---

#### `GET /api/v1/schedule/group/{id}`
Returns both today's and tomorrow's schedules bundled for a specific GPV group.

- **Path Parameters**:
  - `id` *(required, string)*: Group identifier (`GPV1.1` to `GPV6.2`, case-insensitive).
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "group": "GPV2.1",
    "last_updated_source": "04.10 02:15",
    "today": {
      "date": "2026-10-04",
      "is_available": true,
      "total_outage_minutes": 480,
      "total_outage_hours": "8.0",
      "intervals": [ ... ],
      "slots": [ ... ],
      "hours_code": "..."
    },
    "tomorrow": {
      "date": "2026-10-05",
      "is_available": false,
      "status": "not_published"
    }
  }
}
```

---

#### `GET /api/v1/schedule/countdown`
Calculates the remaining time until the next scheduled power outage or restoration.

- **Query Parameters**:
  - `group` *(optional, string)*: GPV group key.
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "group": "GPV2.1",
    "has_countdown": true,
    "current_status": "on",
    "target_status": "off",
    "minutes_remaining": 45,
    "target_time": "2026-10-04T04:00:00.000Z",
    "formatted_remaining": "45 хв",
    "message": "Відключення через 45 хв",
    "is_tomorrow_schedule_missing": false
  }
}
```

---

#### `GET /api/v1/schedule/groups`
Returns an overview of all 12 GPV groups with their current slot status and total outage duration for today and tomorrow.

- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "total_groups": 12,
    "groups": {
      "GPV1.1": {
        "has_today": true,
        "has_tomorrow": false,
        "today_outage_minutes": 420,
        "tomorrow_outage_minutes": 0,
        "current_status": "on",
        "source_updated": "04.10 02:15"
      },
      "GPV2.1": {
        "has_today": true,
        "has_tomorrow": false,
        "today_outage_minutes": 480,
        "tomorrow_outage_minutes": 0,
        "current_status": "on",
        "source_updated": "04.10 02:15"
      }
    }
  }
}
```

---

#### `POST /api/v1/schedule/sync`
Triggers an immediate re-fetch of the outage schedule from DTEK's website.

- **Query Parameters**:
  - `force` *(optional, boolean, default: false)*: When `true`, ignores the 30-second cooldown period.
- **Response when synced (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "status": "success",
    "message": "Графіки успішно оновлено з сайту ДТЕК",
    "groups_updated": 12
  }
}
```
- **Response when cooldown is active (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "status": "cooldown_active",
    "message": "Дані нещодавно оновлені. Кулдаун 30 секунд активний.",
    "cooldown_seconds": 30
  }
}
```

---

### 5.4 Outage History & Export Domain

#### `GET /api/v1/history/versions`
Fetches revision history for a given day and group (tracks how DTEK modified the schedule during the day).

- **Query Parameters**:
  - `date` *(optional, string)*: Day `YYYY-MM-DD`. Defaults to today.
  - `group` *(optional, string)*: GPV group key.
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "date": "2026-10-04",
    "group": "GPV2.1",
    "versions_count": 2,
    "versions": [
      {
        "version_number": 1,
        "saved_at": "2026-10-04T00:15:00.000Z",
        "time_string": "00:15",
        "outage_minutes": 360,
        "outage_formatted": "6 год",
        "schedule_code": "a1b2c3d4",
        "slots": [ ... ],
        "intervals": [ ... ]
      }
    ]
  }
}
```

---

#### `GET /api/v1/history/dates`
Returns a list of all distinct dates recorded in the local SQLite database.

- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "count": 35,
    "dates": [
      "2026-10-04",
      "2026-10-03",
      "2026-10-02"
    ]
  }
}
```

---

#### `GET /api/v1/history/export`
Exports database schedules and power events in the standard JSON backup schema.

- **Query Parameters**:
  - `from` *(optional, string)*: Start date `YYYY-MM-DD`.
  - `to` *(optional, string)*: End date `YYYY-MM-DD`.
  *(Note: `from` and `to` must either both be specified or both omitted).*
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "version": 1,
    "export_date": "2026-10-04T03:10:00.000Z",
    "filters": {
      "from": "2026-10-01",
      "to": "2026-10-04"
    },
    "schedules_count": 48,
    "events_count": 16,
    "schedules": [ ... ],
    "power_events": [ ... ]
  }
}
```

---

#### `GET /api/v1/history/logs`
Returns internal diagnostic and synchronization logs.

- **Query Parameters**:
  - `limit` *(optional, integer, default: 50)*: Range `1` to `500`.
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "count": 50,
    "limit": 50,
    "logs": [
      "[2026-10-04 03:09:12] [DTEK] Schedules updated successfully",
      "[2026-10-04 02:45:00] [SENSOR] State change detected: online"
    ]
  }
}
```

---

### 5.5 Analytics & Accuracy Domain

#### `GET /api/v1/analytics/stats`
Aggregated outage metrics over a rolling time window.

- **Query Parameters**:
  - `days` *(optional, integer, default: 7)*: Range `1` to `365`.
  - `mode` *(optional, string, default: "real")*: `"real"` or `"predicted"`.
  - `group` *(optional, string)*: GPV group key.
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "period_days": 7,
    "group": "GPV2.1",
    "mode": "real",
    "total_outage_minutes": 2520,
    "total_outage_hours": "42.0",
    "formatted_total": "1 дн 18 год",
    "outage_percentage": 25,
    "average_duration_minutes": 210,
    "formatted_average_duration": "3 год 30 хв",
    "outages_count": 12
  }
}
```

---

#### `GET /api/v1/analytics/accuracy`
Calculates DTEK schedule accuracy score compared against physical sensor measurements.

- **Query Parameters**:
  - `days` *(optional, integer, default: 7)*: Range `1` to `365`.
  - `group` *(optional, string)*: GPV group key.
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "period_days": 7,
    "group": "GPV2.1",
    "has_data": true,
    "accuracy_score": 0.92,
    "accuracy_percentage": 92,
    "description": "Відсоток збігу запланованих ДТЕК відключень із реальними даними сенсора"
  }
}
```

---

#### `GET /api/v1/analytics/switch-lag`
Measures average switching latency (whether grid operators turn power ON/OFF earlier or later than scheduled).

- **Query Parameters**:
  - `days` *(optional, integer, default: 7)*: Range `1` to `365`.
  - `group` *(optional, string)*: GPV group key.
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "period_days": 7,
    "group": "GPV2.1",
    "sample_count": 14,
    "has_data": true,
    "avg_on_lag_minutes": 8.5,
    "avg_off_lag_minutes": -4.2,
    "interpretation": {
      "on_lag": "Світло вмикають пізніше графіка в середньому на 8.5 хв",
      "off_lag": "Світло вимикають раніше графіка в середньому на 4.2 хв"
    }
  }
}
```

---

#### `GET /api/v1/analytics/records`
Calculates extreme outage and uptime duration records.

- **Query Parameters**:
  - `mode` *(optional, string, default: "real")*: `"real"` or `"predicted"`.
  - `group` *(optional, string)*: GPV group key.
- **Response (200 OK)**:
```json
{
  "success": true,
  "timestamp": "2026-10-04T03:10:00.000Z",
  "data": {
    "group": "GPV2.1",
    "mode": "real",
    "longest_outage": {
      "start": "2026-09-20T10:00:00.000Z",
      "end": "2026-09-20T22:30:00.000Z",
      "duration_minutes": 750,
      "formatted": "12 год 30 хв",
      "date": "20.09.2026"
    },
    "longest_uptime": {
      "start": "2026-09-25T00:00:00.000Z",
      "end": "2026-09-28T12:00:00.000Z",
      "duration_minutes": 5040,
      "formatted": "3 дн 12 год",
      "date": "25.09 - 28.09"
    },
    "shortest_uptime": {
      "start": "2026-09-22T14:00:00.000Z",
      "end": "2026-09-22T14:45:00.000Z",
      "duration_minutes": 45,
      "formatted": "45 хв",
      "date": "22.09.2026"
    }
  }
}
```

---

### 5.6 Real-Time Server-Sent Events (SSE)

#### `GET /api/v1/stream`
Establishes a persistent, real-time HTTP stream using the standard Server-Sent Events protocol (`text/event-stream`).

- **Headers**:
  ```http
  Accept: text/event-stream
  Cache-Control: no-cache
  ```
- **Connection Characteristics**:
  - Unbuffered streaming with immediate flush.
  - Background heartbeat `: ping\n\n` emitted every **25 seconds** to prevent intermediary proxy or NAT timeouts. Dead sockets are automatically pruned.
  - Broadcasts both automatic hardware sensor updates, manual REST event injections, and DTEK schedule re-fetches.

#### SSE Events Reference

1. **`event: connected`**  
   Emitted immediately upon opening the connection.
   ```text
   event: connected
   data: {"status":"connected","timestamp":"2026-10-04T03:10:00.000Z","active_clients":1}
   ```

2. **`event: power_status`**  
   Dispatched immediately upon connection (with current status) and whenever the electricity state changes.
   ```text
   event: power_status
   data: {"state":"online","reason":"active","reason_message":"Сенсор активний","is_stale":false,"timestamp":"2026-10-04T03:10:00.000Z"}
   ```

3. **`event: manual_event_added`**  
   Broadcast when a new manual event is created via `POST /api/v1/power/events`.
   ```text
   event: manual_event_added
   data: {"created":true,"event_id":104,"firebase_key":"manual_...","status":"online","timestamp":"2026-10-04T03:10:00.000Z","device":"HomeAssistant","is_manual":true}
   ```

4. **`event: schedule_updated`**  
   Broadcast when a background or manual DTEK sync successfully updates outage schedules.
   ```text
   event: schedule_updated
   data: {"timestamp":"2026-10-04T03:10:00.000Z","groups_count":12,"source":"dtek_sync"}
   ```

---

## 6. Error Codes & HTTP Status Dictionary

| HTTP Code | Error Code | Trigger Condition / Description |
| :--- | :--- | :--- |
| `400` | `INVALID_HOST` | Request `Host` header does not match `localhost`, `127.0.0.1`, or `::1` |
| `400` | `INVALID_GROUP` | Specified GPV group is not one of the 12 valid groups (`GPV1.1` - `GPV6.2`) |
| `400` | `INVALID_DATE_FORMAT` | Date string cannot be parsed as `YYYY-MM-DD` |
| `400` | `INVALID_DATE_ORDER` | Query parameter `from` is chronologically after `to` |
| `400` | `INCOMPLETE_DATE_RANGE` | Only one of `from` / `to` was provided (both are required for ranged queries) |
| `400` | `BODY_TOO_LARGE` | POST request body exceeds the 64KB (`65536` bytes) security ceiling |
| `400` | `EMPTY_BODY` | POST body is empty or whitespace-only |
| `400` | `INVALID_JSON` | Request body is not a valid JSON object (`{ ... }`) |
| `400` | `INVALID_STATUS` | Power event status is missing or not `"online"` / `"offline"` |
| `400` | `INVALID_TIMESTAMP` | Provided event timestamp cannot be parsed into a valid DateTime |
| `404` | `ROUTE_NOT_FOUND` | Path does not match any registered endpoint |
| `405` | `METHOD_NOT_ALLOWED` | HTTP method is not permitted on this route (check `Allow` header) |
| `500` | `INTERNAL_ERROR` | Unhandled server exception (includes exception details in response) |
| `503` | `SERVICE_UNAVAILABLE` | Local server is shutting down or resources are temporarily exhausted |
