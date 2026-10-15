-- lazyagent-monitor bridge service
--
-- Connects to the lazyagent SSE stream, parses `update` events, deduplicates
-- heartbeats, and publishes a compact snapshot via noctalia.state for the
-- bar widget. Services and widgets run in isolated VMs, so noctalia.state is
-- the only channel between them.

local BASE_URL = "http://127.0.0.1:7421"
local RECONNECT_DELAY_MS = 5000
local AUTH_RETRY_DELAY_MS = 30000
local AUTH_NOTIFY_INTERVAL_MS = 60000
local CONFIG_PATH = "~/.config/lazyagent/config.json"

local state = noctalia.state

local stream = nil
local resolving = false
local currentToken = nil
local lastFingerprint = nil
local nextReconnectMs = 0
local lastAuthNoticeMs = 0
local publishedCount = 0
local skippedCount = 0

noctalia.setUpdateInterval(1000)

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function now()
	return noctalia.nowMs()
end

local function log(msg)
	noctalia.log("lazyagent-monitor: " .. msg)
end

local function notifyAuthError()
	local t = now()
	if t - lastAuthNoticeMs >= AUTH_NOTIFY_INTERVAL_MS then
		lastAuthNoticeMs = t
		noctalia.notifyError(
			"lazyagent-monitor",
			"Could not authenticate to the lazyagent API (401 or missing token). "
				.. "Check `lazyagent passphrase` and the plugin token setting."
		)
	end
end

-- Parse the 43-char base64url token from `lazyagent passphrase --show` output.
-- Output looks like:
--   gWxXFwhz_...0
--   (passphrase source: /home/inner/.config/lazyagent/config.json)
local function parseTokenFromStdout(stdout)
	if type(stdout) ~= "string" then
		return nil
	end
	for line in stdout:gmatch("[^\r\n]+") do
		line = line:match("^%s*(.-)%s*$")
		if line:match("^[%w_-]{40,64}$") then
			return line
		end
	end
	return nil
end

-- Future-compatible: use bearer_token from config.json if lazyagent ever
-- stores it there.
local function readTokenFromConfigFile()
	local path = noctalia.expandPath(CONFIG_PATH)
	local raw = noctalia.readFile(path)
	if raw == nil then
		return nil
	end
	local ok, data = pcall(noctalia.json.decode, raw)
	if ok and type(data) == "table" and type(data.bearer_token) == "string" and data.bearer_token ~= "" then
		return data.bearer_token
	end
	return nil
end

-- Token resolution order:
--   1. plugin setting "token" (explicit, wins)
--   2. `lazyagent passphrase --show` (subcommand works without the server)
--   3. bearer_token field in config.json (future-compatible fallback)
local function resolveToken(onToken)
	local token = noctalia.getConfig("token")
	if type(token) == "string" and token ~= "" then
		currentToken = token
		onToken(token)
		return
	end

	local bin = noctalia.getConfig("lazyagent_bin")
	if type(bin) ~= "string" or bin == "" then
		bin = "lazyagent"
	end

	local started = noctalia.runAsync({ bin, "passphrase", "--show" }, function(result)
		local t = parseTokenFromStdout(result.stdout)
		if t == nil then
			t = readTokenFromConfigFile()
		end
		if t ~= nil then
			currentToken = t
			onToken(t)
		else
			log("token resolution failed (" .. bin .. "): "
				.. tostring(result.exitCode) .. " " .. tostring(result.stderr))
			notifyAuthError()
			resolving = false
			nextReconnectMs = now() + AUTH_RETRY_DELAY_MS
		end
	end)

	if not started then
		-- runAsync queue full; retry like a normal reconnect
		resolving = false
		nextReconnectMs = now() + RECONNECT_DELAY_MS
	end
end

----------------------------------------------------------------------------
-- SSE stream
----------------------------------------------------------------------------

local function fingerprint(data)
	local parts = {}
	for _, s in ipairs(data.sessions or {}) do
		table.insert(parts, tostring(s.session_id) .. ":" .. tostring(s.activity) .. ":"
			.. (s.is_active and "1" or "0") .. ":" .. tostring(s.short_name))
	end
	table.sort(parts)
	local st = data.stats or {}
	return table.concat(parts, ";")
		.. "|stats:" .. tostring(st.total_sessions) .. ":" .. tostring(st.active_sessions)
end

local function onLine(line)
	local payload = line:match("^data:%s*(.*)$")
	if payload == nil or payload == "" then
		return -- "event:" lines, comments, keep-alives
	end

	local ok, data = pcall(noctalia.json.decode, payload)
	if not ok or type(data) ~= "table" then
		log("skipping malformed event: " .. payload:sub(1, 120))
		return
	end

	if state.get("status") ~= "connected" then
		state.set("status", "connected")
		log("connected to " .. BASE_URL)
	end

	local fp = fingerprint(data)
	if fp == lastFingerprint then
		skippedCount += 1
		return -- heartbeat with unchanged state; do not republish
	end
	lastFingerprint = fp
	publishedCount += 1

	local sessions = {}
	local agents = {}
	for _, s in ipairs(data.sessions or {}) do
		table.insert(sessions, {
			session_id = tostring(s.session_id),
			agent = tostring(s.agent),
			short_name = tostring(s.short_name),
			activity = tostring(s.activity),
			is_active = s.is_active == true,
			model = s.model ~= nil and tostring(s.model) or "",
			cost_usd = type(s.cost_usd) == "number" and s.cost_usd or 0,
		})
		local a = agents[s.agent] or { total = 0, active = 0, statuses = {} }
		a.total += 1
		local st = tostring(s.activity ~= nil and s.activity or "idle")
		a.statuses[st] = (a.statuses[st] or 0) + 1
		if s.is_active == true then
			a.active += 1
		end
		agents[s.agent] = a
	end

	local st = data.stats or {}
	local total = type(st.total_sessions) == "number" and st.total_sessions or #sessions
	local active = type(st.active_sessions) == "number" and st.active_sessions or 0

	state.set("snapshot", {
		sessions = sessions,
		stats = {
			total = total,
			active = active,
			window_minutes = type(st.window_minutes) == "number" and st.window_minutes or 0,
		},
		agents = agents,
		receivedAtMs = now(),
	})

	log(string.format(
		"published %d/%d (agents: %d; published=%d dedup-skipped=%d)",
		active, total, #sessions, publishedCount, skippedCount
	))
end

local function onClose(result)
	stream = nil
	state.set("status", "disconnected")

	local status = result and result.status or 0
	if status == 401 then
		log("rejected token (401); will re-resolve on reconnect")
		currentToken = nil
		notifyAuthError()
		nextReconnectMs = now() + AUTH_RETRY_DELAY_MS
	else
		log("stream closed (status " .. tostring(status) .. "); reconnecting in 5s")
		nextReconnectMs = now() + RECONNECT_DELAY_MS
	end
end

local function startStream(token)
	if stream ~= nil then
		return
	end
	stream = noctalia.httpStream({ url = BASE_URL .. "/api/events?token=" .. token }, onLine, onClose)
	if stream == nil then
		log("httpStream could not start")
		nextReconnectMs = now() + RECONNECT_DELAY_MS
	end
end

local function connect()
	if stream ~= nil or resolving then
		return
	end
	local token = currentToken or noctalia.getConfig("token")
	if type(token) == "string" and token ~= "" then
		startStream(token)
		return
	end
	resolving = true
	resolveToken(function(resolved)
		resolving = false
		if resolved ~= nil and stream == nil then
			startStream(resolved)
		end
	end)
end

----------------------------------------------------------------------------
-- Entry point
----------------------------------------------------------------------------

state.set("status", "disconnected")
log("bridge started")

function update()
	if stream == nil and resolving == false and now() >= nextReconnectMs then
		nextReconnectMs = now() + RECONNECT_DELAY_MS
		connect()
	end
end
