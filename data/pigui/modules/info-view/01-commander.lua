-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui = require 'pigui'
local InfoView = require 'pigui.views.info-view'
local Lang = require 'Lang'
local Character = require 'Character'
local PiGuiFace = require 'pigui.libs.face'
local Event = require 'Event'
local PlayerState = require 'PlayerState'
local FactionStanding = require 'FactionStanding'
local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')

local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local icons = ui.theme.icons

local textTable = require 'pigui.libs.text-table'

local l = Lang.GetResource("ui-core")

local childFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }
local itemSpacing = ui.rescaleUI(Vector2(6, 5), Vector2(1920, 1080))

local face = nil

local function drawPlayerInfo()
    local player = Character.persistent.player

	textTable.withHeading(l.COMBAT, orbiteer.heading, {
		{ l.RATING, l[player:GetCombatRating()] },
		{ l.KILLS,  string.format('%d',player.killcount) },
	})

	ui.spacing()
	ui.separator()
	ui.spacing()

	textTable.withHeading(l.REPUTATION, orbiteer.heading, {
		{ l.STATUS..":", l[player:GetReputationRating()] },
	})

	ui.spacing()
	ui.separator()
	ui.spacing()

	if okTax and TaxAuthority and TaxAuthority.GetResidencyInfo then
		local res = TaxAuthority.GetResidencyInfo()
		local residencyRows
		if res.isResident then
			local lockStr = res.canChange
				and "Unlocked (Eligible to Relocate)"
				or string.format("%d / %d days remaining", res.remainingDays or 0, res.termDaysTotal or 90)
			residencyRows = {
				{ "Home Station:", res.homeStationName or "Unknown" },
				{ "Home System:", res.homeSystemName or "Unknown" },
				{ "Jurisdiction:", res.homeFaction or "Independent" },
				{ "Tax Rate:", string.format("%.1f%%", (res.effectiveRate or 0) * 100) },
				{ "Residency Lock:", lockStr },
			}
		else
			residencyRows = {
				{ "Status:", "Stateless / Unregistered (Register in any Station Lobby)" },
			}
		end
		textTable.withHeading("RESIDENCY & HOME PORT", orbiteer.heading, residencyRows)

		ui.spacing()
		ui.separator()
		ui.spacing()
	end

	local financeRows = {
		{ l.CASH .. ":", ui.Format.Money(PlayerState.GetMoney()) }
	}
	if okTax and TaxAuthority and TaxAuthority.GetTaxAssessment then
		local assess = TaxAuthority.GetTaxAssessment()
		local mgr = assess.manager
		local repDue = assess.reportedTaxDue or 0
		local repStr = (repDue > 0)
			and string.format("%s (%s)", ui.Format.Money(repDue), assess.isDelinquent and "DELINQUENT" or ("Due " .. (assess.earliestDueLabel or "Next Qtr")))
			or "None"
		table.insert(financeRows, { "Reported Taxes Due:", repStr })
		table.insert(financeRows, {
			string.format("Current Qtr (%s):", assess.currentQuarterLabel or "Est."),
			string.format("%s (Reports %s)", ui.Format.Money(assess.currentQuarterTax or 0), assess.currentQuarterReportLabel or "Quarter End")
		})
		table.insert(financeRows, {
			"Financial Manager:",
			(mgr and mgr.hired) and string.format("%s (Auto-Pay Active)", mgr.name or "Officer") or "None (Hire in Station Lobby)"
		})
	end
	textTable.withHeading(l.FINANCE, orbiteer.heading, financeRows)

	local standings = FactionStanding.GetAll(true)
	if #standings > 0 then
		ui.spacing()
		ui.separator()
		ui.spacing()
		local rows = {}
		for _, entry in ipairs(standings) do
			local pct = math.floor((entry.mult - 1.0) * 100 + 0.5)
			local modStr = pct == 0 and "100%" or string.format("%+d%% pay", pct)
			table.insert(rows, { entry.name .. ":", string.format("%s (%+d) [%s]", entry.label, entry.score, modStr) })
		end
		textTable.withHeading("FACTION STANDINGS", orbiteer.heading, rows)
	end
end

InfoView:registerView({
    id = "commander",
    name = l.COMMANDER or "Commander",
    icon = icons.personal_info,
    showView = true,
	draw = function()
		local region = ui.getContentRegion()
		local leftWidth = math.floor(region.x * 0.50)

		ui.withStyleVars({ItemSpacing = itemSpacing}, function()
			ui.withFont(pionillium.body, function()
				ui.child("PlayerInfoDetails", Vector2(leftWidth, 0), nil, childFlags, drawPlayerInfo)

				ui.sameLine()

				ui.child("PlayerView", Vector2(0, 0), nil, childFlags, function()
					face = face or PiGuiFace.New(Character.persistent.player, nil, false)
					face:render()
				end)
			end)
		end)
	end,
    refresh = function() end,
	debugReload = function()
		package.reimport('pigui.libs.face')
		package.reimport()
	end
})

Event.Register("onGameEnd", function ()
    face = nil
end)
