# Noctalia v5 plugin requirements

## Structure and required files

- `plugin.toml` (required)
- At least one `.luau` file with an entry point (required)
- `README.md` (recommended, required for community)
- `thumbnail.webp` (required for community, size 960×540)
- `translations/en.json` (required for community)
- `LICENSE` (if the license is not MIT)

## Required fields in plugin.toml

| Field | Requirement |
|-------|-------------|
| `id` | `<author>/<name>`, unique, kebab-case |
| `name` | Human-readable name |
| `version` | Strictly `MAJOR.MINOR.PATCH` (semver) |
| `plugin_api` | Integer, minimum required API version |
| `author` | Author/organization |

## Optional fields

| Field | Description |
|-------|-------------|
| `description` | Up to 120 characters for the catalog |
| `license` | SPDX identifier (default MIT) |
| `tags` | Array of tags for search |
| `icon` | Glyph name |
| `dependencies` | External dependencies (for information) |
| `deprecated` | `true` if the plugin is deprecated |

## Entry points

Each entry point is described by a separate section (`[[widget]]`, `[[service]]`, etc.):
- `id`: unique within the plugin
- `entry`: path to the `.luau` file

Entry point types: `widget`, `service`, `shortcut`, `launcher_provider`, `desktop_widget`, `panel`.

## Community restrictions

- Maximum 200 files in the plugin directory
- One PR — one plugin
- The directory name must exactly match the part of `id` after `/`
- `version` must increase on every change
- CI validates the manifest, entry scripts, and required files