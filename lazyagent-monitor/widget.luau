-- lazyagent-monitor bar widget
--
-- Renders the aggregated snapshot published by the bridge service through
-- noctalia.state. No HTTP here - the widget only reads shared state.

local state = noctalia.state
local icon = require("./lib/icon.luau")

local COLOR_ACTIVE = "primary" -- theme role: resolved by the host at render time
local COLOR_IDLE = "#8a8f98"
local COLOR_DOWN = "#d97706" -- amber: stream broken

local GLYPH_ACTIVE = "bot"
local GLYPH_IDLE = "circle"
local GLYPH_DOWN = "alert-circle"
local GLYPH_LOADER = "loader"

-- Agent icons as shown in `lazyagent` TUI (single char per agent). pi → π,
-- opencode → O. The rest are best-effort placeholders; tweak freely.
local AGENT_ICONS = {
	pi = "π",
	opencode = "O",
	claude = "✳",
	codex = "⌘",
	cursor = "⌃",
	grok = "𝕏",
	kimi = "☯",
	kilo = "k",
	amp = "A",
	gemini = "✦",
}
local function agentIcon(agent)
	return AGENT_ICONS[agent]
		or (type(agent) == "string" and agent ~= "" and agent:sub(1, 1):upper() or "•")
end

local function setStatus(glyph, glyphColor, text, color)
	barWidget.setGlyph(glyph)
	barWidget.setGlyphColor(glyphColor)
	barWidget.setText(text)
	barWidget.setColor(color)
end

-- Show the user-configured icon (glyph or SVG) for a connected state, returning
-- the color (palette role) the caller should also apply to the text. The SVG is
-- baked with the active hex so it can be tinted to the theme's primary color.
local function setConnectedIcon(active)
	local roleColor = active and COLOR_ACTIVE or COLOR_IDLE
	local bakeColor = active and icon.activeHex() or COLOR_IDLE
	local configured = icon.resolveIcon(bakeColor)
	if configured ~= nil and configured.image ~= nil then
		barWidget.setImage(configured.image)
	else
		local glyph = configured ~= nil and configured.glyph or (active and GLYPH_ACTIVE or GLYPH_IDLE)
		barWidget.setGlyph(glyph)
		barWidget.setGlyphColor(roleColor)
	end
	return roleColor
end

-- Keep "starting…" visible instead of flipping to "?" while the just-launched
-- server is still coming up (the service republishes "disconnected" every 5s).
local GRACE_MS = 8000
local pendingStartUntilMs = 0

-- Resolve the widget's display language from the `language` setting. "auto"
-- (or an unset/invalid value) falls back to noctalia.tr(), which follows the
-- shell language. An explicit code loads translations/<lang>.json directly so
-- the widget ignores the shell locale.
local translations = {}
local function loadLang(lang)
	if translations[lang] ~= nil then
		return translations[lang]
	end
	local raw = noctalia.readFile("translations/" .. lang .. ".json")
	if raw == nil then
		return nil
	end
	local ok, data = pcall(noctalia.json.decode, raw)
	if ok and type(data) == "table" then
		translations[lang] = data
		return data
	end
	return nil
end

local langTable = nil
local function refreshLang()
	local overrideLang = noctalia.getConfig("language")
	langTable = nil
	if type(overrideLang) == "string" and overrideLang ~= "" and overrideLang ~= "auto" then
		langTable = loadLang(overrideLang)
	end
end
refreshLang()

local function tr(key, subst)
	if langTable ~= nil then
		local val = langTable[key]
		if val ~= nil then
			if subst ~= nil then
				return (val:gsub("{(%w+)}", function(name)
					return subst[name] or "{" .. name .. "}"
				end))
			end
			return val
		end
	end
	return noctalia.tr(key, subst)
end

local function renderIdle()
	local roleColor = setConnectedIcon(false)
	barWidget.setText("\u{2014}")
	barWidget.setColor(roleColor)
	barWidget.setTooltip({ "lazyagent", tr("widget.connecting") })
end

local function renderSnapshot(snap)
	if snap == nil or type(snap) ~= "table" or snap.stats == nil then
		return
	end
	local stats = snap.stats
	local active = stats.active > 0

	local roleColor = setConnectedIcon(active)
	barWidget.setText(string.format("%d/%d", stats.active, stats.total))
	barWidget.setColor(roleColor)

	local sessions = {}
	for _, s in ipairs(snap.sessions or {}) do
		table.insert(sessions, s)
	end
	table.sort(sessions, function(a, b)
		if a.is_active ~= b.is_active then
			return a.is_active
		end
		return (a.short_name or "") < (b.short_name or "")
	end)

	local rows = {}
	if #sessions == 0 then
		rows = { { tr("widget.sessions"), tr("widget.none") } }
	else
		for _, s in ipairs(sessions) do
			local act = s.activity ~= nil and s.activity ~= "" and s.activity or "idle"
			table.insert(rows, { agentIcon(s.agent), act })
		end
	end
	barWidget.setTooltip(rows)
end

local function renderStatus(statusValue)
	if statusValue == "disconnected" then
		if noctalia.nowMs() < pendingStartUntilMs then
			return -- in the grace window after a start; keep "starting…"
		end
		setStatus(GLYPH_DOWN, COLOR_DOWN, "", COLOR_DOWN)
		barWidget.setTooltip({ "lazyagent", tr("widget.disconnected") })
	elseif statusValue == "connected" then
		renderSnapshot(state.get("snapshot"))
		if state.get("snapshot") == nil then
			renderIdle()
		end
	end
end

renderIdle()

state.watch("snapshot", renderSnapshot)
state.watch("status", renderStatus)

local initialStatus = state.get("status")
local initialSnapshot = state.get("snapshot")
if initialSnapshot ~= nil then
	renderSnapshot(initialSnapshot)
elseif initialStatus == "disconnected" then
	renderStatus("disconnected")
end

-- Right-click toggles the local `lazyagent --api` server: stop it when a
-- process is running, otherwise start it. Right-click only fires for gestures
-- nobody has bound, so this stays clickable by default.
function onRightClick()
	setStatus(GLYPH_LOADER, COLOR_IDLE, "", COLOR_IDLE)
	noctalia.processMatches(function(matched)
		if matched then
			-- Running → STOP. runAsync gives no PID, so kill by pattern.
			pendingStartUntilMs = 0
			local ok = noctalia.runAsync({ "pkill", "-f", "lazyagent --api" })
			if ok then
				setStatus(GLYPH_LOADER, COLOR_IDLE, "", COLOR_IDLE)
				barWidget.setTooltip({ "lazyagent", tr("widget.tooltip_stopping") })
			else
				noctalia.notifyError("lazyagent-monitor", tr("widget.stop_failed"))
				renderStatus(state.get("status"))
			end
			return
		end

		-- Not running → START, but only when the stream is actually down.
		if state.get("status") == "connected" then
			return
		end

		local bin = noctalia.getConfig("lazyagent_bin")
		if type(bin) ~= "string" or bin == "" then
			bin = "lazyagent"
		end

		if not noctalia.commandExists(bin) then
			noctalia.notifyError("lazyagent-monitor", tr("widget.bin_not_found", { bin = bin }))
			renderStatus(state.get("status"))
			return
		end

		local ok = noctalia.runAsync({ bin, "--api" })
		if ok then
			pendingStartUntilMs = noctalia.nowMs() + GRACE_MS
			setStatus(GLYPH_LOADER, COLOR_ACTIVE, "", COLOR_ACTIVE)
			barWidget.setTooltip({ "lazyagent", tr("widget.tooltip_starting") })
		else
			noctalia.notifyError("lazyagent-monitor", tr("widget.start_failed", { bin = bin }))
			renderStatus(state.get("status"))
		end
	end, "lazyagent")
end

-- Settings changed (icon, language, …): re-resolve and re-render in place so
-- icon-glyph/image/colorize and language changes apply without an entry reload.
function onConfigChanged()
	refreshLang()
	renderStatus(state.get("status"))
end
