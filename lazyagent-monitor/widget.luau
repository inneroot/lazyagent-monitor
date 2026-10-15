-- lazyagent-monitor bar widget
--
-- Renders the aggregated snapshot published by the bridge service through
-- noctalia.state. No HTTP here - the widget only reads shared state.

local state = noctalia.state

local COLOR_ACTIVE = "#22c55e"
local COLOR_IDLE = "#8a8f98"

local function renderIdle()
	barWidget.setText("\u{2014}") -- em dash: no data yet
	barWidget.setColor(COLOR_IDLE)
	barWidget.setTooltip({ "lazyagent", "connecting…" })
end

local function renderSnapshot(snap)
	if snap == nil or type(snap) ~= "table" or snap.stats == nil then
		return
	end
	local stats = snap.stats

	barWidget.setText(string.format("%d/%d", stats.active, stats.total))
	barWidget.setColor(stats.active > 0 and COLOR_ACTIVE or COLOR_IDLE)

	local names = {}
	for name in pairs(snap.agents or {}) do
		table.insert(names, name)
	end
	table.sort(names)

	local rows = {}
	if #names == 0 then
		rows = { { "sessions", "none" } }
	else
		for _, name in ipairs(names) do
			local a = snap.agents[name]
			table.insert(rows, { name, a.active .. "/" .. a.total .. " active" })
		end
	end
	table.insert(rows, { "window", stats.window_minutes .. " min" })
	barWidget.setTooltip(rows)
end

local function renderStatus(statusValue)
	if statusValue == "disconnected" then
		barWidget.setText("?")
		barWidget.setColor(COLOR_IDLE)
		barWidget.setTooltip({ "lazyagent", "disconnected, reconnecting…" })
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
