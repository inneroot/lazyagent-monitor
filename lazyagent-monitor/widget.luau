-- lazyagent-monitor bar widget
--
-- Renders the aggregated snapshot published by the bridge service through
-- noctalia.state. No HTTP here - the widget only reads shared state.

local state = noctalia.state

local COLOR_ACTIVE = "#22c55e"
local COLOR_IDLE = "#8a8f98"
local COLOR_DOWN = "#d97706" -- amber: stream broken

local GLYPH_ACTIVE = "activity"
local GLYPH_IDLE = "circle"
local GLYPH_DOWN = "alert-circle"
local GLYPH_LOADER = "loader"

local function setStatus(glyph, glyphColor, text, color)
	barWidget.setGlyph(glyph)
	barWidget.setGlyphColor(glyphColor)
	barWidget.setText(text)
	barWidget.setColor(color)
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

local function renderIdle()
	setStatus(GLYPH_IDLE, COLOR_IDLE, "\u{2014}", COLOR_IDLE) -- no data yet
	barWidget.setTooltip({ "lazyagent", tr("widget.connecting") })
end

local function renderSnapshot(snap)
	if snap == nil or type(snap) ~= "table" or snap.stats == nil then
		return
	end
	local stats = snap.stats
	local active = stats.active > 0

	setStatus(
		active and GLYPH_ACTIVE or GLYPH_IDLE,
		active and COLOR_ACTIVE or COLOR_IDLE,
		string.format("%d/%d", stats.active, stats.total),
		active and COLOR_ACTIVE or COLOR_IDLE
	)

	local names = {}
	for name in pairs(snap.agents or {}) do
		table.insert(names, name)
	end
	table.sort(names)

	local rows = {}
	if #names == 0 then
		rows = { { tr("widget.sessions"), tr("widget.none") } }
	else
		for _, name in ipairs(names) do
			local a = snap.agents[name]
			table.insert(rows, { name, string.format("%d/%d %s", a.active, a.total, tr("widget.active")) })
		end
	end
	barWidget.setTooltip(rows)
end

local function renderStatus(statusValue)
	if statusValue == "disconnected" then
		if noctalia.nowMs() < pendingStartUntilMs then
			return -- in the grace window after a start; keep "starting…"
		end
		setStatus(GLYPH_DOWN, COLOR_DOWN, "?", COLOR_DOWN)
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
	setStatus(GLYPH_LOADER, COLOR_IDLE, tr("widget.checking"), COLOR_IDLE)
	noctalia.processMatches(function(matched)
		if matched then
			-- Running → STOP. runAsync gives no PID, so kill by pattern.
			pendingStartUntilMs = 0
			local ok = noctalia.runAsync({ "pkill", "-f", "lazyagent --api" })
			if ok then
				setStatus(GLYPH_LOADER, COLOR_IDLE, tr("widget.stopping"), COLOR_IDLE)
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
			setStatus(GLYPH_LOADER, COLOR_ACTIVE, tr("widget.starting"), COLOR_ACTIVE)
			barWidget.setTooltip({ "lazyagent", tr("widget.tooltip_starting") })
		else
			noctalia.notifyError("lazyagent-monitor", tr("widget.start_failed", { bin = bin }))
			renderStatus(state.get("status"))
		end
	end, "lazyagent")
end
