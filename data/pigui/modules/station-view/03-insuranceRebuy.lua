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
local sarClaimCommsText = EncryptedText.New("Pilot life signs verified and medical clearance issued by starport trauma ward staff. Under standard emergency protocols, you must exercise Option A (Hull Rebuy) or Option B (Payout & Starter Craft) to clear starport quarantine hold and obtain launch clearance.", 0.50)
local sarPolicyCommsText = EncryptedText.New("All licensed vessels are equipped with a standardized COSPAS-SARSAT cryogenic stasis pod. In the event of catastrophic hull integrity failure, emergency ejection is automatically executed and broadcast across the sub-space distress network. SAR trauma responders maintain continuous beacon monitoring across civilized space. Upon recovery, pilots are stabilized in medical starports without forfeiture of legal assets.", 0.50)

local function drawClaimPending(claim)
	local now = ui.getTime()
	local playerMoney = PlayerState.GetMoney()
	local canAffordRebuy = playerMoney >= claim.deductible
	local payoutAmount = math.max(0, claim.totalValue - claim.deductible)

	ui.withStyleVars({ItemSpacing = widgetSizes.itemSpacing}, function()
		local padding = ui.getWindowPadding()
		local infoColumnWidth = ui.getContentRegion().x
			- widgetSizes.faceSize.x - padding.x * 2

		-- Left Column: Incident Report & Settlement Options
		ui.child("ClaimMedicalSAR", Vector2(infoColumnWidth, 0), nil, commsChildFlags, function()
			ui.withFont(orbiteer.title, function()
				ui.textColored(colors.alertRed, "CRITICAL SHIP LOSS - SEARCH & RESCUE RECOVERY REPORT")
			end)
			ui.separator()
			ui.spacing()

			ui.withFont(orbiteer.medlarge, function()
				ui.textColored(colors.uiPrimaryLight, "MEDICAL DISCHARGE & SAR LOG")
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

			textTable.draw({
				{ "SAR Facility", claim.stationName or "Starport Medical Ward" },
				{ "Cryo-Stasis Duration", recoveryTimeStr },
				{ "Patient Vitals", "Resuscitated & Stabilized" },
				{ "Distress Incident System", claim.systemName or "Unknown Sector" },
				{ "Policy Coverage", "95% (Deductible: 5%)" },
				{ "Your Cash Balance", Format.Money(playerMoney) },
			})

			ui.spacing()
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
			end

			ui.separator()
			ui.spacing()

			local shipDef = ShipDef[claim.hullId]
			local hullName = (shipDef and shipDef.name) or claim.hullId

			ui.withFont(orbiteer.medlarge, function()
				ui.textColored(colors.uiPrimaryLight, "DESTROYED VESSEL VALUATION")
			end)
			ui.spacing()

			textTable.draw({
				{ "Vessel Call-Sign", claim.shipName or "Unregistered" },
				{ "Ship Model", hullName },
				{ "Total Hull & Modules Value", Format.Money(claim.totalValue) },
				{ "Insurance Deductible (5%)", Format.Money(claim.deductible) },
			})

			ui.spacing()
			ui.separator()
			ui.spacing()

			ui.withFont(orbiteer.medlarge, function()
				ui.text("SETTLEMENT OPTIONS")
			end)
			ui.spacing()

			-- Option 1: Rebuy Exact Ship
			ui.group(function()
				ui.textColored(colors.uiPrimaryLight, "Option A: Full Insurance Rebuy (Recommended)")
				ui.textColored(colors.fontDim, "Replaces and re-installs your exact hull and all insured equipment modules.")

				local rebuyLabel = canAffordRebuy and
					string.format("REBUY SHIP & OUTFITTING (%s)", Format.Money(claim.deductible)) or
					string.format("INSUFFICIENT FUNDS (Need %s)", Format.Money(claim.deductible))

				if not canAffordRebuy then
					ui.textColored(colors.compareWorse, "You do not have enough credits to cover the 5% deductible.")
				end

				if ui.button(rebuyLabel, Vector2(ui.getContentRegion().x, widgetSizes.buttonSizeBase.y)) then
					if canAffordRebuy then
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

			ui.spacing()
			ui.separator()
			ui.spacing()

			-- Option 2: Insurance Payout & Starter Loaner Ship
			ui.group(function()
				ui.textColored(colors.uiPrimaryLight, "Option B: Cash Settlement & Starter Loaner")
				ui.textColored(colors.fontDim, "Receive the net cash insurance payout and a standard starter scout.")

				local payoutLabel = string.format("CLAIM PAYOUT (%s) & STARTER CRAFT", Format.Money(payoutAmount))

				if ui.button(payoutLabel, Vector2(ui.getContentRegion().x, widgetSizes.buttonSizeBase.y)) then
					local ok, msg = Insurance.ClaimPayoutAndLoaner()
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

			-- Claim settlement feedback displayed at bottom so report and buttons never shift
			if statusBanner then
				ui.spacing()
				ui.textColored(bannerColor, statusBanner)
			end
		end)

		ui.sameLine(0, padding.x * 2)

		-- Right Column: SAR Official Contact & Authority Directive
		ui.child("InsuranceContactPane", Vector2(0, 0), nil, commsChildFlags, function()
			if face ~= nil then
				face:render()
			end
			ui.spacing()
			ui.separator()
			ui.spacing()
			sarClaimCommsText:renderCommsHeader(now, "SAR-MED // CASUALTY-EVAC")
			ui.withFont(orbiteer.medlarge, function()
				ui.textColored(colors.alertRed, "RESCUE DISCHARGE DIRECTIVE")
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

			ui.withFont(orbiteer.medlarge, function()
				ui.textColored(colors.uiPrimaryLight, "CURRENT VESSEL POLICY SCHEDULE")
			end)
			ui.spacing()

			textTable.draw({
				{ "Insured Vessel Name", policy.shipLabel or "Unregistered" },
				{ "Hull Classification", policy.hullName },
				{ "Hull Base Valuation", Format.Money(policy.hullValue) },
				{ "Installed Equipment Valuation", Format.Money(policy.equipValue) },
				{ "Total Insured Sum", Format.Money(policy.totalValue) },
				{ "Policy Coverage Rate", string.format("%d%%", policy.coverageRate) },
				{ "Rebuy Deductible", policy.hardcore and "N/A (Permadeath)" or Format.Money(policy.deductible) },
				{ "Account Status", policy.hardcore and "UNINSURED (HARDCORE CHARTER)" or "ACTIVE & IN GOOD STANDING" },
				{ "SAR Transponder Status", policy.beaconStatus },
			})

			ui.spacing()
			ui.separator()
			ui.spacing()

			ui.withFont(orbiteer.medlarge, function()
				ui.text("PILOT ASSURANCE GUARANTEE")
			end)
			ui.spacing()
			ui.textWrapped("Under standard interstellar charter laws, pilots recovered via cryogenic stasis are transported to the nearest regional medical starport. Upon discharge, you may exercise your right to rebuy your exact ship and outfitting for the 5% deductible fee, or receive an insurance cash payout with a complimentary starter loaner craft.")
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

local function drawInsuranceView()
	local claim = Insurance.GetActiveClaim()
	if claim and claim.pending then
		drawClaimPending(claim)
	else
		drawPolicyPortal()
	end
end

StationView:registerView({
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

		if Insurance.HasPendingClaim() then
			self.name = "Insurance [CLAIM]"
		else
			self.name = "Insurance & SAR"
		end
	end,
	debugReload = function()
		package.reimport()
	end
})

