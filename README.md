# Lazyagent Monitor

A Noctalia v5 plugin that shows live activity of running LLM agents (`pi`, `opencode`, `claude`, etc.) in the bar. It streams events from the local [lazyagent](https://lazyagent.dev) API over SSE and displays a compact `active/total` counter — colored with your theme's primary when agents are active — plus a per-agent breakdown in the tooltip and a desktop widget.

## Highlights

- **Bar widget + desktop widget** — compact glyph (variants: `robot`, `bot`, custom glyph/SVG) colored by state; no clutter, text is minimal.
- **SSE bridge service** — connects to `GET /api/events`, parses, deduplicates unchanged heartbeats (no redraws), auto-reconnects on disconnect, and re-resolves the token on 401.
- **Start/stop the API** — right-click the widget to toggle the local `lazyagent --api` server.
- **10 languages** (en, ru, de, fr, es, it, pt, zh, ja, hi) and per-widget customization (`language`, `icon_glyph`, `icon_image`, `icon_colorize`).

## Structure

```
lazyagent-monitor/
  plugin.toml          # manifest: monitor widget + desktop widget + bridge service
  service.luau         # SSE client: connect, parse, dedup, reconnect
  widget.luau          # bar widget: glyph + color + tooltip
  desktop_widget.luau  # desktop widget: glyph + color + inline breakdown
  translations/        # labels/strings in 10 languages
```

Service and widgets run in isolated VMs and communicate only via `noctalia.state` (`snapshot` and `status`).

## Status indicators

| State | Glyph | Color |
|-------|-------|-------|
| Agents active | `robot` / custom | theme primary |
| Connected, none active | `robot` / custom | gray `#8a8f98` |
| No data | `robot` / custom | gray `#8a8f98` |
| Stream dropped | `alert-circle` | amber `#d97706` |

## Requirements

- **Noctalia v5** (`plugin_api ≥ 31`)
- **lazyagent** with the API running: `lazyagent --api` (default `http://127.0.0.1:7421`)

## License

MIT