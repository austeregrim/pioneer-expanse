-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require "Game"
local Rand = require "Rand"
local ui = require 'pigui'
local StationView = require 'pigui.views.station-view'
local Lang = require 'Lang'
local Legal = require "Legal"
local FactionRoles = require "FactionRoles"
local FactionStanding = require "FactionStanding"
local Event = require 'Event'
local utils = require "utils"
local PiGuiFace = require 'pigui.libs.face'
local Format = require "Format"
local Character = require "Character"
local Commodities = require 'Commodities'
local PlayerState = require 'PlayerState'
local EncryptedText = require 'pigui.libs.encrypted-text'
local l = Lang.GetResource("ui-core")

local ModalWindow = require 'pigui.libs.modal-win'

local rescaleVector = ui.rescaleUI(Vector2(1, 1), Vector2(1920, 1080), true)
local uniformScale = math.min(rescaleVector.x, rescaleVector.y)
local colors = ui.theme.colors
local icons = ui.theme.icons

local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local commsChildFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }
local face = nil
local stationSeed = false
local commsText = EncryptedText.New("", 0.50)

local crimeTableID = "##CrimeTable"

local view

local function refreshStatusIcon()
	local crimes, fine = PlayerState.GetCrimeOutstanding()
	view.icon = fine > 0 and ui.theme.icons.police_tab_fined or ui.theme.icons.police_tab_normal
end

local militaryStatusBanner = nil
local militaryBannerColor = Color(100, 225, 165, 255)

local popup = ModalWindow.New('policePopup', function(self)
	ui.text(l.YOU_NOT_ENOUGH_MONEY .. ".")
	ui.dummy(Vector2((ui.getContentRegion().x - 100*rescaleVector.x) / 2, 0))
	ui.sameLine()
	if ui.button(l.OK, Vector2(100*rescaleVector.x, 0)) then
		self:close()
	end
end)

local resignMilitaryModal = ModalWindow.New('resignMilitaryModal', function(self)
	local active = FactionRoles.GetActiveEnlistment() or "your faction"
	ui.withFont(orbiteer.heading, function()
		ui.textColored(colors.alertRed, "RESIGN MILITARY COMMISSION")
	end)
	ui.separator()
	ui.spacing()
	ui.withFont(pionillium.body, function()
		ui.textWrapped(string.format(
			"Resigning from %s military service will incur a -5 standing penalty and a 14-day re-enlistment cooldown. Your earned rank and XP remain preserved, and permanent rival faction enlistment lockouts remain in effect.",
			active
		))
	end)
	ui.spacing()
	local btnW = 150 * rescaleVector.x
	if ui.button("Confirm Resign", Vector2(btnW, 0)) then
		local ok, msg = FactionRoles.ResignMilitary(false)
		militaryStatusBanner = msg
		militaryBannerColor = ok and Color(255, 185, 55, 255) or colors.alertRed
		if ok then ui.playSfx("OK") end
		self:close()
	end
	ui.sameLine()
	if ui.button("Cancel", Vector2(btnW, 0)) then
		self:close()
	end
end)
resignMilitaryModal.centered = true
resignMilitaryModal.size = Vector2(540 * rescaleVector.x, 0)

local widgetSizes = ui.rescaleUI({
	itemSpacing = Vector2(4, 7),
	faceSize = Vector2(460, 440),
	crimeRecordColumnWidth = 50,
	buttonSize = Vector2(90, 0),
	dummySpaceSmall = Vector2(0, 8),
	dummySpaceMedium = Vector2(0, 36),
	tablePadding = Vector2(10, 3)
}, Vector2(1920, 1080))


local function payfine(fine)
	if PlayerState.GetMoney() < fine then
		popup:open()
		return
	end

	local record = PlayerState.GetCrimeRecord()
	local crimeDetails = {}
	if record and record.crimetype then
		local crimes = make_crime_list(record.crimetype)
		for _, c in ipairs(crimes) do
			if c.count > 0 then
				table.insert(crimeDetails, { "Infraction: " .. c.name, string.format("%d count(s)", c.count) })
			end
		end
	end
	table.insert(crimeDetails, { "Fine Settled", Format.Money(fine) })
	local factionName = (Game.system and Game.system.faction and Game.system.faction.name) or "Local Authority"
	table.insert(crimeDetails, { "Issuing Authority", factionName })

	PlayerState.AddMoney(-fine)
	PlayerState.ClearCrimeFine()
	refreshStatusIcon()

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		FlightLog.RecordTransaction({
			category = "FINE",
			title = string.format("Police Fine Paid (%s)", Format.Money(-fine)),
			amount = -fine,
			details = crimeDetails,
			note = string.format("Settled %s in outstanding fines and citations with %s.", Format.Money(fine), factionName)
		})
	end
end

local function make_crime_list(record)
	local crimes = utils.build_array(utils.map(
		function(crime, v) return true, { count = v.count, name = Legal.CrimeType[crime].name } end,
		pairs(record)
	))

	table.sort(crimes, function(a, b) return a.count > b.count end)

	return crimes
end

-- Render a list of outstanding crimes
local function crime_table(crimes)
	ui.withStyleVars({ CellPadding = widgetSizes.tablePadding }, function()
		ui.beginTable(crimeTableID, 2, { "BordersInnerV" })

		ui.tableSetupColumn("count", "WidthFixed")
		ui.tableSetupColumn("name", "WidthStretch")

		for _, v in pairs(crimes) do
			ui.tableNextRow()

			ui.tableNextColumn()
			ui.text(v.count)

			ui.tableNextColumn()
			ui.text(v.name)
		end

		ui.endTable()
	end)
end

local function crime_record()
	local past_crimes = make_crime_list(PlayerState.GetCrimeRecord())

	if #past_crimes > 0 then
		ui.withFont(orbiteer.heading, function()
			ui.text(l.CRIMINAL_RECORD .. ":")
		end)

		ui.withStyleColors({ Text = ui.theme.colors.fontDim }, function()
			crime_table(past_crimes)
		end)
	end
end


local function outstanding_fines()
	local crimes, fine = PlayerState.GetCrimeOutstanding()

	local crime_list = make_crime_list(crimes)
	if #crime_list > 0 then

		-- headline
		ui.withFont(orbiteer.heading, function()
			ui.text(l.OUTSTANDING_FINES .. ":")
		end)

		-- wrap list in medlarge font
		ui.withFont(pionillium.body, function()
			crime_table(crime_list)
			ui.spacing()

			local canPay = PlayerState.GetMoney() >= fine
			local pay_fine_text = string.interp(l.PAY_FINE_OF_N,
				{ amount = Format.Money(fine) })

			if canPay and ui.button(pay_fine_text, nil) then
				payfine(fine)
			elseif not canPay then
				ui.withStyleColors({ Button = ui.theme.buttonColors.disabled.normal, Text = ui.theme.colors.fontDim }, function()
					ui.button(pay_fine_text, nil)
				end)
			end

			if not canPay and ui.isItemHovered() then
				ui.setTooltip(l.YOU_NOT_ENOUGH_MONEY)
			end
		end)
	else
		ui.withFont(pionillium.body, function()
			ui.text(l.WE_HAVE_NO_BUSINESS_WITH_YOU)
		end)
	end
end

local function drawRulesAndRegulations()
	local station = Game.player:GetDockedWith()

	local header = string.interp(l.LEGAL_RULES, {
		distance = Format.Distance(station.lawEnforcedRange),
	})
	ui.text(header)
	ui.spacing()
	local xpRequired = Legal.IsTransponderRequired(Game.system)
	ui.withStyleColors({ Text = xpRequired and ui.theme.colors.accent or ui.theme.colors.fontDim }, function()
		ui.text("System Transponder Law: " .. (xpRequired
			and "MANDATORY (Transponder must remain ON in open space and at stations)"
			or "NOT REQUIRED (Lawless / unregulated airspace)"))
	end)
	ui.newLine()

	local lawlessness = Game.system.lawlessness

	local crimeList = utils.build_array(utils.map(
		function(k, v) return true, { name = v.name, fine = Legal:fine(k, lawlessness)} end,
		pairs(Legal.CrimeType)
	))

	table.sort(crimeList, function(a, b) return a.name < b.name end)

	ui.withStyleVars({ CellPadding = widgetSizes.tablePadding }, function()
		ui.beginTable("Crimes", 2, { "BordersInnerH" })
		ui.tableSetupColumn(l.CRIME .. ":")
		ui.tableSetupColumn(l.FINE .. ":")

		ui.withFont(pionillium.heading, function()
			ui.tableHeadersRow()
		end)

		for _, v in ipairs(crimeList) do
			ui.tableNextRow()

			ui.tableNextColumn()
			ui.text(v.name .. ":")

			ui.tableNextColumn()
			ui.textAligned(Format.Money(v.fine), 1.0)
		end

		ui.endTable()
	end)
end

local policeTabs = {
	{
		name = l.CRIMINAL_RECORD,
		draw = function()
			-- 1. If outstanding fines, show list & offer to pay
			outstanding_fines()

			ui.dummy(widgetSizes.dummySpaceSmall)

			-- 2 If old payed fines, show grayd out list
			crime_record()
		end
	},
	{
		name = l.LEGAL_RULES_AND_REGULATIONS,
		draw = drawRulesAndRegulations
	},
	{
		name = l.ILLEGAL_COMMODITIES,
		draw = function()
			ui.textWrapped(l.POSESSION_OF_COMMODITIES_ILLEGAL)
			ui.spacing()
			ui.separator()
			ui.spacing()
			ui.textWrapped(l.THESE_ITEMS_ARE_PUNISHABLE_BY_FINE .. ":")

			ui.spacing()

			-- Build a list of illegal goods in this system
			local illegal = utils.map_array(utils.build_array(pairs(Commodities)), function(comm)
				return not Game.system:IsCommodityLegal(comm.name) and comm:GetProperName() or nil
			end)

			-- Sort the list lexicographically
			table.sort(illegal)

			for _, name in ipairs(illegal) do
				ui.text(name)
			end
		end
	},
	{
		name = "Bounty Licences",
		draw = function()
			local sys = Game.system
			local faction = sys and sys.faction
			local factionName = (faction and faction.name) or "Local Authority"
			local info = FactionRoles.GetBountyLicenceInfo(factionName)
			local terms = FactionRoles.GetBountyLicenceTerms(factionName, sys)

			ui.withFont(orbiteer.heading, function()
				ui.text("Faction Bounty Hunter Licence — " .. factionName)
			end)
			ui.spacing()
			ui.textWrapped("A Bounty Hunter Licence authorizes you to accept faction bounty contracts and access " .. factionName .. " warrant registries via a Warrant Scanner. Licences are valid across all systems controlled by the issuing faction.")
			ui.spacing()

			if info and info.active then
				local statusStr = info.deputy and "DEPUTIZED (PERPETUAL)"
					or (info.perpetual and "ACTIVE (PERPETUAL)"
					or string.format("ACTIVE (%.0f days remaining)", info.remainingDays or 0))
				ui.withStyleColors({ Text = Color(100, 225, 165, 255) }, function()
					ui.text("Status: " .. statusStr)
				end)
				if not info.perpetual then
					ui.spacing()
					local renewLabel = string.format("Renew Licence (%s, %d days)", Format.Money(terms.fee), terms.termDays)
					if ui.button(renewLabel, nil) then
						local ok, err = FactionRoles.PurchaseBountyLicence(factionName, sys)
						if not ok and err == "INSUFFICIENT_FUNDS" then
							popup:open()
						else
							ui.playSfx("OK")
						end
					end
				end
			else
				local statusStr = (info and info.expired) and "EXPIRED" or "NOT HELD"
				ui.withStyleColors({ Text = Color(255, 185, 55, 255) }, function()
					ui.text("Status: " .. statusStr)
				end)
				ui.spacing()
				local termStr = terms.perpetual and "Perpetual" or string.format("%d days", terms.termDays)
				ui.text(string.format("Local Fee: %s   |   Term: %s", Format.Money(terms.fee), termStr))
				ui.spacing()
				local buyLabel = string.format("Purchase %s Bounty Licence (%s)", factionName, Format.Money(terms.fee))
				if ui.button(buyLabel, nil) then
					local ok, err = FactionRoles.PurchaseBountyLicence(factionName, sys)
					if not ok and err == "INSUFFICIENT_FUNDS" then
						popup:open()
					else
						ui.playSfx("OK")
					end
				end
			end

			local allLicences = FactionRoles.GetAllLicences()
			if #allLicences > 0 then
				ui.spacing()
				ui.separator()
				ui.spacing()
				ui.withFont(orbiteer.heading, function()
					ui.text("Held & Past Licences:")
				end)
				ui.withStyleVars({ CellPadding = widgetSizes.tablePadding }, function()
					if ui.beginTable("##LicenceTable", 3, { "BordersInnerH" }) then
						ui.tableSetupColumn("Faction", "WidthStretch")
						ui.tableSetupColumn("Status", "WidthFixed")
						ui.tableSetupColumn("Term", "WidthFixed")
						ui.tableHeadersRow()
						for _, lic in ipairs(allLicences) do
							ui.tableNextRow()
							ui.tableNextColumn()
							ui.text(lic.factionName)
							ui.tableNextColumn()
							ui.text(lic.active and "Active" or "Expired")
							ui.tableNextColumn()
							ui.text(lic.perpetual and "Perpetual" or string.format("%.0fd", lic.remainingDays or 0))
						end
						ui.endTable()
					end
				end)
			end
		end
	},
	{
		name = "Military & Deputy",
		draw = function()
			local sys = Game.system
			local faction = sys and sys.faction
			local factionName = (faction and faction.name) or "Independent"
			local milName = (faction and faction.militaryName and faction.militaryName ~= "" and faction.militaryName)
				or (factionName .. " Navy")
			local station = Game.player and Game.player:GetDockedWith()
			local okPenal, PenalSystem = pcall(require, 'modules.Penal.PenalSystem')
			local isPrison = station and okPenal and PenalSystem and PenalSystem.IsPrisonStation(station)
			local isStateless = FactionRoles.IsStatelessFaction(factionName)

			local cit = FactionRoles.GetCitizenship()
			local hasCitizenship = (not isStateless) and cit ~= nil and cit.factionName == factionName
			local milInfo = FactionRoles.GetMilitaryInfo(factionName)
			local canEnlist, enlistReason = FactionRoles.CanEnlist(factionName)
			local green = Color(100, 225, 165, 255)
			local amber = Color(255, 185, 55, 255)

			-- Section 1: Military Enlistment
			ui.withFont(orbiteer.heading, function()
				ui.text("Military Service — " .. milName)
			end)
			ui.spacing()

			if isPrison or isStateless then
				ui.withStyleColors({ Text = colors.fontDim }, function()
					ui.textWrapped(isPrison
						and "Military enlistment and Deputy charters are unavailable at penal facilities."
						or "Independent and uncontrolled systems do not maintain a regular faction military or Deputy charter.")
				end)
			else
				local citStatusText = hasCitizenship
					and string.format("Verified (%s Citizen)", factionName)
					or (cit and string.format("Not Held Here (Citizen of %s)", cit.factionName) or "Stateless (Claim Citizenship in Lobby)")
				ui.withStyleColors({ Text = hasCitizenship and green or amber }, function()
					ui.text("Citizenship Status: " .. citStatusText)
				end)

				local enlistStatusText
				local enlistStatusColor = colors.fontDim
				if milInfo.enlisted then
					enlistStatusText = string.format("ACTIVE COMMISSION — %s (Rank %d)", milInfo.rankTitle, milInfo.rank)
					enlistStatusColor = green
				elseif milInfo.blacklisted then
					enlistStatusText = string.format("PERMANENTLY BARRED: Prior service with rival %s", milInfo.rivalFaction or "faction")
					enlistStatusColor = colors.alertRed
				elseif milInfo.activeFaction then
					enlistStatusText = string.format("Enlisted Elsewhere (%s)", milInfo.activeFaction)
					enlistStatusColor = amber
				elseif (milInfo.reenlistCooldownDays or 0) > 0 then
					enlistStatusText = string.format("Re-enlistment Cooldown (%d days remaining)", milInfo.reenlistCooldownDays)
					enlistStatusColor = amber
				else
					enlistStatusText = "Not Enlisted"
				end
				ui.withStyleColors({ Text = enlistStatusColor }, function()
					ui.text("Service Status: " .. enlistStatusText)
				end)

				ui.text(string.format("Rank: %s (%d/%s XP)   |   Hazard Bonus: +%d%%   |   Service Discount: %d%%   |   Commendations: %d",
					milInfo.rankTitle,
					milInfo.xp or 0,
					milInfo.nextRankXP and tostring(milInfo.nextRankXP) or "MAX",
					math.floor((milInfo.hazardBonus or 0) * 100),
					math.floor((milInfo.serviceDiscount or 0) * 100),
					milInfo.commendations or 0
				))

				-- Rank XP Progress Gauge
				local prevMinXP = 0
				for _, r in ipairs(FactionRoles.MILITARY_RANKS) do
					if r.rank == milInfo.rank then
						prevMinXP = r.minXP
						break
					end
				end
				local pct = 100
				if milInfo.nextRankXP and milInfo.nextRankXP > prevMinXP then
					pct = math.max(0, math.min(100, ((milInfo.xp - prevMinXP) / (milInfo.nextRankXP - prevMinXP)) * 100))
				end
				local gaugeHeight = math.max(math.ceil(18 * uniformScale), pionillium.details.size + 6)
				local gaugeWidth = math.min(ui.getContentRegion().x, 420 * rescaleVector.x)
				local gaugePos = ui.getCursorScreenPos()
				gaugePos.y = gaugePos.y + gaugeHeight * 0.5
				ui.dummy(Vector2(gaugeWidth, gaugeHeight))
				ui.gauge(gaugePos, pct, '', milInfo.nextRankXP and "%d%% to Next Rank" or "Maximum Rank Achieved",
					0, 100, icons.shield or icons.info, false, colors.gaugeEquipmentMarket, '',
					gaugeWidth, gaugeHeight, pionillium.details)

				ui.spacing()
				if milInfo.enlisted then
					if ui.button("Resign Commission##polResign", nil) then
						resignMilitaryModal:open()
					end
				elseif canEnlist then
					if ui.button("Enlist in " .. milName .. "##polEnlist", nil) then
						local ok, msg = FactionRoles.Enlist(factionName)
						militaryStatusBanner = msg
						militaryBannerColor = ok and green or colors.alertRed
						if ok then ui.playSfx("OK") end
					end
				else
					ui.withStyleColors({ Button = ui.theme.buttonColors.disabled.normal, Text = colors.fontDim }, function()
						ui.button("Enlistment Unavailable##polEnlistDis", nil)
					end)
					if enlistReason then
						ui.sameLine()
						ui.withStyleColors({ Text = milInfo.blacklisted and colors.alertRed or amber }, function()
							ui.textWrapped(enlistReason)
						end)
					end
				end

				ui.spacing()
				ui.separator()
				ui.spacing()

				-- Section 2: Faction Deputy Charter
				ui.withFont(orbiteer.heading, function()
					ui.text("Faction Deputy Charter — " .. factionName)
				end)
				ui.spacing()
				ui.textWrapped("Deputized pilots receive perpetual waiver of faction bounty licence fees, faction-wide warrant access, and legal authority to interdict and engage faction-wanted targets within " .. factionName .. " jurisdiction.")
				ui.spacing()

				local elig = FactionRoles.GetDeputyEligibility(factionName)
				local function drawCheckRow(ok, label)
					ui.withStyleColors({ Text = ok and green or colors.alertRed }, function()
						ui.text((ok and "[PASS] " or "[FAIL] ") .. label)
					end)
				end

				drawCheckRow(elig.citizenshipOk, string.format("Citizenship in %s", factionName))
				drawCheckRow(elig.standingOk, string.format("Allied Standing >= 75 (Current: %d)", elig.standing or 0))
				drawCheckRow(elig.cleanRecordOk, string.format("Clean Criminal Record (Fine: %s)", Format.Money(elig.fine or 0)))
				drawCheckRow(elig.credentialOk, string.format("Bounty Licence, Active Military, or 3+ Commendations (Current: %d)", elig.commendations or 0))
				if not elig.cooldownOk then
					drawCheckRow(false, string.format("Revocation Cooldown Expired (%d days remaining)", elig.cooldownRemDays or 0))
				end

				ui.spacing()
				if elig.isDeputy then
					ui.withStyleColors({ Text = green }, function()
						ui.text("Status: ACTIVE — DEPUTIZED (PERPETUAL)")
					end)
				elseif elig.eligible then
					if ui.button("Claim Deputy Charter##polDeputy", nil) then
						local ok, msg = FactionRoles.ClaimDeputyCharter(factionName)
						militaryStatusBanner = msg
						militaryBannerColor = ok and green or colors.alertRed
						if ok then ui.playSfx("OK") end
					end
				else
					ui.withStyleColors({ Button = ui.theme.buttonColors.disabled.normal, Text = colors.fontDim }, function()
						ui.button("Claim Deputy Charter (Requirements Unmet)##polDeputyDis", nil)
					end)
					if ui.isItemHovered() and #elig.reasons > 0 then
						ui.setTooltip(table.concat(elig.reasons, "\n"))
					end
				end
			end

			-- Section 3: Naval Combat Bonds
			local okCZ, FrontlineCZ = pcall(require, 'modules.FrontlineSupport.FrontlineCombatZones')
			if okCZ and FrontlineCZ and FrontlineCZ.GetAllPendingBonds then
				ui.spacing()
				ui.separator()
				ui.spacing()
				ui.withFont(orbiteer.heading, function()
					ui.text("Naval Combat Bonds")
				end)
				ui.spacing()

				if not isPrison and not isStateless then
					local localBonds = FrontlineCZ.GetPendingBonds(factionName)
					if localBonds > 0 then
						ui.withStyleColors({ Text = green }, function()
							ui.text(string.format("Pending %s Combat Bonds: %s", factionName, Format.Money(localBonds, false)))
						end)
						if ui.button(string.format("Redeem Combat Bonds (%s)##polRedeemBonds", Format.Money(localBonds, false)), nil) then
							local paid, err = FrontlineCZ.RedeemBonds(factionName)
							if paid and paid > 0 then
								militaryStatusBanner = string.format("Redeemed %s in %s Combat Bonds.", Format.Money(paid, false), factionName)
								militaryBannerColor = green
								ui.playSfx("OK")
							elseif err then
								militaryStatusBanner = err
								militaryBannerColor = colors.alertRed
							end
						end
					else
						ui.withStyleColors({ Text = colors.fontDim }, function()
							ui.text("No pending Combat Bonds for " .. factionName .. ".")
						end)
					end
				end

				local allBonds = FrontlineCZ.GetAllPendingBonds()
				local otherBonds = {}
				for _, b in ipairs(allBonds) do
					if isPrison or isStateless or b.factionName ~= factionName then
						table.insert(otherBonds, b)
					end
				end
				if #otherBonds > 0 then
					ui.spacing()
					ui.withStyleColors({ Text = colors.fontDim }, function()
						ui.text("Unredeemed Bonds Held for Other Factions:")
					end)
					for _, b in ipairs(otherBonds) do
						ui.text(string.format("  • %s: %s", b.factionName, Format.Money(b.amount, false)))
					end
				end
			end

			if militaryStatusBanner then
				ui.spacing()
				ui.withStyleColors({ Text = militaryBannerColor }, function()
					ui.textWrapped(militaryStatusBanner)
				end)
			end
		end
	}
}

local function drawPolice()
	local now = ui.getTime()
	local intro_txt = string.interp(l.THIS_IS_FACTION_POLICE,
		{ faction_police = Game.system.faction.policeName, faction = Game.system.faction.name})

	ui.withStyleVars({ItemSpacing = widgetSizes.itemSpacing}, function()
		local padding = ui.getWindowPadding()
		local infoColumnWidth = ui.getContentRegion().x
			- widgetSizes.faceSize.x - padding.x * 2

		ui.child("CrimeStats", Vector2(infoColumnWidth, 0), nil, commsChildFlags, function()
			commsText:renderCommsHeader(now, "POLICE-SEC // 4096-BIT")
			ui.withFont(pionillium.heading, function ()
				ui.textWrapped(commsText:get(now))
			end)
			ui.spacing()

			ui.tabBarFont("tabs", policeTabs, pionillium.heading)
		end)

		ui.sameLine(0, padding.x * 2)
		ui.child("PoliceContactPane", Vector2(0, 0), nil, commsChildFlags, function()
			if(face ~= nil) then face:render() end
		end)
	end)
end

view = StationView:registerView({
	id = "police",
	name = l.POLICE,
	icon = ui.theme.icons.police_tab_normal,
	securityMode = "encryption",
	showView = true,
	draw = drawPolice,
	refresh = function(self)
		militaryStatusBanner = nil
		local station = Game.player:GetDockedWith()
		if (station) then
			if (stationSeed ~= station.seed) then
				stationSeed = station.seed
				local rand = Rand.New(station.seed .. "-police")
				face = PiGuiFace.New(Character.New({ title = l.CONSTABLE, armour=true }, rand),
					{itemSpacing = widgetSizes.itemSpacing})
			end
		end

		local intro_txt = string.interp(l.THIS_IS_FACTION_POLICE,
			{ faction_police = Game.system.faction.policeName, faction = Game.system.faction.name})
		commsText:reset(intro_txt)
		refreshStatusIcon()
	end,
	debugReload = function()
		package.reimport()
	end
})

Event.Register("onShipDocked", function(player, station)
	if player:IsPlayer() then
		refreshStatusIcon()
	end
end)
