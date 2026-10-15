-- lazyagent-monitor desktop widget
--
-- Read-only tile that mirrors the bar widget: shows agent activity as a
-- color/glyph indicator plus a per-agent breakdown. Desktop widgets have no
-- tooltips, so the breakdown is drawn inline. It only reads noctalia.state
-- (published by the bridge service); no process control here.

local state = noctalia.state

local COLOR_ACTIVE = "#22c55e"
local COLOR_IDLE = "#8a8f98"
local COLOR_DOWN = "#d97706" -- amber: stream broken

local GLYPH_ACTIVE = "activity"
local GLYPH_IDLE = "circle"
local GLYPH_DOWN = "alert-circle"

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

local overrideLang = noctalia.getConfig("language")
local langTable = nil
if type(overrideLang) == "string" and overrideLang ~= "" and overrideLang ~= "auto" then
	langTable = loadLang(overrideLang)
end

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

	local headerGlyph, headerColor, headerText
	if status == "connected" and snap ~= nil and snap.stats ~= nil then
		local hasActive = snap.stats.active > 0
		headerGlyph = hasActive and GLYPH_ACTIVE or GLYPH_IDLE
		headerColor = hasActive and COLOR_ACTIVE or COLOR_IDLE
		headerText = string.format("%d/%d", snap.stats.active, snap.stats.total)
	elseif status == "disconnected" then
		headerGlyph = GLYPH_DOWN
		headerColor = COLOR_DOWN
		headerText = "?"
	else
		headerGlyph = GLYPH_IDLE
		headerColor = COLOR_IDLE
		headerText = "\u{2014}"
	end

	local children = {
		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = headerGlyph, size = 18, color = headerColor }),
			ui.label({ text = headerText, fontSize = 22, fontWeight = "bold", color = headerColor }),
		}),
	}

	if status == "connected" and snap ~= nil and type(snap.agents) == "table" then
		local names = {}
		for name in pairs(snap.agents) do
			table.insert(names, name)
		end
		table.sort(names)

		for _, name in ipairs(names) do
			local a = snap.agents[name]
			local color = a.active > 0 and COLOR_ACTIVE or COLOR_IDLE
			if a.total > 0 then
				table.insert(children, ui.row({ gap = 8, align = "center" }, {
					ui.glyph({ name = GLYPH_IDLE, size = 8, color = color }),
					ui.label({ text = name, flexGrow = 1 }),
					ui.label({ text = string.format("%d/%d", a.active, a.total), color = color }),
				}))
			end
		end
	end

	desktopWidget.render(ui.column({ gap = 6, padding = 10 }, children))
end

state.watch("snapshot", render)
state.watch("status", render)
render()