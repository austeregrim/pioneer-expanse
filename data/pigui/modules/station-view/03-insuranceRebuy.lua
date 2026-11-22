-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game        = require 'Game'
local ui          = require 'pigui'
local StationView = require 'pigui.views.station-view'
local Format      = require 'Format'
local PlayerState = require 'PlayerState'
local ShipDef     = require 'ShipDef'
local Rand        = require 'Rand'
local Character   = require 'Character'
local PiGuiFace   = require 'pigui.libs.face'
local textTable   = require 'pigui.libs.text-table'
local Insurance   = require 'modules.Insurance.Insurance'
local EncryptedText = require 'pigui.libs.encrypted-text'

local colors = ui.theme.colors
local icons = ui.theme.icons
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local Vector2 = _G.Vector2

local rescaleVector = ui.rescaleUI(Vector2(1, 1), Vector2(1920, 1080), true)
local commsChildFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }
local widgetSizes = ui.rescaleUI({
	itemSpacing = Vector2(4, 7),
	faceSize = Vector2(460, 440),
	buttonSizeBase = Vector2(64, 40),
}, Vector2(1920, 1080))

local face = nil
local stationSeed = false
local statusBanner = nil
local bannerColor = colors.uiPrimaryLight
local sarClaimCommsText = EncryptedText.New("Under interstellar maritime charter, recovered pilots are placed into an Insurance Starter Ship (Coronatrix) upon arrival. You may pay your policy deductible to swap the starter ship for a factory-fresh replacement of your destroyed vessel, or keep the starter ship and receive any remaining insured equity in cash after deducting both the deductible and the starter ship's cost.", 0.50)
local sarPolicyCommsText = EncryptedText.New("All licensed vessels are equipped with a standardized COSPAS-SARSAT cryogenic stasis pod. In the event of catastrophic hull integrity failure, emergency ejection is automatically executed and broadcast across the sub-space distress network. SAR trauma responders maintain continuous beacon monitoring across civilized space. Upon recovery, pilots are stabilized in medical starports without forfeiture of legal assets.", 0.50)

local function drawClaimPending(claim)
	local now = ui.getTime()
	local playerMoney = PlayerState.GetMoney()
	local bd = Insurance.GetClaimPayoutBreakdown(claim)
	local canAffordRebuy = playerMoney >= bd.deductible
	local starterDef = ShipDef[claim.starterShipId or Insurance.STARTER_SHIP_ID]
	local starterHullName = (starterDef and starterDef.name) or "Coronatrix"

	ui.withStyleVars({ItemSpacing = widgetSizes.itemSpacing}, function()
		local padding = ui.getWindowPadding()
		local infoColumnWidth = ui.getContentRegion().x
			- widgetSizes.faceSize.x - padding.x * 2

		-- Left Column: Incident Report & Settlement Options
		ui.child("ClaimMedicalSAR", Vector2(infoColumnWidth, 0), nil, commsChildFlags, function()
			ui.withFont(orbiteer.title, function()
				if claim.isArrest then
					ui.textColored(colors.alertRed, "DEPARTMENT OF CORRECTIONS // DISCHARGED PILOT INSURANCE CLAIM")
				else
					ui.textColored(colors.alertRed, "SEARCH & RESCUE // VESSEL LOSS INSURANCE CLAIM")
				end
			end)
			ui.separator()
			ui.spacing()

			ui.withFont(orbiteer.medlarge, function()
				if claim.isArrest then
					ui.textColored(colors.uiPrimaryLight, "POST-INCARCERATION VESSEL REPLACEMENT CLAIM")
				else
					ui.textColored(colors.uiPrimaryLight, "SAR RESCUE & VESSEL LOSS LOG")
				end
			end)
			ui.spacing()

			local days = claim.recoveryDays or 0.5
			local recoveryTimeStr
			if days < 1.0 then
				recoveryTimeStr = string.format("%.1f Hours (%.2f Days)", days * 24.0, days)
			elseif days >= 365.25 then
				recoveryTimeStr = string.format("%.1f Years (%.0f Days)", days / 365.25, days)
			else
				recoveryTimeStr = string.format("%.1f Standard Days", days)
			end

			local shipDef = ShipDef[claim.hullId]
			local hullName = (shipDef and shipDef.name) or claim.hullId
			local payoutSummaryStr = bd.cashPayout > 0
				and Format.Money(bd.cashPayout)
				or "0.00 Cr (Charter-Subsidized Starter)"

			if claim.isArrest then
				textTable.draw({
					{ "Correctional Facility", claim.stationName or "Department of Corrections Facility" },
					{ "Incarceration Sentence Served", string.format("%d Standard Days", claim.totalSentenceDays or 1) },
					{ "Fines Settled", claim.finePaid and claim.finePaid > 0 and Format.Money(claim.finePaid) or "0.00 Cr (Commuted via Labor)" },
					{ "Legal Status", "Clean / Full Civilian Rights Restored" },
					{ "Current Assigned Ship", string.format("Insurance Starter Ship (%s — Pad 1)", starterHullName) },
					{ "Destroyed Vessel", string.format("%s (%s)", claim.shipName or "Unregistered", hullName) },
					{ "Total Hull & Modules Value", Format.Money(bd.totalValue) },
					{ string.format("Insurance Deductible (%d%%)", bd.deductibleRate), Format.Money(bd.deductible) },
					{ string.format("Insurance Starter Cost (%s)", starterHullName), Format.Money(bd.starterCost) },
					{ "Net Cash Payout (if keeping Starter)", payoutSummaryStr },
					{ "Your Cash Balance", Format.Money(playerMoney) },
				})
			else
				textTable.draw({
					{ "SAR Recovery Facility", claim.stationName or "Starport Medical Ward" },
					{ "Cryo-Stasis Duration", recoveryTimeStr },
					{ "Patient Vitals", "Resuscitated & Stabilized" },
					{ "Loss Incident Sector", claim.systemName or "Unknown Sector" },
					{ "Current Assigned Ship", string.format("Insurance Starter Ship (%s — Pad 1)", starterHullName) },
					{ "Destroyed Vessel", string.format("%s (%s)", claim.shipName or "Unregistered", hullName) },
					{ "Total Hull & Modules Value", Format.Money(bd.totalValue) },
					{ string.format("Insurance Deductible (%d%%)", bd.deductibleRate), Format.Money(bd.deductible) },
					{ string.format("Insurance Starter Cost (%s)", starterHullName), Format.Money(bd.starterCost) },
					{ "Net Cash Payout (if keeping Starter)", payoutSummaryStr },
					{ "Your Cash Balance", Format.Money(playerMoney) },
				})
			end

			ui.spacing()
			ui.separator()
			ui.spacing()

			if claim.equipment and #claim.equipment > 0 then
				ui.withFont(orbiteer.medlarge, function()
					ui.textColored(colors.uiPrimaryLight, "INSURED EQUIPMENT MODULES (INCLUDED IN REBUY)")
				end)
				ui.spacing()
				ui.textColored(colors.fontDim, "All insured outfitting will be restored and fitted to the replacement hull:")
				for _, eq in ipairs(claim.equipment) do
					local priceStr = (eq.subsidized or (eq.price or 0) == 0)
						and "0.00 Cr (Subsidized)"
						or Format.Money(eq.price or 0)
					ui.bulletText(string.format("%s - %s", eq.name or eq.id, priceStr))
				end
				ui.spacing()
				ui.separator()
				ui.spacing()
			end

			if claim.droppedCargo and #claim.droppedCargo > 0 then
				ui.withFont(orbiteer.medlarge, function()
					ui.textColored(colors.fontDim, "JETTISONED CARGO FLOTSAM")
				end)
				ui.spacing()
				ui.textColored(colors.fontDim, "Cargo wreckage was jettisoned with an emergency transponder beacon:")
				for _, item in ipairs(claim.droppedCargo) do
					ui.bulletText(string.format("%s (%d units)", item.name, item.count))
				end
				ui.spacing()
				ui.separator()
				ui.spacing()
			end

			ui.withFont(orbiteer.medlarge, function()
				ui.text("SETTLEMENT OPTIONS")
			end)
			ui.spacing()

			ui.columns(2, "SettlementOptionsColumns", false)

			-- Column 1: Option A - Rebuy Destroyed Ship
			ui.group(function()
				ui.textColored(colors.uiPrimaryLight, "Option A: Rebuy Destroyed Ship (Recommended)")
				ui.withStyleColors({ Text = colors.fontDim }, function()
					ui.textWrapped(string.format("Pay the %d%% deductible (%s) to swap your %s starter ship on Pad 1 for a factory-fresh replacement %s with all insured outfitting restored.",
						bd.deductibleRate, Format.Money(bd.deductible), starterHullName, hullName))
				end)
				ui.spacing()

				local rebuyLabel = canAffordRebuy and
					string.format("REBUY %s (%s)", string.upper(hullName), Format.Money(bd.deductible)) or
					string.format("INSUFFICIENT FUNDS (Need %s)", Format.Money(bd.deductible))

				if not canAffordRebuy then
					ui.textColored(colors.compareWorse, string.format("Insufficient credits for the %d%% deductible. Sell stocks or secondary fleet ships at this station to raise funds, or select Option B to keep the %s starter ship.",
						bd.deductibleRate, starterHullName))
				else
					ui.dummy(Vector2(0, 16))
				end

				ui.spacing()

				local rebuyVariant = canAffordRebuy and ui.theme.buttonColors.default or ui.theme.buttonColors.disabled
				if not canAffordRebuy then
					ui.withStyleColors({
						Button = ui.theme.buttonColors.disabled.normal,
						ButtonHovered = ui.theme.buttonColors.disabled.normal,
						ButtonActive = ui.theme.buttonColors.disabled.normal,
						Text = colors.fontDim
					}, function()
						ui.button(rebuyLabel, Vector2(-1, widgetSizes.buttonSizeBase.y), nil, string.format("Insufficient credits for %d%% deductible", bd.deductibleRate))
					end)
				else
					if ui.button(rebuyLabel, Vector2(-1, widgetSizes.buttonSizeBase.y), rebuyVariant) then
						local ok, msg = Insurance.RebuyShip()
						if ok then
							statusBanner = msg
							bannerColor = colors.compareBetter
							ui.playSfx("OK")
						else
							statusBanner = msg
							bannerColor = colors.compareWorse
						end
					end
				end
			end)

			ui.nextColumn()

			-- Column 2: Option B - Keep Insurance Starter Ship & Cash Payout
			ui.group(function()
				ui.textColored(colors.uiPrimaryLight, string.format("Option B: Keep %s Starter & Payout", starterHullName))
				ui.withStyleColors({ Text = colors.fontDim }, function()
					if bd.cashPayout > 0 then
						ui.textWrapped(string.format("Keep your %s starter ship (full ownership) and collect the remaining cash balance: %s insured value - %s deductible - %s starter ship cost = %s cash payout.",
							starterHullName, Format.Money(bd.totalValue), Format.Money(bd.deductible), Format.Money(bd.starterCost), Format.Money(bd.cashPayout)))
					else
						ui.textWrapped(string.format("Net insured equity (%s) is below the %s %s starter cost. Cash payout is 0.00 Cr; the underwriter waives the %s difference and issues the %s as a Charter-Subsidized Starter (0 Cr hull/stock resale value).",
							Format.Money(bd.netInsuredValue), Format.Money(bd.starterCost), starterHullName, Format.Money(bd.subsidyAmount), starterHullName))
					end
				end)
				ui.spacing()

				ui.dummy(Vector2(0, 16))
				ui.spacing()

				local payoutLabel = bd.cashPayout > 0
					and string.format("KEEP STARTER & CLAIM %s PAYOUT", Format.Money(bd.cashPayout))
					or string.format("KEEP CHARTER-SUBSIDIZED %s (0.00 Cr)", string.upper(starterHullName))

				if ui.button(payoutLabel, Vector2(-1, widgetSizes.buttonSizeBase.y), ui.theme.buttonColors.default) then
					local ok, msg = Insurance.ClaimPayoutAndKeepStarter()
					if ok then
						statusBanner = msg
						bannerColor = colors.compareBetter
						ui.playSfx("OK")
					else
						statusBanner = msg
						bannerColor = colors.compareWorse
					end
				end
			end)

			ui.columns(1, "SettlementOptionsEnd", false)

			-- Claim settlement feedback displayed at bottom
			if statusBanner then
				ui.spacing()
				ui.textColored(bannerColor, statusBanner)
			end
		end)

		ui.sameLine(0, padding.x * 2)

		-- Right Column: Underwriter / Claims Adjuster Contact & Directive
		ui.child("InsuranceContactPane", Vector2(0, 0), nil, commsChildFlags, function()
			if face ~= nil then
				face:render()
			end
			ui.spacing()
			ui.separator()
			ui.spacing()
			sarClaimCommsText:renderCommsHeader(now, "INSURANCE // CLAIMS ADJUSTER")
			ui.withFont(orbiteer.medlarge, function()
				ui.textColored(colors.uiPrimaryLight, "POLICY DIRECTIVE")
			end)
			ui.spacing()
			sarClaimCommsText:renderTextWrapped(now, pionillium.body)
		end)
	end)
end

local function drawPolicyPortal()
	local now = ui.getTime()
	local policy = Insurance.GetPolicyInfo()
	if not policy then
		ui.text("No active ship registered with starport insurance database.")
		return
	end

	ui.withStyleVars({ItemSpacing = widgetSizes.itemSpacing}, function()
		local padding = ui.getWindowPadding()
		local infoColumnWidth = ui.getContentRegion().x
			- widgetSizes.faceSize.x - padding.x * 2

		-- Left Column: Policy details and guarantees
		ui.child("PolicySchedulePane", Vector2(infoColumnWidth, 0), nil, commsChildFlags, function()
			ui.withFont(orbiteer.title, function()
				ui.textColored(colors.uiPrimaryLight, "SOLAR MARINE & ASTRAL UNDERWRITERS")
			end)
			ui.textColored(colors.fontDim, "Official Galactic Search & Rescue Underwriter and Vessel Hull Registry")
			ui.separator()
			ui.spacing()

			if statusBanner then
				ui.textColored(bannerColor, statusBanner)
				ui.spacing()
				ui.separator()
				ui.spacing()
			end

			ui.withFont(orbiteer.medlarge, function()
				ui.textColored(colors.uiPrimaryLight, "CURRENT VESSEL POLICY SCHEDULE")
			end)
			ui.spacing()

			local scheduleRows = {
				{ "Insured Vessel Name", policy.shipLabel or "Unregistered" },
				{ "Hull Classification", policy.hullName },
				{ "Hull Base Valuation", policy.isSubsidized and "0.00 Cr (Charter-Subsidized Starter)" or Format.Money(policy.hullValue) },
				{ "Installed Equipment Valuation", Format.Money(policy.equipValue) },
				{ "Total Insured Sum", Format.Money(policy.totalValue) },
				{ "Policy Coverage Rate", string.format("%d%%", policy.coverageRate) },
				{ string.format("Rebuy Deductible (%d%%)", policy.deductibleRate), policy.hardcore and "N/A (Permadeath)" or Format.Money(policy.deductible) },
				{ "Account Status", policy.hardcore and "UNINSURED (HARDCORE CHARTER)" or "ACTIVE & IN GOOD STANDING" },
				{ "SAR Transponder Status", policy.beaconStatus },
			}
			if policy.isSubsidized then
				table.insert(scheduleRows, 3, { "Hull Ownership Status", "Charter-Subsidized Starter (0 Cr hull trade-in; aftermarket gear covered)" })
			end
			textTable.draw(scheduleRows)

			ui.spacing()
			ui.separator()
			ui.spacing()

			ui.withFont(orbiteer.medlarge, function()
				ui.text("PILOT ASSURANCE GUARANTEE")
			end)
			ui.spacing()
			ui.textWrapped(string.format("Under standard interstellar charter laws, pilots recovered via cryogenic stasis are placed into a standard Insurance Starter Ship (Coronatrix) at the nearest regional starport. Upon discharge, you may pay your %d%% deductible to swap the starter ship for a replacement of your destroyed vessel, or keep the starter ship and receive any remaining insured equity in cash after deducting both the deductible and the starter ship's cost.", policy.deductibleRate))
		end)

		ui.sameLine(0, padding.x * 2)

		-- Right Column: SAR Attendant portrait & Contact
		ui.child("PolicyContactPane", Vector2(0, 0), nil, commsChildFlags, function()
			if face ~= nil then
				face:render()
			end
			ui.spacing()
			ui.separator()
			ui.spacing()
			sarPolicyCommsText:renderCommsHeader(now, "SAR-TRANS // COSPAS-SARSAT")
			ui.withFont(orbiteer.medlarge, function()
				ui.textColored(colors.uiPrimaryLight, "SAR EMERGENCY DIRECTIVE")
			end)
			ui.spacing()
			sarPolicyCommsText:renderTextWrapped(now, pionillium.body)
		end)
	end)
end

local insuranceViewTab

local function drawInsuranceView()
	local claim = Insurance.GetActiveClaim()
	local hasClaim = claim ~= nil and not claim.resolved
	if insuranceViewTab then
		insuranceViewTab.name = hasClaim and "Insurance [CLAIM]" or "Insurance & SAR"
	end
	if hasClaim then
		drawClaimPending(claim)
	else
		drawPolicyPortal()
	end
end

insuranceViewTab = StationView:registerView({
	id = "insurance",
	name = "Insurance & SAR",
	icon = icons.hull,
	securityMode = "encryption",
	showView = true,
	draw = drawInsuranceView,
	refresh = function(self)
		sarClaimCommsText:reset()
		sarPolicyCommsText:reset()
		statusBanner = nil
		local station = Game.player:GetDockedWith()
		if station then
			if stationSeed ~= station.seed then
				stationSeed = station.seed
				local rand = Rand.New(station.seed .. "-insurance")
				face = PiGuiFace.New(
					Character.New({ title = "SAR CHIEF MEDICAL OFFICER", org = "SEARCH & RESCUE UNDERWRITERS", role = "rescue" }, rand),
					{ itemSpacing = widgetSizes.itemSpacing }
				)
			end
		end

		if Insurance.HasClaim() then
			self.name = "Insurance [CLAIM]"
		else
			self.name = "Insurance & SAR"
		end
	end,
	debugReload = function()
		package.reimport()
	end
})

