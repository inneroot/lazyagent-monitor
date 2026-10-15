Great, let's start with local testing through our own repository.

The main thing to understand: **you don't need a Git repository at all for development**. Noctalia can load plugins directly from a local folder, which is much more convenient for iteration. A Git repository will only be needed when you want to share the plugin with others.

### 🛠️ Setting up local development

According to the Noctalia v5 documentation, the simplest way is to put the plugin in a special folder and specify the path as a `path source`.

**1. Create the plugin folder structure**

Let's say you named the plugin `lazyagent-monitor`. Create the directory:
```bash
mkdir -p ~/dev/noctalia-plugins/lazyagent-monitor
```
Inside it will be `plugin.toml`, `service.luau`, `widget.luau`, `README.md`, and `translations/en.json`.

**2. Register the plugin in the Noctalia config**

Open `~/.config/noctalia/config.toml` and add the section for your source and enable the plugin:
```toml
[plugins]
enabled = ["inner/lazyagent-monitor"]

  [[plugins.source]]
  enabled = true
  kind = "path"
  name = "inner"  # <-- this name will be part of the plugin ID
  location = "/home/inner/dev/noctalia-plugins"
```

**3. Make sure `plugin_api` in the manifest is correct**

The `plugin_api` must be specified in `plugin.toml`. According to the documentation, using `noctalia.httpStream()` requires API level 4 at minimum, but it's better to specify the current stable version (e.g., `plugin_api = 4` or higher if you use features from newer APIs).

### 📄 Plugin requirements file

I've prepared a brief summary of requirements for you that you can save as `REQUIREMENTS.md` next to the plugin. It's based on the official documentation and the submission rules for the community repository.

```markdown
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
```

### 🔗 Links to the official documentation

Here are direct links to the pages describing all the requirements (add them to the README or keep for reference):

| Page | What's there |
|------|--------------|
| [Manifest & Settings](https://docs.noctalia.dev/noctalia/plugins/development/manifest/) | Full description of `plugin.toml`, setting types, `plugin_api` format |
| [Plugin Development](https://docs.noctalia.dev/noctalia/plugins/development/) | Overview of the plugin system and links to all subpages |
| [Workflow & Publishing](https://docs.noctalia.dev/noctalia/plugins/development/workflow/) | Brief on how to publish to the community repository |
| [Using Plugins](https://docs.noctalia.dev/v5/plugins/) | How to add sources, including local `path source` |
| [community-plugins README](https://github.com/noctalia-dev/community-plugins) | PR submission rules (if you decide to publish) |

### 💡 Important note about the SSE API

In your previous code I suggested using `noctalia.httpStream()`. Make sure the `plugin_api` specified in `plugin.toml` supports this function. According to the documentation, `httpStream` is available starting from a certain API level (likely 4 or higher). If you set a too-low level, the function may be unavailable.

After creating the files and adding the path source, launch Noctalia from the terminal so you can see the logs, and enable the plugin in settings. Hot reload for path sources usually works automatically.