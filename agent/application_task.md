# Task for coding agent: Noctalia plugin for displaying LLM agents via lazyagent API

## 1. Task overview

Develop a plugin for Noctalia Shell (v5+) that displays information about running LLM agents (pi, opencode, and others) via the HTTP API of the lazyagent service. The plugin consists of two parts: a background service that connects to the lazyagent SSE stream and publishes data to the plugin's shared state, and a bar widget that displays aggregated statistics.

**Target environment**: Debian GNU/Linux 13 (trixie), WM niri (Wayland), Noctalia Shell v5+.

---

## 2. Solution architecture

The plugin uses the "service + widget" pattern recommended by the Noctalia documentation:

| Component | Purpose |
|-----------|---------|
| `[[service]]` | Connects to the `/api/events` SSE stream, parses events, deduplicates, and publishes state |
| `[[widget]]` | Reads state via `noctalia.state.watch()`, displays aggregates in the bar |

The separation is mandatory: services and widgets run in isolated VMs and do not share Lua memory — communication only via `noctalia.state`.

---

## 3. Data source: lazyagent HTTP API

### 3.1 Starting the server

The server is already running by the user: `lazyagent --api` on `http://127.0.0.1:7421`. Authentication via Bearer token, which is printed on first launch and stored in `~/.config/lazyagent/config.json`.

### 3.2 SSE endpoint

**URL**: `GET /api/events`

**Authentication quirk for SSE**: the `Authorization: Bearer` header is **not supported** by browser EventSource clients, so lazyagent accepts the token via the `?token=<token>` query parameter **only for this endpoint**.

**Stream format** (verified in the user's real terminal):
```
event: update
data: {"sessions":[...],"stats":{"total_sessions":1,"active_sessions":0,"window_minutes":30}}

event: update
data: {...}
```

The server sends a full state snapshot on a regular basis (heartbeat), even if nothing changed.

### 3.3 Data schema

**Each session in the `sessions` array**:

| Field | Type | Description |
|-------|------|-------------|
| `session_id` | string | Unique session identifier |
| `agent` | string | Agent name (`pi`, `opencode`, `claude`, etc.) |
| `cwd` | string | Project working directory |
| `short_name` | string | Short name (usually a path) |
| `activity` | string | State: `idle`, `thinking`, `writing`, `running`, `waiting`, etc. |
| `is_active` | boolean | `true` if the session is active right now |
| `model` | string | Model in use |
| `cost_usd` | number | Estimated cost in dollars |
| `last_activity` | string | ISO 8601 timestamp of last activity |
| `total_messages` | number | Number of messages |

**The `stats` block**:

| Field | Type | Description |
|-------|------|-------------|
| `total_sessions` | number | Total sessions in the window |
| `active_sessions` | number | Active sessions |
| `window_minutes` | number | Size of the time window (default 30 minutes) |

---

## 4. Implementation requirements

### 4.1 Manifest (`plugin.toml`)

Required fields: `id`, `name`, `version`, `plugin_api`.

**Minimum `plugin_api`**: 4 (for `noctalia.httpStream()`).

**Structure**:
```toml
id = "<author>/lazyagent-monitor"
name = "Lazyagent Monitor"
version = "1.0.0"
plugin_api = 4
author = "<author>"
license = "MIT"
description = "Displays LLM agent activity from lazyagent API"

[[widget]]
id = "monitor"
entry = "widget.luau"

[[service]]
id = "bridge"
entry = "service.luau"
```

### 4.2 Service (`service.luau`)

**Tasks**:

1. **Reading configuration**: the lazyagent token is stored in `~/.config/lazyagent/config.json` (field `bearer_token`, or derived from the passphrase — verify against the real file). Read via `noctalia.readFile()`.

2. **Connecting to SSE**: use `noctalia.httpStream(request, onLine, onClose)`.

   **Critically important**: lazyagent accepts the token for SSE via the `?token=` query parameter, because EventSource does not support custom headers. URL format:
   ```
   http://127.0.0.1:7421/api/events?token=<bearer_token>
   ```

3. **Parsing the stream**: each significant line has the format `data: {json}`. Ignore `event: update` lines. Parse JSON via `noctalia.json.decode()`.

4. **Deduplication (variant A)**: compute a "fingerprint" of the state from key fields (`session_id:activity:is_active` for each session + `stats.total_sessions:stats.active_sessions`). Compare with the previous one. If it matches — **do not publish**, do not update state. This prevents unnecessary widget redraws on heartbeat events.

5. **Publishing state**: via `noctalia.state.set(key, value)`. Key, for example, `"snapshot"`. Value — a table with fields:
   - `sessions`: array of sessions (only needed fields to save space)
   - `stats`: `{total, active, window_minutes}`
   - `agents`: aggregated per-agent counter `{pi = N, opencode = M, ...}`

6. **Reconnection**: On `onClose` (connection drop, 401 error) — reconnect via `noctalia.setTimeout()` with a 5-second delay. `httpStream` does not reconnect automatically.

### 4.3 Widget (`widget.luau`)

**Tasks**:

1. **Subscribing to state**: `noctalia.state.watch("snapshot", callback)`.

2. **Rendering in the bar**: use `barWidget.setText()` and/or `barWidget.setGlyph()`. Recommended format — compact, e.g.: `● 2/5` (active/total) or an icon + number of active.

3. **Color indication** (optional, if the API supports text color): green when `active > 0`, gray when `active == 0`.

4. **Tooltip**: On hover, show a per-agent breakdown: "pi: 1 active, opencode: 0 active".

5. **Handling empty state**: Until the service publishes its first snapshot, show `—` or `0`.

---

## 5. Limitations and known issues

| Issue | Solution |
|-------|----------|
| `httpStream` in Noctalia v5 uses a native HTTP client, but lazyagent requires the token for SSE via a query parameter | Use `?token=` in the URL for SSE, as documented in lazyagent |
| The token may change when lazyagent is restarted with a new passphrase | Read `config.json` on every reconnect |
| Service and widget are separate VMs | Only `noctalia.state` for data exchange |
| `onClose` fires on any error, including 401 | On status=401, notify the user that the token needs checking |

---

## 6. Acceptance criteria

- [ ] The plugin appears in `Settings → Plugins` after installation into `~/.local/share/noctalia/plugins/`
- [ ] The service connects to `http://127.0.0.1:7421/api/events?token=...` and receives events
- [ ] Deduplication works: the widget does not redraw on unchanged data
- [ ] The widget displays `active/total` in the bar
- [ ] The tooltip shows a per-agent breakdown
- [ ] When lazyagent stops, the service reconnects after 5 seconds
- [ ] On an invalid token (401), the service logs the error and notifies the user
- [ ] The plugin is compatible with `plugin_api = 4` (Noctalia v5.0.0-beta.4+)

---

## 7. References

- **Noctalia Plugin Development**: `https://docs.noctalia.dev/noctalia/plugins/development/`
- **Runtime API (httpStream, state)**: `https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/`
- **Plugin API Versions**: `https://docs.noctalia.dev/noctalia/plugins/development/plugin-api/`
- **lazyagent HTTP API**: `https://lazyagent.dev/docs/interfaces/http-api/`
- **Example plugin (ticker service + widget)**: official repo `noctalia-dev/official-plugins`, `example/` directory