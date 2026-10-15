--!nonstrict
-- Shared icon helpers for the lazyagent-monitor bar & desktop widgets.
--
-- A widget can show either its built-in per-state glyph (the default, so the
-- plugin keeps its existing state visuals) or a user-configured icon: a fixed
-- glyph or a custom SVG. The pattern mirrors the built-in sysmon widget's
-- `custom_image` + `custom_image_colorize` + `glyph` settings: a custom image
-- wins over a custom glyph, which wins over the per-state glyph.
--
-- SVG recoloring bakes a single fill/stroke color into the SVG source and caches
-- the result to the plugin data dir, because the script image APIs
-- (barWidget.setImage / ui.image) render an image file as-is and cannot tint it
-- on their own. The glyph and role-color paths stay live: the host resolves a
-- palette role such as "primary" at render time, so it follows the theme.

local M = {}

local FALLBACK_ACTIVE = "#22c55e"

local sourceCache = {} -- raw SVG content keyed by source path
local tintCache = {}   -- tinted file path keyed by "<source>|<color>"

local function sanitize(s)
	return (s:gsub("[^%w]", "_"))
end

-- Replaces every color-bearing fill/stroke in an SVG with a single `color` so
-- the icon adopts the given theme color. Non-color values (none, transparent,
-- gradient url(...) references) are left untouched so outline and gradient
-- icons keep their structure. Icons that declare no color at all (a plain black
-- shape, or one that only sets fill on a <style> rule) get a fill stamped on the
-- root <svg> element so they still take the color.
local function tintSvg(source, color)
	local function keep(value)
		local v = value:lower()
		if v == "none" or v == "transparent" or v:match("^%s*url%(") then
			return value
		end
		return color
	end

	local out = source
	out = out:gsub('fill="([^"]*)"', function(v) return 'fill="' .. keep(v) .. '"' end)
	out = out:gsub("fill='([^']*)'", function(v) return "fill='" .. keep(v) .. "'" end)
	out = out:gsub('stroke="([^"]*)"', function(v) return 'stroke="' .. keep(v) .. '"' end)
	out = out:gsub("stroke='([^']*)'", function(v) return "stroke='" .. keep(v) .. "'" end)
	out = out:gsub("fill:%s*(#[0-9a-fA-F]+)", "fill:" .. color)
	out = out:gsub("stroke:%s*(#[0-9a-fA-F]+)", "stroke:" .. color)
	out = out:gsub("currentColor", color)

	local hasTint = out:match('fill="#[0-9a-fA-F]+"') ~= nil
		or out:match('stroke="#[0-9a-fA-F]+"') ~= nil
	if not hasTint then
		out = out:gsub("<svg([^>]*)>", function(attrs)
			return "<svg" .. attrs .. ' fill="' .. color .. '">'
		end, 1)
	end
	return out
end
M.tintSvg = tintSvg

-- Active color as a hex value, for baking into SVGs. Falls back to the plugin's
-- original green if the palette has no "primary" role (never expected).
function M.activeHex()
	return noctalia.getColor("primary") or FALLBACK_ACTIVE
end

-- Returns the path of a copy of `sourcePath` with every color replaced by
-- `color`. The copy is cached in the plugin data dir and reused across renders.
-- Returns nil when the source can't be read or the file can't be written.
function M.tintedPath(sourcePath, color)
	if sourcePath == nil or sourcePath == "" or color == nil then
		return nil
	end
	local key = sourcePath .. "|" .. color
	if tintCache[key] ~= nil then
		return tintCache[key]
	end

	local content = sourceCache[sourcePath]
	if content == nil then
		content = noctalia.readFile(sourcePath)
		sourceCache[sourcePath] = content
	end
	if content == nil then
		return nil
	end

	-- Only tint actual SVG markup. A non-SVG file (e.g. a PNG path typed by the
	-- user) cannot be recolored by string rewriting, so show it as-is.
	if content:lower():find("<svg", 1, true) == nil then
		return sourcePath
	end

	local dir = noctalia.pluginDataDir()
	if dir == nil then
		dir = noctalia.pluginDir()
	end
	if dir == nil then
		return nil
	end

	local name = "icon_" .. sanitize(sourcePath) .. "_" .. sanitize(color) .. ".svg"
	local path = (dir:gsub("/$", "")) .. "/" .. name
	if noctalia.fileExists(path) then
		tintCache[key] = path
		return path
	end

	if noctalia.writeFile(path, tintSvg(content, color)) then
		tintCache[key] = path
		return path
	end
	return nil
end

-- Resolves the user-configured icon from this entry's own settings (icon_glyph,
-- icon_image, icon_colorize) for a state color. Mirrors the sysmon widget's
-- custom-image + custom_image_colorize pattern: a custom image wins over a
-- custom glyph, which wins over the per-state default. Returns nil when the
-- widget should keep its per-state default glyph, otherwise { glyph = name } or
-- { image = path }.
function M.resolveIcon(color)
	local imagePath = noctalia.getConfig("icon_image")
	if type(imagePath) == "string" and imagePath ~= "" then
		if noctalia.getConfig("icon_colorize") then
			-- Tint the SVG with the widget's dynamic color (theme primary when
			-- active), like sysmon's custom_image_colorize.
			local p = M.tintedPath(imagePath, color)
			if p ~= nil then
				return { image = p }
			end
		else
			-- Show the SVG as-is (its own baked-in colors), no tinting.
			return { image = imagePath }
		end
	end
	local glyph = noctalia.getConfig("icon_glyph")
	if type(glyph) == "string" and glyph ~= "" then
		return { glyph = glyph }
	end
	return nil
end

return M