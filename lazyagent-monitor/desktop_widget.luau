-- lazyagent-monitor desktop widget
--
-- Read-only tile that mirrors the bar widget: lists each running session with
-- its agent icon and status (like the lazyagent TUI). Desktop widgets have no
-- tooltips, so the breakdown is drawn inline. It only reads noctalia.state
-- (published by the bridge service); no process control here.

local state = noctalia.state
local icon = require("./lib/icon.luau")

local COLOR_ACTIVE = "primary" -- theme role: resolved by the host at render time
local COLOR_IDLE = "#8a8f98"
local COLOR_DOWN = "#d97706" -- amber: stream broken

local GLYPH_ACTIVE = "activity"
local GLYPH_IDLE = "circle"
local GLYPH_DOWN = "alert-circle"

local STATUS_COLORS = {
	idle = "#6B7280",
	waiting = "#4ADE80",
	thinking = "#F59E0B",
	compacting = "#2DD4BF",
	reading = "#38BDF8",
	writing = "#FB923C",
	running = "#A78BFA",
	searching = "#34D399",
	browsing = "#22D3EE",
	spawning = "#F472B6",
}
local STATUS_DEFAULT = "#6B7280"

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

local function statusColor(status)
	return STATUS_COLORS[status] or STATUS_DEFAULT
end

-- Resolve the display language from the `language` setting (same scheme as the
-- bar widget). "auto" (or unset/invalid) falls back to noctalia.tr(), which
-- follows the shell language.
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

local function render()
	local status = state.get("status")
	local snap = state.get("snapshot")

	local iconScale = tonumber(noctalia.getConfig("icon_scale")) or 100
	local iconSize = 18 * (iconScale / 100)

	-- Build the header icon node; a user-configured icon (custom SVG tinted to the
	-- active color, or a custom glyph) is used only for the connected state, so the
	-- disconnected / no-data states keep their semantic glyphs.
	local function headerIcon(roleColor, bakeColor, defaultGlyph)
		local configured = icon.resolveIcon(bakeColor)
		if configured ~= nil and configured.image ~= nil then
			return ui.image({ path = configured.image, width = iconSize, height = iconSize })
		end
		local glyph = configured ~= nil and configured.glyph or defaultGlyph
		return ui.glyph({ name = glyph, size = iconSize, color = roleColor })
	end

	local headerNode, headerColor, headerText
	if status == "connected" and snap ~= nil and snap.stats ~= nil then
		local hasActive = snap.stats.active > 0
		local hasWaiting = false
		for _, s in ipairs(snap.sessions or {}) do
			if s.activity == "waiting" then
				hasWaiting = true
				break
			end
		end
		local roleColor, bakeColor, defaultGlyph
		if hasWaiting then
			roleColor, bakeColor, defaultGlyph = "secondary", icon.secondaryHex(), GLYPH_ACTIVE
		elseif hasActive then
			roleColor, bakeColor, defaultGlyph = COLOR_ACTIVE, icon.activeHex(), GLYPH_ACTIVE
		else
			roleColor, bakeColor, defaultGlyph = COLOR_IDLE, COLOR_IDLE, GLYPH_IDLE
		end
		headerColor = roleColor
		headerNode = headerIcon(roleColor, bakeColor, defaultGlyph)
		headerText = string.format("%d/%d", snap.stats.active, snap.stats.total)
	elseif status == "disconnected" then
		headerNode = ui.glyph({ name = GLYPH_DOWN, size = iconSize, color = COLOR_DOWN })
		headerColor = COLOR_DOWN
		headerText = "?"
	else
		headerNode = headerIcon(COLOR_IDLE, COLOR_IDLE, GLYPH_IDLE)
		headerColor = COLOR_IDLE
		headerText = "\u{2014}"
	end

	local children = {
		ui.row({ gap = 8, align = "center" }, {
			headerNode,
			ui.label({ text = headerText, fontSize = 22, fontWeight = "bold", color = headerColor }),
		}),
	}

	if status == "connected" and snap ~= nil and type(snap.sessions) == "table" and not noctalia.getConfig("compact") then
		local sessions = {}
		for _, s in ipairs(snap.sessions) do
			table.insert(sessions, s)
		end
		table.sort(sessions, function(a, b)
			if a.is_active ~= b.is_active then
				return a.is_active
			end
			return (a.short_name or "") < (b.short_name or "")
		end)

		for _, s in ipairs(sessions) do
			local act = s.activity ~= nil and s.activity ~= "" and s.activity or "idle"
			local color = statusColor(act)
			table.insert(children, ui.row({ gap = 8, align = "center" }, {
				ui.label({ text = agentIcon(s.agent), fontSize = 16, fontWeight = "bold", color = color }),
				ui.label({ text = act, fontWeight = "bold", color = color }),
				ui.label({ text = icon.statusSymbol(act), fontSize = 16, color = color }),
			}))
		end
	end

	desktopWidget.render(ui.column({ gap = 6, padding = 10 }, children))
end

state.watch("snapshot", render)
state.watch("status", render)
render()

-- Settings changed (icon, language, …): re-resolve and re-render so
-- icon-glyph/image/colorize and language changes apply without an entry reload.
function onConfigChanged()
	refreshLang()
	render()
end