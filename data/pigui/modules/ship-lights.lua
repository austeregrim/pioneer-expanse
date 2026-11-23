-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event = require 'Event'
local Game = require 'Game'
local Vector2 = _G.Vector2

local ui = require 'pigui'

local icons = ui.theme.icons
local sc = ui.theme.styleColors
local buttonSize = ui.theme.styles.MainButtonSize

local flags = ui.WindowFlags { "NoDecoration", "NoMove", "NoSavedSettings", "NoFocusOnAppearing", "NoBringToFrontOnFocus", "NoBackground" }

local offVariant = {
	normal  = sc.panel_800:opacity(0.82),
	hovered = sc.primary_700:opacity(0.92),
	active  = sc.primary_500
}

local beaconOnVariant = {
	normal  = sc.danger_500:opacity(0.88),
	hovered = sc.danger_300:opacity(0.95),
	active  = sc.warning_300
}

local forwardOnVariant = {
	normal  = sc.accent_600:opacity(0.90),
	hovered = sc.accent_400:opacity(0.96),
	active  = sc.accent_200
}

local landingOnVariant = {
	normal  = sc.warning_500:opacity(0.88),
	hovered = sc.warning_300:opacity(0.95),
	active  = sc.warning_100
}

local transponderOnVariant = {
	normal  = sc.success_500 and sc.success_500:opacity(0.88) or sc.accent_600:opacity(0.90),
	hovered = sc.success_300 and sc.success_300:opacity(0.95) or sc.accent_400:opacity(0.96),
	active  = sc.accent_200
}

local transponderWarnActive = false
Event.Register("onPoliceTransponderWarning", function()
	transponderWarnActive = true
end)
Event.Register("onPoliceTransponderWarningCleared", function()
	transponderWarnActive = false
end)
Event.Register("onLeaveSystem", function()
	transponderWarnActive = false
end)
Event.Register("onGameEnd", function()
	transponderWarnActive = false
end)

local function displayShipLights()
	if Game.CurrentView() ~= "WorldView" or not ui.shouldDrawUI() then return end
	if Game.InHyperspace() then return end

	local player = Game.player
	if not player or not player.GetBeaconsEnabled then return end
	local flightState = player:GetFlightState()
	if flightState == "HYPERSPACE" then return end

	local inSupercruise = (flightState == "SUPERCRUISE") or (player.IsSupercruiseActive and player:IsSupercruiseActive())
	local beaconsOn = player:GetBeaconsEnabled()
	local forwardOn = player:GetForwardLightsEnabled()
	local landingOn = player:GetLandingLightsEnabled()
	local xpActive = player.GetTransponder and player:GetTransponder() or true
	local xpWarming = player.IsTransponderWarmingUp and player:IsTransponderWarmingUp() or false
	local xpRequested = player.GetTransponderRequested and player:GetTransponderRequested() or xpActive

	if xpActive then
		transponderWarnActive = false
	end

	local spacing = ui.getItemSpacing()
	local winPad = ui.getWindowPadding()

	local numButtons = inSupercruise and 1 or 4
	local totalW = buttonSize.x * numButtons + spacing.x * (numButtons - 1) + winPad.x * 2
	local totalH = buttonSize.y + winPad.y * 2
	local bottomOffset = (ui.planetaryInfoHeight or 0) + ui.rescaleUI(2)

	ui.setNextWindowSize(Vector2(totalW, totalH), "Always")
	ui.setNextWindowPos(Vector2(ui.screenWidth, ui.screenHeight - bottomOffset), "Always", Vector2(1, 1))

	ui.window("ShipLightsBar", flags, function()
		if not inSupercruise then
			if ui.iconButton("##ship_lights_bcn", icons.lights_beacon,
				beaconsOn and "Beacon Lights: ON (Click to disable)" or "Beacon Lights: OFF (Click to enable)",
				beaconsOn and beaconOnVariant or offVariant, buttonSize) then
				player:ToggleBeacons()
				ui.playSfx("OK")
			end
			ui.sameLine()

			if ui.iconButton("##ship_lights_fwd", icons.lights_forward,
				forwardOn and "Forward Lights: ON (Click to disable)" or "Forward Lights: OFF (Click to enable)",
				forwardOn and forwardOnVariant or offVariant, buttonSize) then
				player:ToggleForwardLights()
				ui.playSfx("OK")
			end
			ui.sameLine()

			if ui.iconButton("##ship_lights_ldg", icons.lights_landing,
				landingOn and "Landing Lights: ON (Click to disable)" or "Landing Lights: OFF (Click to enable)",
				landingOn and landingOnVariant or offVariant, buttonSize) then
				player:ToggleLandingLights()
				ui.playSfx("OK")
			end
			ui.sameLine()
		end

		local xpVariant = xpActive and transponderOnVariant
			or (xpWarming and landingOnVariant or (transponderWarnActive and beaconOnVariant or offVariant))
		local xpTip = xpActive and "Transponder: ON [\\] (Click to run dark)"
			or (xpWarming and "Transponder: INITIALIZING..." or "Transponder: OFF — RUNNING DARK [\\] (Click to broadcast)")
		if ui.iconButton("##ship_transponder", icons.broadcast, xpTip, xpVariant, buttonSize) then
			if player.ToggleTransponder then
				player:ToggleTransponder()
				ui.playSfx("OK")
			end
		end
	end)
end

ui.registerModule("world-view", { id = "ship-lights", draw = displayShipLights, debugReload = true })

return {}
