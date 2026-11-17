-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui = require 'pigui'
local StationView = require 'pigui.views.station-view'
local AutoSave    = require 'modules.AutoSave.AutoSave'
local PlayerState = require 'PlayerState'
local Insurance   = require 'modules.Insurance.Insurance'
local TaxAuthority = require 'modules.Economy.TaxAuthority'

local Game = require 'Game'
local Rand = require 'Rand'
local Format = require 'Format'
local ShipDef = require 'ShipDef'
local Character = require 'Character'
local Comms = require 'Comms'
local Space = require 'Space'

local PiGuiFace = require 'pigui.libs.face'
local textTable = require 'pigui.libs.text-table'
local ModalWindow = require 'pigui.libs.modal-win'

local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local colors = ui.theme.colors
local icons = ui.theme.icons

local Lang = require 'Lang'
local l = Lang.GetResource("ui-core")
local Vector2 = _G.Vector2

local rescaleVector = ui.rescaleUI(Vector2(1, 1), Vector2(1920, 1080), true)
local widgetSizes = ui.rescaleUI({
	itemSpacing = Vector2(4, 7),
	faceSize = Vector2(460, 440),
	buttonSizeBase = Vector2(64, 40),
}, Vector2(1920, 1080))

widgetSizes.itemSpacing = Vector2(math.ceil(widgetSizes.itemSpacing.x), math.ceil(widgetSizes.itemSpacing.y))
widgetSizes.buttonLaunchSize = Vector2(widgetSizes.buttonSizeBase.x*5, widgetSizes.buttonSizeBase.y)

local commsChildFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }

local face = nil
local stationSeed = false
local shipDef

local taxStatusBanner = nil
local taxBannerColor = colors.uiPrimaryLight
local residencyStatusBanner = nil
local residencyBannerColor = colors.uiPrimaryLight

local popupMsg = ''
local popup = ModalWindow.New('lobbyPopup', function(self)
	ui.text(popupMsg)
	ui.dummy(Vector2((ui.getContentRegion().x - 100*rescaleVector.x) / 2, 0))
	ui.sameLine()
	if ui.button("OK", Vector2(100*rescaleVector.x, 0)) then
		self:close()
	end
end)

local requestLaunch = function (station)
	local _, fine = PlayerState.GetCrimeOutstanding()
	local nearbyTraffic = station:GetNearbyTraffic(50000) -- ships within 50km of station

	if not Game.player:HasCorrectCrew() then
		Comms.ImportantMessage(l.LAUNCH_PERMISSION_DENIED_CREW, station.label)
		popupMsg = l.LAUNCH_PERMISSION_DENIED_CREW
		popup:open()
		return
	elseif fine > 0 then
		Comms.ImportantMessage(l.LAUNCH_PERMISSION_DENIED_FINED, station.label)
		popupMsg = l.LAUNCH_PERMISSION_DENIED_FINED
		popup:open()
		return
	end

	AutoSave.Save()

	if not Game.player:Undock() then
		Comms.ImportantMessage(l.LAUNCH_PERMISSION_DENIED_BUSY, station.label)
		popupMsg = l.LAUNCH_PERMISSION_DENIED_BUSY
		popup:open()
	else
		if popup.isOpen or popup.stackIdx ~= -1 then
			popup:close()
		end
		if nearbyTraffic - (station.numShipsDocked) > 0 then -- station radar picking up stuff nearby
			Comms.Message(l.LAUNCH_PERMISSION_GRANTED_WATCH_TRAFFIC, station.label)
		elseif station.numDocks - (station.numShipsDocked + 1) < station.numShipsDocked * 0.2 then -- busy station, pads almost full
			Comms.Message(l.LAUNCH_PERMISSION_GRANTED_DEPART_QUICK, station.label)
		else
			Comms.Message(l.LAUNCH_PERMISSION_GRANTED, station.label)
		end
		Game.SwitchView()
	end
end

local function drawCivilAdministrationSection(station)
	local resInfo = TaxAuthority.GetResidencyInfo()
	local assess = TaxAuthority.GetTaxAssessment()
	local playerMoney = PlayerState.GetMoney()

	ui.spacing()
	ui.separator()
	ui.spacing()

	-- Header
	ui.withFont(orbiteer.medlarge, function()
		ui.textColored(colors.uiPrimaryLight, "INTERSTELLAR REVENUE SERVICE & CIVIL ADMINISTRATION")
	end)
	ui.spacing()

	local availWidth = ui.getContentRegion().x
	local col0Width = math.max(380 * rescaleVector.x, math.floor(availWidth * 0.50))
	ui.columns(2, "LobbyCivilTaxCols", false)
	ui.setColumnWidth(0, col0Width)

	-- Left Column: Residency & Civic Allegiance
	ui.group(function()
		ui.withFont(orbiteer.medlarge, function()
			ui.textColored(colors.uiPrimaryLight, "CIVIL RESIDENCY & JURISDICTION")
		end)
		ui.spacing()

		local residencyStatusStr
		if resInfo.isResident then
			if resInfo.canChange then
				residencyStatusStr = "Term Expired (Eligible to Transfer)"
			else
				residencyStatusStr = string.format("Active (Locked: %d days remaining)", resInfo.remainingDays)
			end
		else
			residencyStatusStr = "Stateless / Transient Pilot"
		end

		local rateStr = string.format("%.1f%% (Faction %.1f%% + System %+.1f%%)",
			resInfo.effectiveRate * 100,
			resInfo.baselineRate * 100,
			resInfo.systemModifier * 100)

		textTable.draw({
			{ "Current Port of Call", (station and station.label) or "Unknown Station" },
			{ "Registered Home Station", resInfo.homeStationName },
			{ "Home System", resInfo.homeSystemName },
			{ "Governing Faction", resInfo.homeFaction },
			{ "Residency Status", residencyStatusStr },
			{ "Effective Tax Rate", rateStr },
		})

		ui.spacing()
		if resInfo.isResident and not resInfo.canChange then
			ui.textColored(colors.fontDim, string.format("90-Day Residency Commitment: %d / %d Days", resInfo.termDaysTotal - resInfo.remainingDays, resInfo.termDaysTotal))
			local gaugePos = ui.getCursorScreenPos()
			local gaugeHeight = 16 * rescaleVector.y
			local gaugeWidth = ui.getContentRegion().x
			ui.gauge(gaugePos, resInfo.progress * 100, '', "%d%% Term Elapsed",
				0, 100, icons.station or icons.info, false, colors.gaugeEquipmentMarket, '',
				gaugeWidth, gaugeHeight, pionillium.details)
			ui.dummy(Vector2(0, gaugeHeight + 8 * rescaleVector.y))
		end

		ui.spacing()
		ui.withFont(orbiteer.medlarge, function()
			ui.textColored(colors.fontDim, "RESIDENCY PRIVILEGES & INCENTIVES")
		end)
		ui.bulletText("Subsidized Ship Insurance: 40% reduction on rebuy deductible (3% vs 5%).")
		ui.bulletText("Academic Cartography Credit: +10% scan value & 25% tax rebate at Home Port.")
		ui.bulletText("Faction Legal Standing: System defense patrol protection in core lanes.")

		ui.spacing()
		if station then
			local isCurrentHome = (resInfo.isResident and resInfo.homeStationName == station.label)
			local actionBtnSize = Vector2(ui.getContentRegion().x, 36 * rescaleVector.y)
			if isCurrentHome then
				ui.withStyleColors({ Button = ui.theme.buttonColors.disabled.normal, Text = colors.fontDim }, function()
					ui.button("CURRENT REGISTERED HOME STATION##lobbyRes", actionBtnSize)
				end)
			elseif not resInfo.canChange then
				ui.withStyleColors({ Button = ui.theme.buttonColors.disabled.normal, Text = colors.fontDim }, function()
					ui.button(string.format("RESIDENCY LOCKED (%d DAYS REMAINING)##lobbyRes", resInfo.remainingDays), actionBtnSize)
				end)
			else
				local regLabel = string.format("REGISTER RESIDENCY AT %s (90-DAY TERM)##lobbyRes", string.upper(station.label))
				if ui.button(regLabel, actionBtnSize) then
					local ok, msg = TaxAuthority.RegisterResidency(station)
					if ok then
						residencyStatusBanner = msg
						residencyBannerColor = colors.econProfit or colors.uiPrimaryLight
						ui.playSfx("OK")
					else
						residencyStatusBanner = msg
						residencyBannerColor = colors.alertRed
					end
				end
			end
		end

		if residencyStatusBanner then
			ui.spacing()
			ui.textColored(residencyBannerColor, residencyStatusBanner)
		end
	end)

	ui.nextColumn()

	-- Right Column: Full Tax Assessment Ledger & Single Payment Button
	ui.group(function()
		ui.withFont(orbiteer.medlarge, function()
			ui.textColored(colors.uiPrimaryLight, "CONSOLIDATED TAX ASSESSMENT")
		end)
		ui.spacing()

		local dueStatusStr
		local dueColor = colors.fontDim
		if assess.isDelinquent then
			dueStatusStr = "DELINQUENT - 5% LATE PENALTY APPLIED"
			dueColor = colors.alertRed
		elseif assess.daysUntilDue > 0 then
			dueStatusStr = string.format("Filing Due in %d In-Game Days", assess.daysUntilDue)
			dueColor = colors.fontDim
		else
			dueStatusStr = "No Assessment Pending"
		end

		textTable.draw({
			{ "Your Liquid Capital", Format.Money(playerMoney) },
			{ "Assessment Filing Status", dueStatusStr },
			{ "Trade Net Capital Gains Tax", Format.Money(assess.breakdown.tradeProfitTax) },
			{ "Civilian BBS Contracts Tax", Format.Money(assess.breakdown.bbsJobsTax) },
			{ "Cartographic Survey Data Tax", Format.Money(assess.breakdown.cartographyTax) },
			{ "Combat & Bounty Earnings", string.format("%s (0%% Tax-Exempt)", Format.Money(assess.breakdown.exemptIncome)) },
			{ "Lottery Windfall Tax Withheld", string.format("%s (30%% Withheld)", Format.Money(assess.breakdown.windfallTaxWithheld)) },
			{ "Total Taxes Paid to Date", Format.Money(assess.stats.totalTaxPaid) },
		})

		local curPos = ui.getCursorScreenPos()
		local colW = ui.getContentRegion().x
		ui.addLine(curPos, Vector2(curPos.x + colW, curPos.y), colors.border or colors.fontDim, 1.0)
		ui.dummy(Vector2(0, 6 * rescaleVector.y))

		ui.withFont(orbiteer.large, function()
			local balColor = (assess.accruedTax > 0 and (assess.isDelinquent and colors.alertRed or colors.alertYellow)) or (colors.econProfit or colors.uiPrimaryLight)
			ui.textColored(balColor, string.format("OUTSTANDING TAX BALANCE: %s", Format.Money(assess.accruedTax)))
		end)

		ui.withFont(pionillium.body, function()
			if assess.accruedTax > 0 then
				local statusColor = assess.isDelinquent and colors.alertRed or colors.alertYellow
				ui.textColored(statusColor, string.format("Status: %s", dueStatusStr))
			else
				ui.textColored(colors.econProfit or colors.uiPrimaryLight, "Status: Account in Good Standing")
			end
		end)

		ui.spacing()
		local payBtnSize = Vector2(ui.getContentRegion().x, 38 * rescaleVector.y)
		if assess.accruedTax > 0 then
			local canAfford = playerMoney >= assess.accruedTax
			local payBtnLabel = string.format("PAY ALL TAXES (%s)##lobbyPayTax", Format.Money(assess.accruedTax))

			if canAfford then
				ui.withStyleColors({ Button = colors.uiPrimaryLight, Text = colors.background or colors.font }, function()
					if ui.button(payBtnLabel, payBtnSize) then
						local ok, msg = TaxAuthority.PayTaxes()
						if ok then
							taxStatusBanner = msg
							taxBannerColor = colors.econProfit or colors.uiPrimaryLight
							ui.playSfx("OK")
						else
							taxStatusBanner = msg
							taxBannerColor = colors.alertRed
						end
					end
				end)
			else
				ui.withStyleColors({ Button = ui.theme.buttonColors.disabled.normal, Text = colors.alertRed }, function()
					ui.button("INSUFFICIENT FUNDS TO SETTLE TAX ASSESSMENT##lobbyPayTax", payBtnSize)
				end)
			end
		else
			ui.withStyleColors({ Button = ui.theme.buttonColors.disabled.normal, Text = colors.fontDim }, function()
				ui.button("ALL ASSESSMENTS SETTLED##lobbyPayTax", payBtnSize)
			end)
		end

		if taxStatusBanner then
			ui.spacing()
			ui.textColored(taxBannerColor, taxStatusBanner)
		end
	end)

	ui.columns(1, "LobbyCivilTaxEnd", false)
end

local function drawPlayerInfo()

	local station = Game.player:GetDockedWith()

	if(not (station and shipDef)) then return end

	local tech_certified

	if station.techLevel == 11 then
		tech_certified = l.TECH_CERTIFIED_MILITARY
	else
		tech_certified = string.interp(l.TECH_CERTIFIED, { tech_level = station.techLevel})
	end

	local station_docks = string.interp(l.STATION_DOCKS, { total_docking_pads = string.format("%d", station.numDocks),})

	local orbit_period = station.path:GetSystemBody().orbitPeriod

	local station_frameBody = Space.GetBody(station.path:GetSystemBody().parent.index)
	local local_gravity_pressure = ""
	if station.type == "STARPORT_SURFACE" then
		if station.path:GetSystemBody().parent.hasAtmosphere then
			local_gravity_pressure = string.format(l.STATION_LOCAL_GRAVITY_PRESSURE, (station.path:GetSystemBody().parent.gravity/9.8), station_frameBody:GetAtmosphericState(station))
		else
			local_gravity_pressure = string.format(l.STATION_LOCAL_GRAVITY, (station.path:GetSystemBody().parent.gravity/9.8))
		end
	end

	local station_orbit_info = ""
	if station.type == "STARPORT_ORBITAL" then
		station_orbit_info =
			string.interp(l.STATION_ORBIT, { orbit_period = string.format("%.2f", orbit_period),
				parent_body = station.path:GetSystemBody().parent.name})
	end

	ui.withFont(pionillium.heading, function()
		ui.withStyleVars({ItemSpacing = widgetSizes.itemSpacing}, function()
			local buttonSizeSpacing = widgetSizes.buttonLaunchSize.y + widgetSizes.itemSpacing.y

			ui.child("Wrapper", Vector2(0, 0), function()
				-- face display has 1:1 aspect ratio, and we need size for a launch button underneath
				local infoColumnWidth = -math.min(ui.getContentRegion().y - buttonSizeSpacing, widgetSizes.faceSize.x) - widgetSizes.itemSpacing.x
				ui.child("StationCivilInfo", Vector2(infoColumnWidth, 0), nil, commsChildFlags, function()
					ui.spacing()  -- Extra padding for umlaut and other signs on top of the station label.
					textTable.withHeading(station.label, orbiteer.title, {
						{ tech_certified, "" },
						{ station_docks, "" },
						{ station_orbit_info, "" },
						{ local_gravity_pressure, ""},
					})

					drawCivilAdministrationSection(station)
				end)

				ui.sameLine()

				ui.child("StationLobbyContact", Vector2(0, 0), nil, commsChildFlags, function()
					if(face ~= nil) then face:render() end

					local now = ui.getTime()
					ui.spacing()
					ui.separator()
					ui.spacing()
					ui.withFont(pionillium.details, function()
						local lineH = ui.getTextLineHeight()
						ui.icon(icons.comms, Vector2(lineH), colors.uiPrimaryLight)
						ui.sameLine()
						ui.textColored(colors.uiPrimaryLight, "PORT-OPS // TRAFFIC-CTRL")
						ui.sameLine()
						local rightText = "STARPORT FLIGHT OPERATIONS // TELEMETRY LINK"
						local avail = ui.getContentRegion().x
						local rw = ui.calcTextSize(rightText).x
						if avail > rw then
							ui.addCursorPos(Vector2(avail - rw, 0))
						end
						ui.textColored(colors.fontDim, rightText)
					end)
					ui.separator()
					ui.spacing()
					ui.withFont(pionillium.body, function()
						ui.textWrapped("Starport Flight Operations telemetry link verified. Docking bay clearance and orbital traffic monitoring standing by. Request departure clearance when pre-flight checks are complete.")
					end)
					ui.spacing()

					local size = Vector2(ui.getContentRegion().x, widgetSizes.buttonLaunchSize.y)
					if Insurance.HasPendingClaim() then
						ui.withFont(orbiteer.large, function()
							ui.withStyleColors({ Button = colors.alertRed }, function()
								if ui.button("SETTLE INSURANCE CLAIM TO LAUNCH", size) then
									StationView:SwitchTo("insurance")
								end
							end)
						end)
					else
						ui.withFont(orbiteer.title, function()
							if ui.button(l.REQUEST_LAUNCH, size) then
								requestLaunch(station)
							end
						end)
					end
				end)
			end)

		end)
	end)
end

StationView:registerView({
	id = "lobby",
	name = l.LOBBY,
	icon = ui.theme.icons.info,
	securityMode = "signature",
	showView = true,
	draw = drawPlayerInfo,
	refresh = function()
		taxStatusBanner = nil
		local station = Game.player:GetDockedWith()
		shipDef = ShipDef[Game.player.shipId]

		if (station) then
			if (stationSeed ~= station.seed) then
				stationSeed = station.seed
				local rand = Rand.New(station.seed)
				face = PiGuiFace.New(Character.New({ title = l.STATION_MANAGER }, rand), {itemSpacing = widgetSizes.itemSpacing})
			end
		end

		if Insurance.ShouldOpenModal() then
			StationView:SwitchTo("insurance")
			return
		end
	end,
	debugReload = function()
		package.reimport()
	end
})
