-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

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

local function displayShipLights()
	if Game.CurrentView() ~= "WorldView" or not ui.shouldDrawUI() then return end
	if Game.InHyperspace() then return end

	local player = Game.player
	if not player or not player.GetBeaconsEnabled then return end
	local flightState = player:GetFlightState()
	if flightState == "HYPERSPACE" or flightState == "SUPERCRUISE" then return end
	if player.IsSupercruiseActive and player:IsSupercruiseActive() then return end

	local beaconsOn = player:GetBeaconsEnabled()
	local forwardOn = player:GetForwardLightsEnabled()
	local landingOn = player:GetLandingLightsEnabled()

	local spacing = ui.getItemSpacing()
	local winPad = ui.getWindowPadding()

	local totalW = buttonSize.x * 3 + spacing.x * 2 + winPad.x * 2
	local totalH = buttonSize.y + winPad.y * 2
	local bottomOffset = (ui.planetaryInfoHeight or 0) + ui.rescaleUI(2)

	ui.setNextWindowSize(Vector2(totalW, totalH), "Always")
	ui.setNextWindowPos(Vector2(ui.screenWidth, ui.screenHeight - bottomOffset), "Always", Vector2(1, 1))

	ui.window("ShipLightsBar", flags, function()
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
	end)
end

ui.registerModule("world-view", { id = "ship-lights", draw = displayShipLights, debugReload = true })

return {}
