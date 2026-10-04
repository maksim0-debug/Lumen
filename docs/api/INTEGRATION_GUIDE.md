# Lumen Local API Integration & AI Agent Guide

> **Integration Recipes, Automations, and Client Implementations**  
> Tailored for smart home engines (Home Assistant), AI assistants, automation scripts, and background daemons.

---

## 1. Quick Ingestion Card for AI / LLM Agents

If you are an AI assistant processing this document to interact with the Lumen API:
- **Base Endpoint**: `http://127.0.0.1:18080/api/v1`
- **Target Host Header**: Must always send `Host: 127.0.0.1:18080` or `Host: localhost:18080` (DNS rebinding protection).
- **Primary Data Source**: Use `GET /status?group={GROUP}` for a full snapshot (power + schedule + countdown) in 1 roundtrip.
- **Real-Time Data**: Connect to `GET /stream` for Server-Sent Events (`event: power_status`, `event: schedule_updated`).
- **Manual Power Reporting**: Send `POST /power/events` with `{"status": "online"|"offline"}` (body must be under 64KB).
- **Outage Schedule Groups**: 12 groups total (`GPV1.1` to `GPV6.2`). Default is `GPV2.1`.

---

## 2. Common Integration Patterns & Workflows

### 2.1 Workflow 1: Single-Call Dashboard Polling
Instead of querying multiple endpoints, fetch everything needed for a dashboard widget in a single request:
```bash
curl -s http://127.0.0.1:18080/api/v1/status?group=GPV2.1
```
Key fields to extract:
- `data.power.state`: `"online"` | `"offline"` | `"unknown"`
- `data.power.duration_minutes`: Duration in minutes in current state.
- `data.countdown.minutes_remaining`: Minutes until next state change.
- `data.countdown.target_status`: Scheduled next state (`"on"` or `"off"`).
- `data.schedule_today.total_outage_hours`: Scheduled outage hours today.

---

### 2.2 Workflow 2: External Power State Ingestion (UPS / Smart Plug / Ping)
When an external device (such as a NUT-connected UPS, a Zigbee smart plug, or an ESP32 ping monitor) detects a power outage or restoration, update Lumen instantly:

```bash
# Report blackout:
curl -X POST http://127.0.0.1:18080/api/v1/power/events \
  -H "Content-Type: application/json" \
  -d '{"status": "offline", "device": "SmartPlug_Router"}'

# Report power restored:
curl -X POST http://127.0.0.1:18080/api/v1/power/events \
  -H "Content-Type: application/json" \
  -d '{"status": "online", "device": "SmartPlug_Router"}'
```
*Effect*: This immediately writes to SQLite, updates in-memory monitoring status, and broadcasts `manual_event_added` to all connected SSE clients without waiting for external cloud sync.

---

### 2.3 Workflow 3: Re-fetching Outage Schedules from DTEK
When you want to verify if DTEK updated Kyiv power outage schedules:
```bash
curl -X POST "http://127.0.0.1:18080/api/v1/schedule/sync?force=true"
```
*Handling response*:
- If `status == "success"`: Schedules updated.
- If `status == "cooldown_active"`: Previous sync occurred less than 30 seconds ago. Re-query using existing data.

---

## 3. Home Assistant Configuration

### 3.1 REST Sensors (`configuration.yaml`)

Add these sensor definitions to Home Assistant:

```yaml
sensor:
  - platform: rest
    name: "Lumen Electricity Status"
    resource: "http://127.0.0.1:18080/api/v1/status?group=GPV2.1"
    scan_interval: 30
    value_template: "{{ value_json.data.power.state }}"
    icon: >
      {% if value_json.data.power.state == 'online' %}
        mdi:flash
      {% elif value_json.data.power.state == 'offline' %}
        mdi:flash-off
      {% else %}
        mdi:help-circle-outline
      {% endif %}
    json_attributes_path: "$.data"
    json_attributes:
      - power
      - countdown
      - schedule_today

  - platform: rest
    name: "Lumen Outage Countdown"
    resource: "http://127.0.0.1:18080/api/v1/schedule/countdown?group=GPV2.1"
    scan_interval: 60
    value_template: >
      {% if value_json.data.has_countdown %}
        {{ value_json.data.minutes_remaining }}
      {% else %}
        0
      {% endif %}
    unit_of_measurement: "min"
    icon: "mdi:timer-outline"
    json_attributes_path: "$.data"
    json_attributes:
      - target_status
      - formatted_remaining
      - message
      - target_time
```

### 3.2 REST Commands for Automations

```yaml
rest_command:
  lumen_report_power_online:
    url: "http://127.0.0.1:18080/api/v1/power/events"
    method: "POST"
    headers:
      Content-Type: "application/json"
    payload: '{"status": "online", "device": "HomeAssistant Automation"}'

  lumen_report_power_offline:
    url: "http://127.0.0.1:18080/api/v1/power/events"
    method: "POST"
    headers:
      Content-Type: "application/json"
    payload: '{"status": "offline", "device": "HomeAssistant Automation"}'

  lumen_sync_schedules:
    url: "http://127.0.0.1:18080/api/v1/schedule/sync?force=true"
    method: "POST"
```

### 3.3 Automations (Blackout Alerts)

```yaml
automation:
  - alias: "Lumen: Alert on Power Outage"
    trigger:
      - platform: state
        entity_id: sensor.lumen_electricity_status
        to: "offline"
    action:
      - service: notify.notify
        data:
          title: "⚡ Знеструмлення!"
          message: "Світло вимкнули. Залишок за графіком перевіряється."

  - alias: "Lumen: Alert on Power Restored"
    trigger:
      - platform: state
        entity_id: sensor.lumen_electricity_status
        to: "online"
    action:
      - service: notify.notify
        data:
          title: "💡 Світло з'явилося!"
          message: "Електропостачання відновлено."
```

---

## 4. Python Implementation

### 4.1 Synchronous REST Client (`requests`)

```python
import requests
from typing import Dict, Any, Optional

class LumenApiClient:
    def __init__(self, base_url: str = "http://127.0.0.1:18080/api/v1", default_group: str = "GPV2.1"):
        self.base_url = base_url.rstrip("/")
        self.default_group = default_group
        self.session = requests.Session()
        self.session.headers.update({
            "Accept": "application/json",
            "User-Agent": "LumenPythonClient/1.0",
        })

    def get_status(self, group: Optional[str] = None) -> Dict[str, Any]:
        """Fetch unified status snapshot."""
        grp = group or self.default_group
        res = self.session.get(f"{self.base_url}/status", params={"group": grp})
        res.raise_for_status()
        return res.json()["data"]

    def report_event(self, status: str, device: str = "PythonScript") -> Dict[str, Any]:
        """Report manual power event ('online' or 'offline')."""
        payload = {"status": status.lower(), "device": device}
        res = self.session.post(f"{self.base_url}/power/events", json=payload)
        res.raise_for_status()
        return res.json()["data"]

    def trigger_sync(self, force: bool = False) -> Dict[str, Any]:
        """Trigger DTEK schedule update."""
        res = self.session.post(f"{self.base_url}/schedule/sync", params={"force": str(force).lower()})
        res.raise_for_status()
        return res.json()["data"]

if __name__ == "__main__":
    client = LumenApiClient()
    status = client.get_status()
    print(f"Electricity: {status['power']['state'].upper()} (duration: {status['power']['duration_minutes']} min)")
    if status['countdown']['has_countdown']:
        print(f"Next switch: {status['countdown']['target_status'].upper()} in {status['countdown']['minutes_remaining']} min")
```

---

### 4.2 Asynchronous Real-Time SSE Listener (`httpx`)

```python
import asyncio
import json
import httpx

async def listen_lumen_events(base_url: str = "http://127.0.0.1:18080/api/v1"):
    url = f"{base_url}/stream"
    headers = {"Accept": "text/event-stream"}
    
    print(f"Connecting to Lumen SSE stream at {url}...")
    async with httpx.AsyncClient(timeout=None) as client:
        async with client.stream("GET", url, headers=headers) as response:
            current_event = None
            async for line in response.aiter_lines():
                if not line:
                    continue
                # Handle heartbeat comments (: ping)
                if line.startswith(":"):
                    continue
                if line.startswith("event:"):
                    current_event = line.replace("event:", "").strip()
                elif line.startswith("data:"):
                    data_str = line.replace("data:", "").strip()
                    payload = json.loads(data_str)
                    handle_event(current_event, payload)
                    current_event = None

def handle_event(event: str, data: dict):
    if event == "connected":
        print(f"✅ Connected to Lumen. Active clients: {data.get('active_clients')}")
    elif event == "power_status":
        print(f"⚡ Power status changed: {data.get('state').upper()} (reason: {data.get('reason')})")
    elif event == "schedule_updated":
        print(f"📅 DTEK Schedule updated for {data.get('groups_count')} groups")
    elif event == "manual_event_added":
        print(f"✍️ Manual event ingested: {data.get('status')} by {data.get('device')}")

if __name__ == "__main__":
    try:
        asyncio.run(listen_lumen_events())
    except KeyboardInterrupt:
        print("\nDisconnected.")
```

---

## 5. TypeScript / Node.js Implementation

```typescript
import { fetch } from 'undici'; // Or global fetch in Node 18+

interface StatusResponse {
  success: boolean;
  data: {
    group: string;
    power: {
      state: 'online' | 'offline' | 'unknown';
      duration_minutes: number;
    };
    countdown: {
      has_countdown: boolean;
      minutes_remaining: number;
      target_status: string;
    };
  };
}

const BASE_URL = 'http://127.0.0.1:18080/api/v1';

async function getDashboardStatus(group = 'GPV2.1'): Promise<void> {
  const response = await fetch(`${BASE_URL}/status?group=${group}`);
  if (!response.ok) {
    throw new Error(`HTTP error ${response.status}`);
  }
  const body = (await response.json()) as StatusResponse;
  const { power, countdown } = body.data;

  console.log(`Current state: ${power.state}`);
  if (countdown.has_countdown) {
    console.log(`Countdown: ${countdown.target_status} in ${countdown.minutes_remaining} min`);
  }
}

async function reportPowerState(status: 'online' | 'offline'): Promise<void> {
  const response = await fetch(`${BASE_URL}/power/events`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ status, device: 'NodeJS Service' }),
  });
  const result = await response.json();
  console.log('Event reported:', result);
}
```

---

## 6. CLI & Shell Cheatsheet

### 6.1 Check Health & Uptime
```bash
curl -s http://127.0.0.1:18080/api/v1/health | jq .data
```

### 6.2 Get Real Outage Intervals for Today
```bash
curl -s "http://127.0.0.1:18080/api/v1/power/intervals" | jq .data
```

### 6.3 Query Outage Events with Limit and Sort
```bash
curl -s "http://127.0.0.1:18080/api/v1/power/events?limit=5&sort=desc" | jq .data.events
```

### 6.4 Inspect Outage Duration Records
```bash
curl -s "http://127.0.0.1:18080/api/v1/analytics/records?mode=real&group=GPV2.1" | jq .data
```

### 6.5 Export Database Backup for Date Range
```bash
curl -s "http://127.0.0.1:18080/api/v1/history/export?from=2026-10-01&to=2026-10-04" > lumen_backup.json
```

---

## 7. Edge Cases & Resilience Checklist

1. **Host Header**: Always ensure your HTTP client preserves the loopback Host header (`127.0.0.1` or `localhost`). Proxying tools that rewrite the Host header to an external IP or custom domain will be blocked.
2. **Payload Size Guard**: Never send batches or oversized payloads to `/power/events`. Keep payloads concise (under 64KB).
3. **SSE Disconnections**: If the stream connection drops (e.g. Lumen application restart), implement an exponential backoff reconnect policy (initial wait 1s, doubling up to 30s).
4. **Schedule Cooldown**: DTEK scrapers are rate-limited to avoid IP bans. If `POST /schedule/sync` responds with `status: "cooldown_active"`, respect the 30-second cooldown period before retrying.
