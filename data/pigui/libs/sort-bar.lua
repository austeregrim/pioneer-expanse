-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui = require 'pigui'

local icons = ui.theme.icons
local styles = ui.theme.styles
local buttonColors = ui.theme.buttonColors
local Vector2 = _G.Vector2

local SortBar = {}

--- Render a standardized row of sort buttons matching the Equipment Outfitter style.
---@param tableId string Unique ImGui table ID
---@param keys { id: string, label: string, defaultDir?: integer, tooltip?: string }[]
---@param sortId string? Active sort key ID
---@param sortDir integer? Active sort direction (1 = ascending, -1 = descending)
---@param opts { allowReset?: boolean, font?: table }?
---@return string? newSortId
---@return integer? newSortDir
---@return boolean changed
function SortBar.draw(tableId, keys, sortId, sortDir, opts)
	opts = opts or {}
	local font = opts.font or ui.fonts.pionillium.details
	local allowReset = opts.allowReset or false

	local newSortId, newSortDir, changed = sortId, sortDir, false

	ui.withFont(font, function()
		ui.withStyleVars({ FrameRounding = 4 }, function()
			if ui.beginTable(tableId, #keys) then
				ui.tableNextRow()

				for i, key in ipairs(keys) do
					ui.tableSetColumnIndex(i - 1)

					local active = (sortId == key.id) and sortDir or nil
					local variant = active and buttonColors.dark or buttonColors.deselected
					local sortIcon = ""
					if active then
						sortIcon = (active > 0 and ui.get_icon_glyph(icons.chevron_up) or ui.get_icon_glyph(icons.chevron_down)) .. " "
					end

					local label = sortIcon .. key.label .. "##" .. tableId .. "_" .. key.id
					local clicked = ui.button(label, Vector2(ui.getContentRegion().x, 0), variant, key.tooltip, styles.IconButtonPadding)

					if clicked then
						local defDir = key.defaultDir or 1
						if not active then
							newSortId, newSortDir = key.id, defDir
						elseif allowReset then
							if active == defDir then
								newSortId, newSortDir = key.id, -defDir
							else
								newSortId, newSortDir = nil, nil
							end
						else
							newSortId, newSortDir = key.id, -active
						end
						changed = true
					end
				end

				ui.endTable()
			end
		end)
	end)

	return newSortId, newSortDir, changed
end

--- Strict weak ordering comparator helper for table.sort.
--- Returns boolean when a and b differ, or nil when equal so callers can chain tie-breakers.
---@param a any
---@param b any
---@param dir integer? 1 for ascending (default), -1 for descending
---@return boolean?
function SortBar.compareValues(a, b, dir)
	if a == b then return nil end
	if a == nil then return false end
	if b == nil then return true end

	local d = dir or 1
	if type(a) == "string" or type(b) == "string" then
		local sa = string.lower(tostring(a))
		local sb = string.lower(tostring(b))
		if sa == sb then return nil end
		if d < 0 then
			return sa > sb
		else
			return sa < sb
		end
	end

	if d < 0 then
		return a > b
	else
		return a < b
	end
end

return SortBar
