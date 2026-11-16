-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require 'Game'
local Rand = require 'Rand'
local ui = require 'pigui'
local StationView = require 'pigui.views.station-view'
local Lang = require 'Lang'
local Format = require 'Format'
local Character = require 'Character'
local PiGuiFace = require 'pigui.libs.face'
local EncryptedText = require 'pigui.libs.encrypted-text'
local Cartography = require 'modules.Cartography.Cartography'
require 'modules.Cartography.Missions'

local l = Lang.GetResource("ui-core")

local colors = ui.theme.colors
local icons = ui.theme.icons
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer

local commsChildFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }

local face = nil
local stationSeed = false
local lastSaleBanner = nil

local INTRO_TEXT = "Universal Cartographics encrypted telemetry uplink established. All stellar discoveries, orbital surveys, and detailed surface surveys from uncharted systems are eligible for immediate credit payout."
local commsText = EncryptedText.New(INTRO_TEXT, 0.50)

local widgetSizes = ui.rescaleUI({
	itemSpacing = Vector2(4, 7),
	faceSize = Vector2(460, 440),
	buttonSize = Vector2(180, 32),
	sellAllSize = Vector2(260, 36),
	tablePadding = Vector2(10, 4),
	barHeight = Vector2(0, 2),
}, Vector2(1920, 1080))

local function drawUniversalCartographics()
	local now = ui.getTime()
	local displayIntro = commsText:get(now)

	ui.withStyleVars({ ItemSpacing = widgetSizes.itemSpacing }, function()
		local padding = ui.getWindowPadding()
		local infoColumnWidth = ui.getContentRegion().x - widgetSizes.faceSize.x - padding.x * 2

		ui.child("CartographyPanel", Vector2(infoColumnWidth, 0), nil, commsChildFlags, function()
			commsText:renderCommsHeader(now, "UC-SIG // AES-512")

			ui.withFont(orbiteer.heading, function()
				ui.text("UNIVERSAL CARTOGRAPHICS")
				if lastSaleBanner then
					ui.sameLine(0, 18)
					ui.withFont(pionillium.body, function()
						ui.textColored(colors.econMajorImport or colors.uiPrimaryLight, "• " .. lastSaleBanner)
					end)
				end
			end)
			ui.spacing()

			ui.withFont(pionillium.body, function()
				ui.textWrapped(displayIntro)
			end)
			ui.spacing()

			local stats = Cartography.GetStats()
			local unsoldList = Cartography.GetUnsoldList()
			local totalUnsold, eligibleUnsold = Cartography.GetTotalUnsoldValue()

			ui.withFont(pionillium.details, function()
				ui.textColored(colors.fontDim, string.format(
					"Systems Discovered: %d   |   Orbital Scans: %d   |   Surface Scans: %d   |   Lifetime Earnings: %s",
					stats.systemsDiscovered or 0,
					stats.orbitalScans or 0,
					stats.surfaceScans or 0,
					Format.Money(stats.totalEarned or 0)
				))
			end)

			ui.spacing()
			ui.separator()
			ui.spacing()

			-- Top Action Bar: Total Unsold + Eligible + Sell All
			ui.withFont(orbiteer.medium, function()
				if eligibleUnsold < totalUnsold then
					ui.text(string.format("Available Cartographic Data: %s (Eligible: %s)", Format.Money(totalUnsold), Format.Money(eligibleUnsold)))
				else
					ui.text("Available Cartographic Data: " .. Format.Money(totalUnsold))
				end
			end)

			if eligibleUnsold > 0 then
				ui.sameLine()
				local avail = ui.getContentRegion().x
				if avail > widgetSizes.sellAllSize.x then
					ui.addCursorPos(Vector2(avail - widgetSizes.sellAllSize.x, 0))
				end
				if ui.button("Sell Eligible Data (" .. Format.Money(eligibleUnsold) .. ")", widgetSizes.sellAllSize) then
					local earned, soldItems = Cartography.SellAll()
					if earned > 0 then
						lastSaleBanner = string.format("Signature verified. Transmitted %d eligible system survey(s) for %s.", #soldItems, Format.Money(earned))
						animStartTime = ui.getTime()
						ui.playSfx("OK")
					end
				end
			elseif totalUnsold > 0 then
				ui.sameLine()
				local avail = ui.getContentRegion().x
				if avail > widgetSizes.sellAllSize.x then
					ui.addCursorPos(Vector2(avail - widgetSizes.sellAllSize.x, 0))
				end
				ui.withStyleColors({ Button = ui.theme.buttonColors.disabled.normal, Text = colors.fontDim }, function()
					ui.button("Data Within 10 ly (Ineligible)", widgetSizes.sellAllSize)
				end)
			end

			ui.spacing()

			-- Scrollable list of unsold systems
			ui.child("CartographyDataList", Vector2(0, 0), function()
				if #unsoldList == 0 then
					ui.spacing()
					ui.textColored(colors.fontDim, "No unsold cartographic data stored on ship computer.")
					ui.textColored(colors.fontDim, "Equip a System Discovery Scanner and planetary scanners to survey uncharted systems.")
					return
				end

				for _, sys in ipairs(unsoldList) do
					ui.withStyleVars({ CellPadding = widgetSizes.tablePadding }, function()
						ui.separator()
						ui.withFont(pionillium.heading, function()
							ui.text(sys.name)
							ui.sameLine()
							ui.textColored(colors.uiPrimaryLight, " (" .. Format.Money(sys.totalPay) .. ")")
							ui.sameLine()
							ui.withFont(pionillium.details, function()
								local distStr = string.format("[%.1f ly]", sys.distance or 0)
								if sys.isEligibleDistance then
									ui.textColored(colors.econProfit, distStr)
								else
									ui.textColored(colors.alertYellow, distStr .. " (Min 10 ly required)")
								end
							end)
							if sys.isKnownSystem then
								ui.sameLine()
								ui.withFont(pionillium.details, function()
									ui.textColored(colors.fontDim, "[Known System - 20%]")
								end)
							end
						end)

						ui.sameLine()
						local avail = ui.getContentRegion().x
						if avail > widgetSizes.buttonSize.x then
							ui.addCursorPos(Vector2(avail - widgetSizes.buttonSize.x, 0))
						end
						if sys.isEligibleDistance then
							if ui.button("Sell System##" .. sys.key, widgetSizes.buttonSize) then
								local earned, msg = Cartography.SellSystem(sys.key)
								if earned > 0 then
									lastSaleBanner = "Verified & sold " .. sys.name .. " survey data for " .. Format.Money(earned) .. "."
									animStartTime = ui.getTime()
									ui.playSfx("OK")
								else
									lastSaleBanner = msg or "Unable to sell system data."
								end
							end
						else
							ui.withStyleColors({ Button = ui.theme.buttonColors.disabled.normal, Text = colors.fontDim }, function()
								ui.button("Too Close (<10 ly)##" .. sys.key, widgetSizes.buttonSize)
							end)
						end

						if ui.beginTable("CartoSys_" .. sys.key, 3, { "BordersInnerV" }) then
							ui.tableSetupColumn("Item", "WidthStretch")
							ui.tableSetupColumn("Survey", "WidthFixed")
							ui.tableSetupColumn("Payout", "WidthFixed")

							if sys.discovered then
								ui.tableNextRow()
								ui.tableNextColumn()
								ui.text("System Stellar Discovery")
								ui.tableNextColumn()
								ui.textColored(colors.fontDim, string.format("%d bodies", sys.scannableCount))
								ui.tableNextColumn()
								ui.text(Format.Money(sys.discoveryPay))
							end

							for _, b in ipairs(sys.bodies) do
								ui.tableNextRow()
								ui.tableNextColumn()
								ui.text(b.name)
								ui.tableNextColumn()
								local tags = {}
								if b.orbital then table.insert(tags, "Orbital") end
								if b.surface then table.insert(tags, "Surface Survey") end
								if b.isRescan then
									table.insert(tags, "Rescan (10%)")
								elseif b.isKnownSystem then
									table.insert(tags, "Known (20%)")
								end
								local col = (b.isRescan or b.isKnownSystem) and colors.fontDim or colors.uiPrimaryLight
								ui.textColored(col, table.concat(tags, " • "))
								ui.tableNextColumn()
								ui.text(Format.Money(b.totalPay))
							end

							if sys.isFullSystem and sys.fullSystemBonus > 0 then
								ui.tableNextRow()
								ui.tableNextColumn()
								ui.textColored(colors.econMajorImport or colors.uiPrimaryLight, "Full System Survey Bonus (+25%)")
								ui.tableNextColumn()
								ui.textColored(colors.econMajorImport or colors.uiPrimaryLight, "Complete")
								ui.tableNextColumn()
								ui.textColored(colors.econMajorImport or colors.uiPrimaryLight, Format.Money(sys.fullSystemBonus))
							end

							ui.endTable()
						end
					end)
					ui.spacing()
				end
			end)
		end)

		ui.sameLine(0, padding.x * 2)
		ui.child("CartographyContactPane", Vector2(0, 0), nil, commsChildFlags, function()
			if face ~= nil then face:render() end
		end)
	end)
end

StationView:registerView({
	id = "universalCartographics",
	name = "Universal Cartographics",
	icon = icons.galaxy_map,
	securityMode = "encryption",
	showView = true,
	draw = drawUniversalCartographics,
	refresh = function(self)
		commsText:reset()
		lastSaleBanner = nil
		local station = Game.player:GetDockedWith()
		if station then
			if stationSeed ~= station.seed then
				stationSeed = station.seed
				local rand = Rand.New(station.seed .. "-cartography")
				face = PiGuiFace.New(
					Character.New({ title = "CARTOGRAPHIC ARCHIVIST", org = "UNIVERSAL CARTOGRAPHICS", role = "cartography" }, rand),
					{ itemSpacing = widgetSizes.itemSpacing }
				)
			end
		end
	end,
	debugReload = function()
		package.reimport()
	end
})

