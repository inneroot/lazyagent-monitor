# Implementation plan: Noctalia plugin `lazyagent-monitor`

> **Status (Oct 15, ~17:00): Phases 1–4 done.** The plugin is installed in
> Noctalia v5.2.1 via path-source `inner`, enabled, widget in the bar.
> Real discrepancies found during integration:
> 1. Path source expects a subfolder with the plugin — files moved into
>    `lazyagent-monitor/` inside the repository.
> 2. The Noctalia process PATH does not contain `~/go/bin` → added the
>    `lazyagent_bin` setting (filled in `settings.toml`).
> 3. The user entered the token via the GUI (filled in `settings.toml`);
>    auto-resolution via `lazyagent passphrase --show` remains a fallback.
> 4. The live Noctalia config is `~/.local/state/noctalia/settings.toml`
>    (the GUI periodically rewrites it; `~/.config/noctalia/config.toml` is
>    empty — you cannot duplicate tables there).
> 5. The 401 test passed normally (the user set the token himself); the
>    "server stopped" test was not run (lazyagent without systemd — risky),
>    the code path is shared with the 401 reconnect.
> 6. Dedup metrics in logs: ~500 heartbeats filtered out vs ~10 publications.


A plugin for Noctalia Shell v5+ (installed v5.2.1) that displays LLM agent activity in
the bar via the SSE API of the local `lazyagent` service (`http://127.0.0.1:7421`,
currently running, pid 846374).

Architecture: `[[service]]` (bridge, SSE client) + `[[widget]]` (bar widget),
communication only via `noctalia.state` (VM isolation).

---

## 1. Facts verified in the environment (Oct 15)

| Fact | Value |
|------|-------|
| Noctalia | v5.2.1, `/usr/local/bin/noctalia`, `~/.config/noctalia` **not present** yet |
| lazyagent | running on `127.0.0.1:7421`, sources in `/home/inner/dev/lazyagent` |
| `~/.config/lazyagent/config.json` | has `api_passphrase`, `api_salt`; **no** `bearer_token` |
| Token | derived via PBKDF2-SHA256(passphrase, salt, 600,000 iterations, 32 bytes) → base64url without padding (see `internal/apiauth/derive.go`) |
| Token for SSE | only via `?token=<token>` query parameter (headers not supported) |
| 401 | `onClose` receives `{ ok = true, status = 401 }` — the status arrives in onClose, the error body goes to onLine |

## 2. Deviations from `application_task.md` (corrections per the current documentation)

1. **`noctalia.setTimeout()` does not exist.** Timer scheduling is done via
   `noctalia.setUpdateInterval(1000)` + a `nextReconnectMs` flag and
   `noctalia.nowMs()` (requires `plugin_api ≥ 12`).
2. **Reading the token from `bearer_token` does not work** — no such field exists.
   Token resolution order (see §4.2):
   1. plugin setting `token` (the user pasted it manually);
   2. `noctalia.runAsync({ "lazyagent", "passphrase", "--show" }, cb)` —
      the subcommand is independent of the server, prints the current token to stdout;
   3. the `bearer_token` field from `config.json` (for the future, if lazyagent adds it).
   PBKDF2 in Luau is not feasible (600k iterations — prohibitively expensive for the plugin VM).
3. **Deduplication by "fingerprint"** from the task is kept, but we add
   `last_activity` to the fingerprint — otherwise the widget would "stick" on the old state
   until activity changes `activity`/`is_active`.

## 3. Plugin structure

```
lazyagent-monitor/                  # == root of this repository (name = id after "/")
  plugin.toml
  service.luau                      # [[service]] id="bridge"
  widget.luau                       # [[widget]] id="monitor"
  README.md
  translations/en.json              # setting labels (required, since there are settings)
  thumbnail.webp                    # 960×540, only for community — phase 6
```

`plugin.toml` (minimum):

```toml
id         = "inner/lazyagent-monitor"
name       = "Lazyagent Monitor"
version    = "1.0.0"
plugin_api = 12                      # nowMs(); httpStream requires 4
license    = "MIT"
description= "Displays LLM agent activity from the lazyagent API in the bar"
tags       = ["llm", "agents", "monitor"]
dependencies = ["lazyagent"]

[[setting]]                          # plugin-level: shared for service
key         = "token"
type        = "string"
label_key   = "settings.token.label"
description_key = "settings.token.description"
default     = ""

[[widget]]
id    = "monitor"
entry = "widget.luau"

[[service]]
id    = "bridge"
entry = "service.luau"
```

## 4. Phase 1 — service (`service.luau`)

Top-level (initialization) + `update()` (1000 ms interval):

1. **Token resolution** (see §2.2). Cache in `noctalia.state` under the key
   `"token"` together with its source; on 401 — clear the cache and re-derive.
2. **SSE connection**:
   ```lua
   stream = noctalia.httpStream({
     url = "http://127.0.0.1:7421/api/events?token=" .. token,
   }, onLine, onClose)
   ```
3. **Parsing in `onLine(line)`**:
   - lines starting with `data:` — strip the prefix, `noctalia.json.decode`;
   - `event:` and empty lines are ignored;
   - JSON error — `noctalia.log`, skip the line (do not crash the VM).
4. **Deduplication (fingerprint)**:
   ```
   fp = string.join(sorted "session_id:activity:is_active:short_name")
      .. "|stats:" .. total .. ":" .. active
   ```
   fp matches the previous one → do not publish.
5. **Publishing** `noctalia.state.set("snapshot", {...})`:
   ```lua
   {
     sessions = { { agent, activity, is_active, short_name, model, cost_usd } ... },
     stats    = { total = n, active = m, window_minutes = w },
     agents   = { ["pi"] = { total = n, active = m }, ... },  -- per-agent aggregate
     receivedAtMs = noctalia.nowMs(),
   }
   ```
   State values are plain data (copied between VMs).
6. **Reconnection in `onClose(result)`**:
   - `result.status == 401` → clear the token cache, `noctalia.notifyError`
     "check the lazyagent token", 30 s reconnect timeout
     (no spamming) + re-resolve the token via `passphrase --show`;
   - otherwise → `nextReconnectMs = nowMs() + 5000`.
   - In `update()`: if `stream == nil and nowMs() >= nextReconnectMs` —
     try to reconnect (re-checking the token if there's 401 history).
   - Before start/reconnect, call `stream:stop()` idempotently
     (stop suppresses onClose — protection against duplicates).
7. **Logging**: `noctalia.log` — connection, number of published
   and skipped (dedup) events, errors. This gives proof of dedup
   during acceptance.

## 5. Phase 2 — widget (`widget.luau`)

1. Initial state: `barWidget.setGlyph("robot")` (or "terminal"),
   `setText("—")`, tooltip "noctalia/lazyagent-monitor: connecting…"
2. `noctalia.state.watch("snapshot", fn)`:
   - `setText("%d/%d")` — `active/total`;
   - color: `setColor("ok"/"#22C55E")` if active > 0, `setColor("disabled"/gray)`
     if 0 (palette roles — check in `~/.config/noctalia` during integration,
     fallback to hex);
   - tooltip: array of strings "pi: 1 active", "opencode: 0 active" + a
     `total/active` line and the window (`window_minutes`).
3. Protection against "frozen" state: if `receivedAtMs` is older than ~90 s —
   show `?` / gray color (the service lost the stream).

## 6. Phase 3 — local integration and tests

1. Set up Noctalia (no config yet, created on first launch):
   - run `noctalia` from the terminal (logs to console);
   - in `~/.config/noctalia/config.toml`:
     ```toml
     [plugins]
     enabled = ["inner/lazyagent-monitor"]

       [[plugins.source]]
     enabled = true
     kind = "path"
     name = "inner"
     location = "/home/inner/dev/lazyagent-monitor"
     ```
2. Add the widget to the bar with `type = "inner/lazyagent-monitor:monitor"`
   (Settings → Bar / plugin settings).
3. **Test matrix** (acceptance criteria):
   - [ ] the plugin is visible in Settings → Plugins and can be enabled;
   - [ ] the service receives events: `event: update` arrives in logs,
     the widget shows `active/total` (verify with curl:
     `curl -s "http://127.0.0.1:7421/api/sessions"` with the token from
     `lazyagent passphrase --show`);
   - [ ] dedup: on heartbeats the "published" counter in logs does not grow;
   - [ ] tooltip with per-agent breakdown;
   - [ ] `kill lazyagent` → after ~5 s the service reconnects;
   - [ ] invalid token (paste garbage into the setting) → 401 → notifyError,
     no infinite loop;
   - [ ] hot reload: editing `.luau` applies without restarting Noctalia.
4. Verify in a real scenario: start a pi/opencode agent, see the
   change `0/0 → 1/1` and the active state.

## 7. Phase 4 — polish and docs

- `translations/en.json`: `settings.token.label` = "lazyagent Bearer token",
  `settings.token.description` = "Leave empty to derive automatically via
  `lazyagent passphrase --show`.";
- `README.md` (root): installation, path source, token setup,
  troubleshooting (401, 30-minute window, hot reload);
- optionally `icon` in the manifest.

## 8. Phase 5 — (optional, separately) publishing to community

Only on request: `thumbnail.webp` 960×540, full `translations`,
version bump, PR to `noctalia-dev/community-plugins` (1 PR = 1 plugin).

## 9. Risks

| Risk | Mitigation |
|------|------------|
| Palette roles for `setColor` are unknown in advance | fallback to hex; check in the theme palette during integration |
| `lazyagent passphrase --show` may print warnings too, to stdout | parse the line resembling a 43-char base64url token |
| SSE lines may not arrive one-per-line (chunking) — httpStream gives onLine per received line, CR is stripped by the runtime | trust onLine; do not parse "by buffer" |
| The token in the URL ends up in Noctalia logs | don't log the token; warn in README (same in lazyagent docs) |
| Noctalia `offline_mode` blocks httpStream | check during integration, document in README if needed |

## 10. Working order

1. Phase 1: `plugin.toml` + `service.luau` (core).
2. Phase 2: `widget.luau`.
3. Phase 3: integration into Noctalia + run the test matrix.
4. Phase 4: README + translations + fixes from test results.
5. Phase 5 — at the user's discretion.