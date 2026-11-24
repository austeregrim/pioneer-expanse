-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui = require 'pigui'
local StationView = require 'pigui.views.station-view'
local AutoSave    = require 'modules.AutoSave.AutoSave'
local PlayerState = require 'PlayerState'
local Insurance   = require 'modules.Insurance.Insurance'
local TaxAuthority = require 'modules.Economy.TaxAuthority'
local Event       = require 'Event'

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

local rescaleVector = ui.rescaleUI(Vector2(1, 1), Vector2(1920, 1080), true, nil, true)
local uniformScale = math.min(rescaleVector.x, rescaleVector.y)
local widgetSizes = ui.rescaleUI({
	itemSpacing = Vector2(4, 4),
	faceSize = Vector2(440, 420),
	buttonSizeBase = Vector2(64, 34),
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
local managerStatusBanner = nil
local managerBannerColor = colors.uiPrimaryLight

local popupMsg = ''
local popup = ModalWindow.New('lobbyPopup', function(self)
	ui.text(popupMsg)
	ui.dummy(Vector2((ui.getContentRegion().x - 100*rescaleVector.x) / 2, 0))
	ui.sameLine()
	if ui.button("OK", Vector2(100*rescaleVector.x, 0)) then
		self:close()
	end
end)

local incarcerationModal = ModalWindow.New('incarcerationModal', function(self)
	local rec = Insurance.GetIncarcerationRecord()
	if not rec then
		self:close()
		return
	end

	ui.withFont(orbiteer.title, function()
		ui.textColored(colors.alertRed, "DEPARTMENT OF CORRECTIONS // JUDICIAL DISCHARGE RECORD")
	end)
	ui.separator()
	ui.spacing()

	ui.withFont(pionillium.body, function()
		ui.textWrapped("Pilot remand protocol completed. In accordance with Interstellar Judicial Standard Charter 44-B, mandatory holding period and compulsory fine restitution have been satisfied.")
	end)
	ui.spacing()

	local details = {
		{ "Correctional Facility", rec.stationName or "Detention Center" },
		{ "Destroyed Vessel", string.format("%s (%s)", rec.shipName or "Unregistered", rec.hullName or "Unknown") },
		{ "Intake Date", rec.startDateStr or "Unknown" },
		{ "Discharge Date", rec.releaseDateStr or "Present" },
		{ "Statutory Custody Term", string.format("%d Standard Days", rec.baseDays or 0) },
		{ "Unpaid Fine Commutation", (rec.extraDays and rec.extraDays > 0) and string.format("%d Standard Days (commuted at 150 Cr/day)", rec.extraDays) or "0 Days (Fine satisfied)" },
		{ "Total Time Served", string.format("%d Standard Days", rec.totalDays or 0) },
		{ "Outstanding Fines Assessed", Format.Money(rec.totalFine or 0) },
		{ "Liquid Capital Garnished", Format.Money(rec.finePaid or 0) },
		{ "Unpaid Balance Remitted", (rec.unpaidFine and rec.unpaidFine > 0) and string.format("%s (Discharged via Labor)", Format.Money(rec.unpaidFine)) or "0.00 Cr" },
		{ "Criminal Record & Warrants", "CLEARED & EXPUNGED (TIME SERVED)" },
		{ "Current Assigned Vessel", "Insurance Starter Ship (Coronatrix — Claim Pending)" },
		{ "Insurance Claim Status", "Underwriter Claim Open (Rebuy or payout at Insurance Office)" },
	}

	ui.columns(2, "IncarcerationDetails", false)
	ui.setColumnWidth(0, 310 * rescaleVector.x)
	for _, row in ipairs(details) do
		ui.withFont(pionillium.body, function()
			ui.textColored(colors.fontDim, row[1])
		end)
		ui.nextColumn()
		ui.withFont(pionillium.body, function()
			ui.textWrapped(row[2])
		end)
		ui.nextColumn()
	end
	ui.columns(1, "IncarcerationDetailsEnd", false)

	ui.spacing()
	ui.separator()
	ui.spacing()

	local btnText = "ACCEPT DISCHARGE & ENTER CONCOURSE"
	ui.withFont(orbiteer.medlarge, function()
		local btnTextW = ui.calcTextSize(btnText).x
		local btnWidth = math.max(520 * rescaleVector.x, btnTextW + 48 * rescaleVector.x)
		local availW = ui.getContentRegion().x
		if availW > btnWidth then
			ui.dummy(Vector2((availW - btnWidth) / 2, 0))
			ui.sameLine()
		end
		ui.withStyleColors({ Button = colors.uiPrimaryLight }, function()
			if ui.button(btnText, Vector2(btnWidth, widgetSizes.buttonSizeBase.y)) then
				Insurance.DismissIncarcerationRecord()
				self:close()
				if Insurance.HasClaim() then
					StationView:SwitchTo("insurance")
				end
			end
		end)
	end)
end)
incarcerationModal.centered = true
incarcerationModal.size = Vector2(920 * rescaleVector.x, 0)

local requestLaunch = function (station)
	if Insurance.HasClaim() then
		Comms.ImportantMessage("Launch clearance denied: settle your open insurance claim at the Insurance & SAR office first.", station.label)
		popupMsg = "You have an unresolved insurance claim. Please visit the Insurance & SAR tab to either rebuy your ship or claim your payout and keep the starter ship before launching."
		popup:open()
		return
	end

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
	local mgr = TaxAuthority.GetManagerInfo(station)
	local playerMoney = PlayerState.GetMoney()

	local okPenal, PenalSystem = pcall(require, 'modules.Penal.PenalSystem')
	local isPrison = okPenal and PenalSystem and PenalSystem.IsPrisonStation(station)

	ui.spacing()
	ui.separator()
	ui.spacing()

	-- Header
	ui.withFont(orbiteer.heading, function()
		ui.textColored(colors.uiPrimaryLight, "INTERSTELLAR REVENUE SERVICE & CIVIL ADMINISTRATION")
	end)
	ui.spacing()

	local availWidth = ui.getContentRegion().x
	local col0Width = math.floor(availWidth * 0.50)
	ui.columns(2, "LobbyCivilTaxCols", false)
	ui.setColumnWidth(0, col0Width)

	-- Left Column: Residency & Civic Allegiance
	ui.group(function()
		ui.withFont(orbiteer.body, function()
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
			local gaugeHeight = math.max(math.ceil(18 * uniformScale), pionillium.details.size + 6)
			local gaugeWidth = ui.getContentRegion().x
			local gaugePos = ui.getCursorScreenPos()
			gaugePos.y = gaugePos.y + gaugeHeight * 0.5
			ui.dummy(Vector2(gaugeWidth, gaugeHeight))
			ui.gauge(gaugePos, resInfo.progress * 100, '', "%d%% Term Elapsed",
				0, 100, icons.station or icons.info, false, colors.gaugeEquipmentMarket, '',
				gaugeWidth, gaugeHeight, pionillium.details)
		end

		ui.spacing()

		ui.withFont(orbiteer.body, function()
			ui.textColored(isPrison and colors.alertRed or colors.fontDim, isPrison and "HIGH-SECURITY CORRECTIONAL FACILITY" or "RESIDENCY PRIVILEGES & INCENTIVES")
		end)

		local actionBtnH = math.max(ui.getFrameHeight() + 6, math.ceil(30 * uniformScale))

		if isPrison then
			ui.bulletText("Incarceration Jurisdiction: Station strictly serves penal and judicial functions.")
			ui.bulletText("Civil Status Suspended: Commercial residency and tax domicile are strictly prohibited.")
			ui.bulletText("Starport Flight Clearance: Granted only to discharged pilots or verified couriers.")
			ui.spacing()
			local actionBtnSize = Vector2(ui.getContentRegion().x, actionBtnH)
			ui.withStyleColors({ Button = ui.theme.buttonColors.disabled.normal, Text = colors.fontDim }, function()
				ui.button("CIVIL RESIDENCY PROHIBITED AT CORRECTIONAL FACILITY##lobbyRes", actionBtnSize)
			end)
		else
			ui.bulletText("Subsidized Ship Insurance: 40% reduction on rebuy deductible (3% vs 5%).")
			ui.bulletText("Academic Cartography Credit: +10% scan value & 25% tax rebate at Home Port.")
			ui.bulletText("Home Fiduciary Rebate: 20% discount on Financial Manager onboarding fee at Home Port.")
			ui.bulletText("Faction Legal Standing: System defense patrol protection in core lanes.")

			ui.spacing()
			if station then
				local isCurrentHome = (resInfo.isResident and resInfo.homeStationName == station.label)
				local actionBtnSize = Vector2(ui.getContentRegion().x, actionBtnH)
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
		end

		if residencyStatusBanner then
			ui.spacing()
			ui.textColored(residencyBannerColor, residencyStatusBanner)
		end
	end)

	ui.nextColumn()

	-- Right Column: Quarterly Tax Statements, Current Quarter Accrual & Payment
	ui.group(function()
		ui.withFont(orbiteer.body, function()
			ui.textColored(colors.uiPrimaryLight, "QUARTERLY TAX ASSESSMENT")
		end)
		ui.withFont(pionillium.details, function()
			ui.withStyleColors({ Text = colors.fontDim }, function()
				ui.textWrapped("Quarterly Cycle: Profits report at quarter end (Mar/Jun/Sep/Dec) and remain payable until end of the following quarter.")
			end)
		end)
		ui.spacing()

		local dueStatusStr
		local reportedDue = assess.reportedTaxDue or assess.accruedTax or 0
		if assess.isDelinquent then
			dueStatusStr = "DELINQUENT - 5% LATE PENALTY APPLIED"
		elseif reportedDue > 0 and assess.earliestDueLabel then
			dueStatusStr = string.format("Due by %s (%d days grace remaining)", assess.earliestDueLabel, assess.daysUntilDue or 0)
		elseif (assess.currentQuarterTax or 0) > 0 then
			dueStatusStr = string.format("Accruing %s (Reports %s)", assess.currentQuarterLabel or "Current Qtr", assess.currentQuarterReportLabel or "Quarter End")
		else
			dueStatusStr = "No Reported Taxes Pending"
		end

		local curAccrualStr = string.format("%s (Reports %s, Due %s)",
			Format.Money(assess.currentQuarterTax or 0),
			assess.currentQuarterReportLabel or "Quarter End",
			assess.currentQuarterDueLabel or "Next Quarter End")

		local taxRows = {
			{ "Your Liquid Capital", Format.Money(playerMoney) },
			{ "Quarterly Filing Status", dueStatusStr },
			{ string.format("Current Quarter (%s)", assess.currentQuarterLabel or "Accruing"), curAccrualStr },
			{ "Flagship Trade Net Profit Tax", Format.Money(assess.breakdown.tradeProfitTax or 0) },
			{ "Autonomous Fleet Operations Tax", Format.Money(assess.breakdown.fleetOperationsTax or 0) },
		}
		if (assess.breakdown.stationOperationsTax or 0) > 0 then
			table.insert(taxRows, { "Station & Industrial Ops Tax", Format.Money(assess.breakdown.stationOperationsTax or 0) })
		end
		table.insert(taxRows, { "Contracts, Missions & Bounties Tax", Format.Money(assess.breakdown.bbsJobsTax or 0) })
		table.insert(taxRows, { "Cartographic Survey Tax", Format.Money(assess.breakdown.cartographyTax or 0) })
		table.insert(taxRows, { "Equities & Dividends Tax", Format.Money(assess.breakdown.investmentTax or 0) })
		table.insert(taxRows, { "Lottery Windfall Tax Withheld", string.format("%s (30%% Withheld)", Format.Money(assess.breakdown.windfallTaxWithheld or 0)) })
		table.insert(taxRows, { "Crew & Captain Salaries Deducted", Format.Money(assess.breakdown.crewPayrollDeducted or 0) })
		table.insert(taxRows, { "Deductible Operating Expenses", string.format("%s (Pool: %s)", Format.Money(assess.breakdown.operatingExpensesDeducted or 0), Format.Money(assess.deductibleExpensePool or 0)) })
		table.insert(taxRows, { "Total Taxes Paid to Date", Format.Money(assess.stats.totalTaxPaid or 0) })
		textTable.draw(taxRows)

		if assess.statements and #assess.statements > 0 then
			ui.spacing()
			ui.withFont(pionillium.details, function()
				ui.textColored(colors.uiPrimaryLight, "REPORTED QUARTERLY STATEMENTS DUE:")
				for _, stmt in ipairs(assess.statements) do
					local sCol = stmt.isDelinquent and colors.alertRed or colors.alertYellow
					local deadlineText = stmt.isDelinquent
						and string.format("DELINQUENT (+%s penalty)", Format.Money(stmt.penalty or 0))
						or string.format("Payable until %s (%dd left)", stmt.dueLabel or "Next Qtr End", stmt.daysUntilDue or 0)
					ui.textColored(sCol, string.format("• %s: %s  —  %s", stmt.label, Format.Money(stmt.tax or 0), deadlineText))
				end
			end)
		end

		local curPos = ui.getCursorScreenPos()
		local colW = ui.getContentRegion().x
		ui.addLine(curPos, Vector2(curPos.x + colW, curPos.y), colors.border or colors.fontDim, 1.0)
		ui.dummy(Vector2(0, math.ceil(4 * uniformScale)))

		ui.withFont(orbiteer.heading, function()
			local balColor = (reportedDue > 0 and (assess.isDelinquent and colors.alertRed or colors.alertYellow)) or (colors.econProfit or colors.uiPrimaryLight)
			ui.textColored(balColor, string.format("REPORTED TAX DUE: %s", Format.Money(reportedDue)))
		end)

		ui.withFont(pionillium.body, function()
			if (resInfo.effectiveRate or 0) <= 0 then
				ui.textColored(colors.fontDim, "Jurisdiction rate is 0.0% (Anarchy/Lawless). Register at a lawful port for civil coverage.")
			elseif reportedDue > 0 then
				local statusColor = assess.isDelinquent and colors.alertRed or colors.alertYellow
				ui.textColored(statusColor, string.format("Status: %s", dueStatusStr))
			elseif (assess.currentQuarterTax or 0) > 0 then
				ui.textColored(colors.econProfit or colors.uiPrimaryLight,
					string.format("Status: No Reported Balance Due (%s reported %s)", Format.Money(assess.currentQuarterTax), assess.currentQuarterReportLabel or "at quarter end"))
			else
				ui.textColored(colors.econProfit or colors.uiPrimaryLight, "Status: Account in Good Standing")
			end
		end)

		ui.spacing()
		local payBtnSize = Vector2(ui.getContentRegion().x, math.max(ui.getFrameHeight() + 6, math.ceil(30 * uniformScale)))
		if reportedDue > 0 then
			local canAfford = playerMoney >= reportedDue
			local payBtnLabel = string.format("PAY REPORTED TAXES (%s)##lobbyPayTax", Format.Money(reportedDue))

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
				ui.button("NO REPORTED TAXES DUE##lobbyPayTax", payBtnSize)
			end)
		end

		if taxStatusBanner then
			ui.spacing()
			ui.textColored(taxBannerColor, taxStatusBanner)
		end
	end)

	ui.columns(1, "LobbyCivilTaxEnd", false)

	-- Financial Manager Section (Automated Quarterly Tax Settlement)
	ui.spacing()
	ui.separator()
	ui.spacing()
	ui.withFont(orbiteer.body, function()
		ui.textColored(colors.uiPrimaryLight, "FINANCIAL MANAGEMENT & AUTOMATED TAX FILING")
	end)
	ui.spacing()

	local mgrColW = math.floor(availWidth * 0.62)
	ui.columns(2, "LobbyManagerCols", false)
	ui.setColumnWidth(0, mgrColW)

	ui.group(function()
		if mgr.hired then
			local mRows = {
				{ "Retained Financial Manager", string.format("%s — %s", mgr.name or "Officer", mgr.title or "Fiduciary Officer") },
				{ "Mandate Status", "ACTIVE — Auto-Paying Reported Quarterly Taxes" },
				{ "Retaining Office", mgr.hiredStation or "Registered Agency" },
				{ "Quarterly Retainer", string.format("%s / quarter (tax-deductible)", Format.Money(mgr.quarterlyFee or 1500)) },
				{ "Taxes Auto-Settled", string.format("%s (%d quarterly statement(s))", Format.Money(mgr.totalTaxesSettled or 0), mgr.statementsSettled or 0) },
			}
			if mgr.lastPaymentNote and mgr.lastPaymentNote ~= "" then
				table.insert(mRows, { "Latest Ledger Note", mgr.lastPaymentNote })
			end
			textTable.draw(mRows)
		else
			ui.withFont(pionillium.details, function()
				ui.textWrapped("Retain a bonded Financial Manager to monitor quarterly tax statements and automatically settle reported assessments on your behalf—preventing late penalties during multi-month deep-space voyages.")
			end)
			ui.spacing()
			local feeText = mgr.isHomeStationDiscount
				and string.format("%s (-%d%% Home Station Discount, std %s; tax-deductible)", Format.Money(mgr.hireFee or 2000), mgr.homeDiscountPct or 20, Format.Money(mgr.baseHireFee or 2500))
				or string.format("%s (tax-deductible operating expense)", Format.Money(mgr.hireFee or 2500))
			textTable.draw({
				{ "Available Fiduciary Officer", string.format("%s — %s", mgr.candidateName or "Elena Vance", mgr.candidateTitle or "Senior Tax & Fiduciary Officer") },
				{ "Onboarding Fee", feeText },
				{ "Quarterly Retainer", string.format("%s / quarter (auto-billed at quarter close)", Format.Money(mgr.quarterlyFee or 1500)) },
			})
		end
	end)

	ui.nextColumn()

	ui.group(function()
		local mgrBtnSize = Vector2(ui.getContentRegion().x, math.max(ui.getFrameHeight() + 6, math.ceil(32 * uniformScale)))
		if mgr.hired then
			if ui.button("DISMISS FINANCIAL MANAGER##lobbyDismissMgr", mgrBtnSize) then
				local ok, msg = TaxAuthority.DismissManager()
				managerStatusBanner = msg
				managerBannerColor = ok and colors.alertYellow or colors.alertRed
			end
		elseif isPrison then
			ui.withStyleColors({ Button = ui.theme.buttonColors.disabled.normal, Text = colors.fontDim }, function()
				ui.button("FIDUCIARY CONTRACTING UNAVAILABLE AT PRISON##lobbyHireMgr", mgrBtnSize)
			end)
		else
			local hireFee = mgr.hireFee or 2500
			local hireBtnLabel = mgr.isHomeStationDiscount
				and string.format("HIRE FINANCIAL MANAGER (%s · -%d%% HOME)##lobbyHireMgr", Format.Money(hireFee), mgr.homeDiscountPct or 20)
				or string.format("HIRE FINANCIAL MANAGER (%s)##lobbyHireMgr", Format.Money(hireFee))
			if playerMoney >= hireFee then
				ui.withStyleColors({ Button = colors.uiPrimaryLight, Text = colors.background or colors.font }, function()
					if ui.button(hireBtnLabel, mgrBtnSize) then
						local ok, msg = TaxAuthority.HireManager(station)
						managerStatusBanner = msg
						managerBannerColor = ok and (colors.econProfit or colors.uiPrimaryLight) or colors.alertRed
						if ok then ui.playSfx("OK") end
					end
				end)
			else
				ui.withStyleColors({ Button = ui.theme.buttonColors.disabled.normal, Text = colors.alertRed }, function()
					ui.button(string.format("INSUFFICIENT FUNDS TO HIRE (%s)##lobbyHireMgr", Format.Money(hireFee)), mgrBtnSize)
				end)
			end
		end

		if managerStatusBanner then
			ui.spacing()
			ui.textColored(managerBannerColor, managerStatusBanner)
		end
	end)

	ui.columns(1, "LobbyManagerEnd", false)
end

local function drawPlayerInfo()
	if Insurance.HasIncarcerationRecord() and not incarcerationModal.isOpen and incarcerationModal.stackIdx == -1 then
		incarcerationModal:open()
	end

	local station = Game.player:GetDockedWith()
	if not shipDef and Game.player then
		shipDef = ShipDef[Game.player.shipId]
	end

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

	ui.withFont(pionillium.body, function()
		ui.withStyleVars({ItemSpacing = widgetSizes.itemSpacing}, function()
			local buttonSizeSpacing = widgetSizes.buttonLaunchSize.y + widgetSizes.itemSpacing.y

			ui.child("Wrapper", Vector2(0, 0), function()
				-- face display has 1:1 aspect ratio, and we need size for a launch button underneath
				local infoColumnWidth = -math.min(ui.getContentRegion().y - buttonSizeSpacing, widgetSizes.faceSize.x) - widgetSizes.itemSpacing.x
				ui.child("StationCivilInfo", Vector2(infoColumnWidth, 0), nil, commsChildFlags, function()
					local stationRows = {
						{ tech_certified, "" },
						{ station_docks, "" },
					}
					if station_orbit_info ~= "" then
						table.insert(stationRows, { station_orbit_info, "" })
					end
					if local_gravity_pressure ~= "" then
						table.insert(stationRows, { local_gravity_pressure, "" })
					end
					textTable.withHeading(station.label, orbiteer.heading, stationRows)

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
						local rightText = "STARPORT FLIGHT OPERATIONS // TELEMETRY LINK"
						local rw = ui.calcTextSize(rightText).x
						ui.sameLine()
						local avail = ui.getContentRegion().x
						if avail > rw + 8 then
							ui.addCursorPos(Vector2(avail - rw, 0))
							ui.textColored(colors.fontDim, rightText)
						else
							ui.newLine()
							ui.textColored(colors.fontDim, rightText)
						end
					end)
					ui.separator()
					ui.spacing()
					ui.withFont(pionillium.body, function()
						ui.textWrapped("Starport Flight Operations telemetry link verified. Docking bay clearance and orbital traffic monitoring standing by. Request departure clearance when pre-flight checks are complete.")
					end)
					ui.spacing()

					local size = Vector2(ui.getContentRegion().x, widgetSizes.buttonLaunchSize.y)
					local claim = Insurance.GetActiveClaim()
					if claim and not claim.resolved then
						ui.withFont(pionillium.body, function()
							local claimShipDef = ShipDef[claim.hullId]
							local name = claim.shipName or (claimShipDef and claimShipDef.name) or "destroyed vessel"
							ui.textColored(colors.alertRed, string.format("LAUNCH LOCKED: Open insurance claim pending for %s. Rebuy your ship or claim payout at the Insurance & SAR office.", name))
						end)
						ui.spacing()
						ui.withFont(orbiteer.medlarge, function()
							ui.withStyleColors({ Button = colors.alertRed }, function()
								if ui.button("SETTLE INSURANCE CLAIM TO LAUNCH##lobbyInsurance", size) then
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
		residencyStatusBanner = nil
		managerStatusBanner = nil
		local station = Game.player:GetDockedWith()
		shipDef = ShipDef[Game.player.shipId]

		if (station) then
			if (stationSeed ~= station.seed) then
				stationSeed = station.seed
				local rand = Rand.New(station.seed)
				face = PiGuiFace.New(Character.New({ title = l.STATION_MANAGER }, rand), {itemSpacing = widgetSizes.itemSpacing})
			end
		end

		if Insurance.HasIncarcerationRecord() and not incarcerationModal.isOpen and incarcerationModal.stackIdx == -1 then
			incarcerationModal:open()
		end
	end,
	debugReload = function()
		package.reimport()
	end
})

Event.Register("onPlayerRescued", function()
	if Insurance.HasIncarcerationRecord() and not incarcerationModal.isOpen and incarcerationModal.stackIdx == -1 then
		incarcerationModal:open()
	end
end)
