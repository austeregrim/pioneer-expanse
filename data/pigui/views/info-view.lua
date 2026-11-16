-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require 'Game'
local ui = require 'pigui'
local TabView = require 'pigui.views.tab-view'

local infoView = TabView.New("InfoView")
infoView.windowPadding = ui.rescaleUI(Vector2(12, 12), Vector2(1920, 1080))

local useWindowPadding = ui.ChildFlags { 'AlwaysUseWindowPadding' }
function infoView:renderTab(tabFn)
	local panelStyleColors = {
		WindowBg = ui.theme.styleColors.panel_900 or ui.theme.colors.windowBackground,
		Border = ui.theme.styleColors.primary_500 or ui.theme.colors.windowFrame,
	}
	ui.withStyleColors(panelStyleColors, function()
		ui.withStyleVars({WindowPadding = self.windowPadding}, function()
			ui.child("InfoContainer", Vector2(0, 0), nil, useWindowPadding, tabFn)
		end)
	end)
end

ui.registerHandler("InfoView", function(delta_t, refresh)
	infoView:renderTabView(refresh)

	if ui.escapeKeyReleased() then
		Game.SetView("WorldView")
	end
end)

return infoView
