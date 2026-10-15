# Lazyagent Monitor — Noctalia v5 plugin

Shows the activity of running LLM agents (`pi`, `opencode`,
`claude`, etc.) in the Noctalia bar via the HTTP API of the local
[lazyagent](https://lazyagent.dev) service: a compact `active/total` counter
(theme primary color when there's activity) and a per-agent breakdown in the tooltip.

## Structure

```
lazyagent-monitor/
  plugin.toml          # manifest: [[widget]] monitor + [[desktop_widget]] desktop + [[service]] bridge
  service.luau         # SSE client: connect, parse, dedup, reconnect
  widget.luau          # bar widget: glyph + color + tooltip
  desktop_widget.luau  # desktop widget: glyph + color + inline breakdown
  translations/        # setting labels and strings (10 languages: en ru de fr es it pt zh ja hi)
```

The service and widgets run in isolated VMs and exchange data only
via `noctalia.state` (keys `snapshot` and `status`).

Indication is via color and glyph, text is kept to a minimum:

| State | Glyph | Color |
|-------|-------|-------|
| Agents active | `robot` / custom | theme primary |
| Connected, none active | `robot` / custom | gray `#8a8f98` |
| No data | `robot` / custom | gray `#8a8f98` |
| Stream dropped | `alert-circle` | amber `#d97706` |

> By default the glyph `robot` is shown; a custom glyph or SVG is set in the
> widget and desktop-widget settings via `icon_glyph` / `icon_image`.
> The active-state color is the `primary` role of the current Noctalia theme: glyphs and text
> are colored by the host; the SVG is recolored to the `primary` hex color (if
> `icon_colorize` is enabled).

## Installation

### From a local repository (development)

1. Add a path source to the Noctalia config
   (`~/.config/noctalia/config.toml` or via Settings → Plugins → Sources):

   ```toml
   [plugins]
     [[plugins.source]]
     enabled = true
     kind = "path"
     name = "inner"
     location = "/home/inner/dev/lazyagent-monitor"
   ```

   > The source directory must contain a **subdirectory** with the plugin
   > (`lazyagent-monitor/plugin.toml`), as in the community/official repositories.

2. Enable the plugin: `noctalia msg plugins enable inner/lazyagent-monitor`
   or Settings → Plugins.

3. Add the widget to the bar — in the config:

   ```toml
   [widget.lazyagent_monitor]
   type = "inner/lazyagent-monitor:monitor"
   ```

   and add `"lazyagent_monitor"` to the `start`/`end` list of the desired bar.

4. **Desktop widget** (optional): add it in the desktop widget editor
   (`Settings → Desktop widgets → Add → `inner/lazyagent-monitor:desktop``).
   Position and size are set manually (host-owned); the script only draws the content.

### From the community catalog

The plugin will appear in the catalog after publishing to
`noctalia-dev/community-plugins`.

## Dependencies

- Noctalia v5 (plugin_api ≥ 31; `httpStream` requires ≥ 4, `nowMs()` — ≥ 12,
  argv-format `runAsync` — ≥ 24, `getColor()` for the primary tone — ≥ 31)
- `lazyagent` with the API running: `lazyagent --api`
  (default `http://127.0.0.1:7421`)

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `token` | empty | lazyagent Bearer token. Empty — derived automatically via `lazyagent passphrase --show`. |
| `lazyagent_bin` | `lazyagent` | Binary name or full path, visible from the Noctalia process (its PATH differs from your shell PATH). |
| `language` (widget and desktop) | `auto` | Display language. `auto` — as in the system; otherwise a code from `en ru de fr es it pt zh ja hi`. |
| `icon_glyph` (widget and desktop) | `robot` | Glyph icon instead of the state glyph (Tabler / Nerd-Font name). Empty — state glyph (`bot`/`circle`/`alert-circle`). |
| `icon_image` (widget and desktop) | empty | Path to your own SVG instead of the glyph. Empty — use the glyph. |
| `icon_colorize` (widget and desktop) | `true` | Recolor your SVG to the theme primary color when active. `false` — show the SVG as-is. |

> The `language`, `icon_glyph`, `icon_image`, `icon_colorize` settings are at the
> widget (`[[widget.setting]]`) and desktop-widget (`[[desktop_widget.setting]]`) level:
> Bar Settings → widget `lazyagent_monitor` (or Settings → Desktop widgets).

## How it works

1. The service resolves the token (setting → `lazyagent passphrase --show` →
   `bearer_token` in `config.json`) and opens the SSE stream
   `GET /api/events?token=...` (for SSE the token is passed only as a query parameter).
2. Each `data: {json}` event is parsed; the state "fingerprint"
   (`session_id:activity:is_active:short_name` for each session + `stats`)
   is compared with the previous one — heartbeats without changes are **not published**,
   the widget is not redrawn.
3. On disconnect (`onClose`) the service reconnects after 5 seconds; on 401 —
   it clears the token cache, shows a notification, and retries at 30-second intervals.

## Toggling `lazyagent --api` from the widget

**Right-click** on the widget toggles the local `lazyagent --api` server:

- when the process is not running — starts it (widget: `checking… → starting…`),
  after which the service connects on its own (≤ 5 s) and returns `active/total`;
- when the process is running — stops it (`stopping…`), the widget goes to `?`.

- The binary is taken from the `lazyagent_bin` setting (solves the PATH issue — see
  troubleshooting); default `lazyagent`.
- "running/stopped" detection goes through `noctalia.processMatches`;
  the start is ignored at `status = "connected"` (protection against duplicates).
- If the binary is not found on PATH — the plugin shows a
  "Binary not found" notification and asks to set `lazyagent_bin` to a full path.
- After starting, the widget does not switch to `?` for ~8 s (grace period), so
  `starting…` doesn't flicker while the server starts up.

## Troubleshooting

- **The widget shows `?`** — the stream dropped, the service is reconnecting.
- **A 401 notification** — the lazyagent passphrase changed: clear the
  `token` setting (or update it) — the service will re-derive the token on its own.
- **`token resolution failed` in logs** — `lazyagent` not found: set the
  full path in `lazyagent_bin` (the Noctalia process PATH does not contain
  `~/go/bin`).
- **`failed to execute 'lazyagent'` / click: `starting… → ?`** — the `lazyagent`
  binary is not visible to the Noctalia process. Set in the plugin settings
  `lazyagent_bin = /home/inner/go/bin/lazyagent` (or the current path from
  `command -v lazyagent`).
- Logs: `~/.cache/noctalia/noctalia.log`, tag `[script-runtime]`, prefix
  `lazyagent-monitor:`.